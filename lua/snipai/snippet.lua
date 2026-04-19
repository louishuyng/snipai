-- Snippet object — the canonical shape for one snippet in the registry.
--
-- Responsibilities:
--   validate()         :: the JSON config is well-formed and body / insert
--                         reference only declared parameters or built-in
--                         context names (see M.RESERVED).
--   render(values,ctx) :: substitute {{placeholders}} in the body against
--                         user params + plugin-supplied built-ins.
--   render_insert(...) :: same substitution on the optional `insert` field.
--
-- Rendering intentionally has no escape syntax: there is no way to emit a
-- literal "{{name}}" into the prompt. If that need arises, add an escape
-- later (not speculatively).

local params = require("snipai.params")

local M = {}

-- Reserved built-in placeholder names. The plugin auto-populates these at
-- trigger time from the buffer/window state; snippet authors reference
-- them via {{placeholders}} in body / insert but must NOT declare them in
-- `parameter`. Validation rejects any snippet that tries.
M.RESERVED = {
  cursor_file = true,
  cursor_line = true,
  cursor_col = true,
  cwd = true,
}

-- {{name}} or {{ name }} -> captures "name". Names are [A-Za-z0-9_]+.
local PLACEHOLDER_PATTERN = "{{%s*([%w_]+)%s*}}"

local function extract_placeholders(body)
  local names = {}
  local seen = {}
  for name in body:gmatch(PLACEHOLDER_PATTERN) do
    if not seen[name] then
      seen[name] = true
      table.insert(names, name)
    end
  end
  return names
end

-- A snippet's `filetype` field may be:
--   * nil                  — no filetype constraint
--   * a non-empty string   — single filetype ("lua")
--   * a non-empty array of non-empty strings — any-of list
local function validate_filetype(ft)
  if type(ft) == "string" then
    if ft == "" then
      return false, "filetype string must be non-empty"
    end
    return true
  end
  if type(ft) == "table" then
    if #ft == 0 then
      return false, "filetype array must be non-empty"
    end
    for i, v in ipairs(ft) do
      if type(v) ~= "string" or v == "" then
        return false, ("filetype[%d] must be a non-empty string"):format(i)
      end
    end
    return true
  end
  return false, ("filetype must be a string or array of strings, got %s"):format(type(ft))
end

-- Substitute {{placeholders}} in `template` against `values`. Booleans
-- render as the literal strings "true" / "false"; unknown names render
-- as an empty string so downstream consumers see a predictable shape.
local function substitute(template, values)
  return template:gsub(PLACEHOLDER_PATTERN, function(name)
    local v = values[name]
    if type(v) == "boolean" then
      return v and "true" or "false"
    end
    if v == nil then
      return ""
    end
    return tostring(v)
  end)
end

-- Merge declared-param values on top of plugin-supplied context. Caller
-- can't collide with a reserved name at load time (validation guards it),
-- so the precedence order here only matters defensively.
local function merge_values(params_values, ctx)
  if ctx == nil then
    return params_values
  end
  local merged = {}
  for k, v in pairs(ctx) do
    merged[k] = v
  end
  for k, v in pairs(params_values) do
    merged[k] = v
  end
  return merged
end

-- ---------------------------------------------------------------------------
-- Snippet class
-- ---------------------------------------------------------------------------

local Snippet = {}
Snippet.__index = Snippet

function M.new(name, raw)
  assert(type(name) == "string" and name ~= "", "snippet name must be a non-empty string")
  assert(type(raw) == "table", "snippet definition must be a table")

  return setmetatable({
    name = name,
    description = raw.description,
    prefix = raw.prefix,
    body = raw.body,
    insert = raw.insert,
    parameter = raw.parameter or {},
    filetype = raw.filetype,
  }, Snippet)
end

function Snippet:validate()
  if type(self.prefix) ~= "string" or self.prefix == "" then
    return false, "missing or empty prefix"
  end
  if type(self.body) ~= "string" or self.body == "" then
    return false, "missing or empty body"
  end
  if self.insert ~= nil then
    if type(self.insert) ~= "string" or self.insert == "" then
      return false, "insert must be a non-empty string when set"
    end
  end
  if type(self.parameter) ~= "table" then
    return false, "parameter must be a table"
  end

  if self.filetype ~= nil then
    local ok_ft, err_ft = validate_filetype(self.filetype)
    if not ok_ft then
      return false, err_ft
    end
  end

  for param_name, def in pairs(self.parameter) do
    if type(param_name) ~= "string" or param_name == "" then
      return false, "parameter name must be a non-empty string"
    end
    if M.RESERVED[param_name] then
      return false, ("parameter %q is a reserved built-in name"):format(param_name)
    end
    local ok, err = params.validate_definition(def)
    if not ok then
      return false, ("parameter %q: %s"):format(param_name, err)
    end
  end

  for _, ph in ipairs(extract_placeholders(self.body)) do
    if self.parameter[ph] == nil and not M.RESERVED[ph] then
      return false, ("body references unknown parameter %q"):format(ph)
    end
  end

  if self.insert ~= nil then
    for _, ph in ipairs(extract_placeholders(self.insert)) do
      if self.parameter[ph] == nil and not M.RESERVED[ph] then
        return false, ("insert references unknown parameter %q"):format(ph)
      end
    end
  end

  return true
end

-- Returns true when the snippet has no filetype constraint, or when the
-- supplied filetype matches one of the declared values. `ft` is the
-- buffer filetype the caller is testing against (usually vim.bo.filetype).
function Snippet:matches_filetype(ft)
  if self.filetype == nil then
    return true
  end
  if type(self.filetype) == "string" then
    return self.filetype == ft
  end
  for _, candidate in ipairs(self.filetype) do
    if candidate == ft then
      return true
    end
  end
  return false
end

-- render(values, ctx?)
--   values : { [param_name] = value }      -- declared params only
--   ctx    : { [builtin_name] = value }    -- cursor_file / cursor_line / ...
-- Returns the rendered body on success, or (nil, errors) when the
-- declared params fail validation. ctx is optional; missing built-ins
-- referenced in the body substitute to "".
function Snippet:render(values, ctx)
  local resolved = params.resolve_defaults(self.parameter, values)
  local ok, errors = params.validate_all(self.parameter, resolved)
  if not ok then
    return nil, errors
  end

  return substitute(self.body, merge_values(resolved, ctx))
end

-- render_insert(values, ctx?)
--   Renders the optional `insert` template. Returns nil when no insert
--   is declared (caller should not insert anything). Same validation
--   semantics as render().
function Snippet:render_insert(values, ctx)
  if self.insert == nil then
    return nil
  end
  local resolved = params.resolve_defaults(self.parameter, values)
  local ok, errors = params.validate_all(self.parameter, resolved)
  if not ok then
    return nil, errors
  end

  return substitute(self.insert, merge_values(resolved, ctx))
end

function Snippet:has_required_params()
  for _, def in pairs(self.parameter) do
    if params.is_required(def) then
      return true
    end
  end
  return false
end

-- Expose the placeholder-extraction helper for consumers that want to know
-- which params a body uses without going through render (e.g. the registry
-- validator, future previewers).
function Snippet:placeholders()
  return extract_placeholders(self.body or "")
end

return M
