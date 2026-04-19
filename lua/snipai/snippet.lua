-- Snippet object — the canonical shape for one snippet in the registry.
--
-- Responsibilities:
--   validate()  :: the JSON config for this snippet is well-formed and its
--                  body references only declared parameters.
--   render(values) :: substitute {{placeholders}} in the body with values,
--                     applying defaults and validating along the way.
--
-- Rendering intentionally has no escape syntax: there is no way to emit a
-- literal "{{name}}" into the prompt. If that need arises, add an escape
-- later (not speculatively).

local params = require("snipai.params")

local M = {}

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
    local ok, err = params.validate_definition(def)
    if not ok then
      return false, ("parameter %q: %s"):format(param_name, err)
    end
  end

  for _, ph in ipairs(extract_placeholders(self.body)) do
    if self.parameter[ph] == nil then
      return false, ("body references unknown parameter %q"):format(ph)
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

function Snippet:render(values)
  local resolved = params.resolve_defaults(self.parameter, values)
  local ok, errors = params.validate_all(self.parameter, resolved)
  if not ok then
    return nil, errors
  end

  local rendered = self.body:gsub(PLACEHOLDER_PATTERN, function(placeholder)
    local v = resolved[placeholder]
    if type(v) == "boolean" then
      return v and "true" or "false"
    end
    if v == nil then
      return ""
    end
    return tostring(v)
  end)

  return rendered
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
