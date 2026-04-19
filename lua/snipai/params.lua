-- Parameter definitions, validation, and default resolution.
--
-- This module owns the rules for what a snippet parameter looks like, when
-- a value is valid, and how defaults are applied. It is intentionally pure:
-- no Neovim APIs, no I/O. That keeps it trivially unit-testable and lets it
-- be used identically from the registry (load time) and the form popup
-- (submit time).
--
-- Two validation surfaces:
--   validate_definition(def)     -- load time; does the JSON declare a sane type?
--   validate_value(def, value)   -- submit time; is this user input acceptable?

local M = {}

-- ---------------------------------------------------------------------------
-- Type constants
-- ---------------------------------------------------------------------------

M.TYPES = {
  STRING = "string",
  TEXT = "text",
  SELECT = "select",
  BOOLEAN = "boolean",
}

local VALID_TYPES = {
  [M.TYPES.STRING] = true,
  [M.TYPES.TEXT] = true,
  [M.TYPES.SELECT] = true,
  [M.TYPES.BOOLEAN] = true,
}

-- ---------------------------------------------------------------------------
-- Predicates
-- ---------------------------------------------------------------------------

function M.is_valid_type(t)
  return type(t) == "string" and VALID_TYPES[t] == true
end

-- A parameter is "required" when the user must provide a non-empty value:
-- there is no default AND the definition is not explicitly marked optional.
function M.is_required(def)
  if def.default ~= nil then
    return false
  end
  return def.optional ~= true
end

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- For string/text/select, nil and empty string both count as "missing".
-- For boolean, ONLY nil is missing — `false` is a legitimate value.
local function is_missing(def, v)
  if def.type == M.TYPES.BOOLEAN then
    return v == nil
  end
  return v == nil or v == ""
end

local function default_matches_type(def)
  if def.default == nil then
    return true
  end
  local t = def.type
  if t == M.TYPES.STRING or t == M.TYPES.TEXT then
    return type(def.default) == "string"
  elseif t == M.TYPES.SELECT then
    if type(def.default) ~= "string" then
      return false
    end
    for _, opt in ipairs(def.options or {}) do
      if opt == def.default then
        return true
      end
    end
    return false
  elseif t == M.TYPES.BOOLEAN then
    return type(def.default) == "boolean"
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Definition validation (load time)
-- Used by registry.lua to decide whether a snippet's param block is sane.
-- ---------------------------------------------------------------------------

function M.validate_definition(def)
  if type(def) ~= "table" then
    return false, "parameter definition must be a table"
  end
  if not M.is_valid_type(def.type) then
    return false,
      ("invalid type %q; expected one of: string, text, select, boolean"):format(tostring(def.type))
  end

  if def.type == M.TYPES.SELECT then
    if type(def.options) ~= "table" or #def.options == 0 then
      return false, "type=select requires a non-empty options[] array"
    end
    for i, opt in ipairs(def.options) do
      if type(opt) ~= "string" then
        return false, ("options[%d] must be a string, got %s"):format(i, type(opt))
      end
    end
  end

  if def.default ~= nil and not default_matches_type(def) then
    return false, ("default value does not match type %q"):format(def.type)
  end

  return true
end

-- ---------------------------------------------------------------------------
-- Value validation (submit time)
-- ---------------------------------------------------------------------------

function M.validate_value(def, value)
  local t = def.type

  if is_missing(def, value) then
    if M.is_required(def) then
      return false, "value is required"
    end
    return true
  end

  if t == M.TYPES.STRING then
    if type(value) ~= "string" then
      return false, ("expected string, got %s"):format(type(value))
    end
    if value:find("\n", 1, true) then
      return false, "string values may not contain newlines (use type=text)"
    end
    return true
  elseif t == M.TYPES.TEXT then
    if type(value) ~= "string" then
      return false, ("expected string, got %s"):format(type(value))
    end
    return true
  elseif t == M.TYPES.SELECT then
    if type(value) ~= "string" then
      return false, ("expected string, got %s"):format(type(value))
    end
    for _, opt in ipairs(def.options or {}) do
      if opt == value then
        return true
      end
    end
    return false, ("value %q is not in options"):format(value)
  elseif t == M.TYPES.BOOLEAN then
    if type(value) == "boolean" then
      return true
    end
    return false, ("expected boolean, got %s"):format(type(value))
  end

  return false, ("unknown type %q"):format(tostring(t))
end

-- Batch-validate every definition against its corresponding value.
-- Returns (true) on success or (false, { [name] = err, ... }) on failure.
function M.validate_all(defs, values)
  values = values or {}
  local errors = {}
  local ok_all = true
  for name, def in pairs(defs or {}) do
    local ok, err = M.validate_value(def, values[name])
    if not ok then
      errors[name] = err
      ok_all = false
    end
  end
  if ok_all then
    return true
  end
  return false, errors
end

-- ---------------------------------------------------------------------------
-- Default resolution
--
-- Returns a new values table where missing values are replaced with the
-- declared `default`. Keys that are not declared in `defs` are dropped so
-- unrelated input can't leak into the rendered prompt.
-- ---------------------------------------------------------------------------

function M.resolve_defaults(defs, values)
  values = values or {}
  local resolved = {}
  for name, def in pairs(defs or {}) do
    local v = values[name]
    if is_missing(def, v) and def.default ~= nil then
      resolved[name] = def.default
    else
      resolved[name] = v
    end
  end
  return resolved
end

return M
