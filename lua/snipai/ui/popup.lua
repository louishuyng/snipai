-- UI backend facade for collecting typed parameter values.
--
-- Wraps `vim.ui.input` and `vim.ui.select` so Neovim's existing UI-override
-- ecosystem (dressing.nvim, snacks.nvim, telescope-ui-select, ...) can
-- upgrade the UX transparently. No hard dependency on any popup library.
--
-- The collection is sequential — one prompt per field, chained by callback.
-- A richer multi-field popup backend (e.g. nui.nvim) can plug in behind
-- this same `collect()` API later without changing callers.
--
-- Both vim.ui.* functions are injectable so tests can stub the whole
-- interaction without touching the real APIs.

local M = {}

local BOOL_OPTIONS = { "true", "false" }

local function field_label(field)
  return field.label or field.name
end

local function prompt_for(field)
  local label = field_label(field)
  if field.default ~= nil then
    return ("%s (default: %s)"):format(label, tostring(field.default))
  end
  return label
end

-- Dispatch a single field to vim.ui.input or vim.ui.select. On cancel the
-- backend passes nil; on confirm it passes the selected value (or empty
-- string, which is distinct from cancel).
local function run_field(field, ui, done)
  local t = field.type

  if t == "select" then
    ui.select(field.options or {}, {
      prompt = prompt_for(field),
      format_item = field.format_item,
    }, done)
    return
  end

  if t == "boolean" then
    ui.select(BOOL_OPTIONS, { prompt = prompt_for(field) }, function(choice)
      if choice == nil then
        done(nil)
      else
        done(choice == "true")
      end
    end)
    return
  end

  -- string / text: single-line input in the default backend; a richer
  -- vim.ui override (dressing.nvim, etc.) can turn this into a popup or
  -- multi-line editor without us caring.
  ui.input({
    prompt = prompt_for(field) .. ": ",
    default = field.default and tostring(field.default) or nil,
  }, done)
end

-- Collect values for an ordered list of typed fields.
--
-- fields[i] = {
--   name    = "goal",
--   type    = "string" | "text" | "select" | "boolean",
--   label   = "Goal",                -- optional, defaults to name
--   default = "improve tests",       -- optional
--   options = { "a", "b" },          -- required for type = "select"
--   format_item = function(item) end,-- optional, passed to vim.ui.select
-- }
--
-- opts.on_submit(values)  is called with { [name] = value, ... } when every
--                         field is answered (empty string IS a valid answer).
-- opts.on_cancel()        is called the first time a field returns nil
--                         (user pressed <Esc> / cancelled the prompt).
--
-- opts.ui_input / opts.ui_select are test seams; default to vim.ui.input /
-- vim.ui.select. If neither is injected and vim.ui is unavailable (pure-
-- Lua environment), collect() asserts rather than silently doing nothing.
function M.collect(fields, opts)
  opts = opts or {}
  local ui = {
    input = opts.ui_input or (vim and vim.ui and vim.ui.input),
    select = opts.ui_select or (vim and vim.ui and vim.ui.select),
  }
  assert(type(ui.input) == "function", "popup.collect: vim.ui.input unavailable")
  assert(type(ui.select) == "function", "popup.collect: vim.ui.select unavailable")

  local on_submit = opts.on_submit or function(_) end
  local on_cancel = opts.on_cancel or function() end

  fields = fields or {}
  if #fields == 0 then
    on_submit({})
    return
  end

  local collected = {}

  local function step(index)
    if index > #fields then
      on_submit(collected)
      return
    end
    local field = fields[index]
    run_field(field, ui, function(value)
      if value == nil then
        on_cancel()
        return
      end
      collected[field.name] = value
      step(index + 1)
    end)
  end

  step(1)
end

return M
