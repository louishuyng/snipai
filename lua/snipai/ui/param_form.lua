-- Snippet-aware parameter form.
--
-- Translates a Snippet's parameter table into an ordered field list,
-- drives `snipai.ui.popup` to collect raw values, then applies
-- `params.resolve_defaults` + `params.validate_all` before handing the
-- caller a clean, validated values table.
--
-- Field order: placeholders in body order first (the order a reader sees
-- them), then any declared-but-unreferenced params appended alphabetically
-- so the result is deterministic across Lua table-iteration runs.
--
-- Validation failures at submit time (e.g. a required field left empty)
-- surface via the injected notifier and route to on_cancel — the caller's
-- contract is: on_submit is only ever called with valid, resolved values.

local params = require("snipai.params")
local popup_mod = require("snipai.ui.popup")

local M = {}

local function placeholder_order(snippet)
  if type(snippet.placeholders) == "function" then
    return snippet:placeholders()
  end
  return {}
end

local function field_from(name, def)
  return {
    name = name,
    type = def.type,
    default = def.default,
    options = def.options,
  }
end

local function build_fields(snippet)
  local defs = snippet.parameter or {}
  local fields = {}
  local seen = {}

  for _, name in ipairs(placeholder_order(snippet)) do
    local def = defs[name]
    if def and not seen[name] then
      seen[name] = true
      fields[#fields + 1] = field_from(name, def)
    end
  end

  local leftovers = {}
  for name in pairs(defs) do
    if not seen[name] then
      leftovers[#leftovers + 1] = name
    end
  end
  table.sort(leftovers)
  for _, name in ipairs(leftovers) do
    fields[#fields + 1] = field_from(name, defs[name])
  end

  return fields
end

local function format_errors(errors)
  local parts = {}
  for name, err in pairs(errors) do
    parts[#parts + 1] = ("%s: %s"):format(name, err)
  end
  table.sort(parts)
  return table.concat(parts, "; ")
end

local function surface_error(notify, message)
  if notify and type(notify.notify) == "function" then
    notify:notify("snipai: " .. message, "error")
    return
  end
  if vim and vim.notify then
    local level = vim.log and vim.log.levels and vim.log.levels.ERROR
    vim.notify("snipai: " .. message, level)
  end
end

-- open(snippet, opts)
--   opts.on_submit(values)  required; receives validated, default-resolved values
--   opts.on_cancel()        optional; fires on user cancel OR validation failure
--   opts.notify             optional snipai.notify instance; used to surface
--                           validation errors (falls back to vim.notify)
--   opts.popup              optional; defaults to snipai.ui.popup (test seam)
function M.open(snippet, opts)
  assert(type(snippet) == "table", "param_form.open: snippet required")
  assert(
    type(opts) == "table" and type(opts.on_submit) == "function",
    "param_form.open: opts.on_submit required"
  )
  local on_cancel = opts.on_cancel or function() end
  local popup = opts.popup or popup_mod

  local fields = build_fields(snippet)
  if #fields == 0 then
    opts.on_submit({})
    return
  end

  popup.collect(fields, {
    on_submit = function(raw)
      local defs = snippet.parameter or {}
      local resolved = params.resolve_defaults(defs, raw)
      local ok, errors = params.validate_all(defs, resolved)
      if not ok then
        surface_error(opts.notify, format_errors(errors))
        on_cancel()
        return
      end
      opts.on_submit(resolved)
    end,
    on_cancel = function()
      on_cancel()
    end,
  })
end

-- Exposed for tests.
M._build_fields = build_fields
M._format_errors = format_errors

return M
