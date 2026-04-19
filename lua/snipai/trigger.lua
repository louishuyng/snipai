-- trigger() — the entry point that turns "user picked a snippet" into
-- "Claude is running".
--
-- Extracted from init.lua so the top-level module stays focused on
-- setup / reload / facades. State is passed in explicitly (not module-
-- captured) so the function is self-contained and trivially swappable
-- in tests.
--
-- Dispatch:
--   ctx.params provided (even {}) -> spawn immediately; snippet:render
--       applies declared defaults for missing keys.
--   ctx.params nil AND snippet declares no params -> spawn immediately.
--   ctx.params nil AND snippet declares params -> open param form,
--       spawn on submit; user cancel returns (nil, nil) without error.
--
-- For `insert`-flavored snippets the plugin drops the rendered template
-- at ctx.replace_range (or the cursor, for programmatic callers) and
-- silently writes the buffer before calling jobs:spawn, so Claude has
-- an on-disk scaffold to Edit. Unnamed scratch buffers are refused up
-- front with an error notification.

local M = {}

local function resolve_snippet(state, name_or_snippet)
  if type(name_or_snippet) == "table" then
    return name_or_snippet
  end
  if type(name_or_snippet) ~= "string" or name_or_snippet == "" then
    return nil, "trigger requires a snippet name or object"
  end
  local s = state.registry:get(name_or_snippet)
  if not s then
    return nil, ("unknown snippet: %s"):format(name_or_snippet)
  end
  return s
end

local function snippet_has_params(snippet)
  return next(snippet.parameter or {}) ~= nil
end

-- When the snippet declares an `insert`, we need an on-disk file for
-- Claude to enrich; refuse up front on unnamed scratch buffers rather
-- than placing the template and then erroring at save time.
local function refuse_if_no_file(snippet, builtins)
  if snippet.insert == nil then
    return true
  end
  local path = builtins and builtins.cursor_file
  if path == nil or path == "" then
    return false, "save the buffer to disk first; snippet insert needs a file to enrich"
  end
  return true
end

-- Render + place the template at the cmp-captured range (falls back to
-- the current cursor for programmatic triggers), then silently write
-- the buffer. Returns (ok, err); on error nothing is spawned.
local function apply_insert(state, snippet, values, ctx)
  if snippet.insert == nil then
    return true
  end
  local text, render_err = snippet:render_insert(values, ctx.builtins)
  if text == nil then
    return false, tostring(render_err)
  end
  if ctx.buffer == nil then
    -- Headless / programmatic caller without buffer context — nothing
    -- to write into. Skip placement; body still runs as usual.
    return true
  end
  local range = ctx.replace_range
  if range == nil then
    local cursor = (ctx.builtins and ctx.builtins.cursor_line)
        and {
          row = ctx.builtins.cursor_line - 1,
          col = (ctx.builtins.cursor_col or 1) - 1,
        }
      or { row = 0, col = 0 }
    range = { start = cursor, ["end"] = cursor }
  end
  state.place_insert(ctx.buffer, range, text)
  state.save_buffer(ctx.buffer)
  return true
end

local function spawn_with_insert(state, snippet, values, ctx)
  local ok, err = apply_insert(state, snippet, values, ctx)
  if not ok then
    state.notify:notify("snipai: " .. err, "error")
    return nil, err
  end
  return state.jobs:spawn(snippet, values, ctx)
end

-- run(state, name_or_snippet, ctx?)
--   state is the snipai top-level state table (jobs / registry / notify
--   / param_form / place_insert / save_buffer / gather_builtins). Must
--   already be initialised; callers (init.lua) enforce that guard.
function M.run(state, name_or_snippet, ctx)
  ctx = ctx or {}
  local snippet, err = resolve_snippet(state, name_or_snippet)
  if not snippet then
    state.notify:notify(err, "error")
    return nil, err
  end

  -- Gather built-ins once, at trigger time, so cursor_file / line /
  -- col reflect where the user was when they picked the snippet — not
  -- where they end up after the param form steals focus.
  if ctx.builtins == nil then
    ctx.builtins = state.gather_builtins()
  end

  local ok, refuse_err = refuse_if_no_file(snippet, ctx.builtins)
  if not ok then
    state.notify:notify("snipai: " .. refuse_err, "error")
    return nil, refuse_err
  end

  if ctx.params ~= nil or not snippet_has_params(snippet) then
    return spawn_with_insert(state, snippet, ctx.params or {}, ctx)
  end

  -- Form-driven path. A synchronous form backend (tests, sequential
  -- vim.ui.input chain) still lets us return the spawned job; async
  -- popup backends leave the return value nil and callers can rely
  -- on the job_started event.
  local spawned_job, spawn_err
  state.param_form.open(snippet, {
    notify = state.notify,
    on_submit = function(values)
      spawned_job, spawn_err = spawn_with_insert(state, snippet, values, ctx)
    end,
    on_cancel = function() end,
  })
  return spawned_job, spawn_err
end

return M
