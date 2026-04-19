-- snipai top-level module: setup(), trigger(), reload(), and thin
-- facades over the jobs / history managers.
--
-- setup(opts) resolves config defaults, constructs the event bus,
-- notifier, history, registry, and jobs manager, loads snippet configs,
-- and stashes everything in a module-local state table. After setup,
-- the public surface is:
--
--   snipai.trigger(name_or_snippet, ctx?)
--   snipai.jobs.list() / get(id) / cancel(id) / cancel_all()
--   snipai.history.list({scope}) / get(id) / clear()
--   snipai.reload()
--
-- trigger() behaviour depends on whether the caller supplied params:
--   * ctx.params provided (even empty {}) -> spawn immediately, letting
--     snippet:render apply declared defaults for any missing keys.
--   * ctx.params nil AND snippet declares params -> open the param form
--     and spawn on submit; user cancel or validation failure returns no
--     job and does not error.
--   * ctx.params nil AND snippet declares no params -> spawn immediately.
--
-- Testing: pass opts._deps to inject any or all of { env, events,
-- notify, history, registry, jobs, runner, reader, json_decode,
-- param_form, gather_builtins, place_insert, save_buffer,
-- refresh_buffers }. Not part of the public API; leading underscore
-- signals internal.

local config = require("snipai.config")
local events_mod = require("snipai.events")
local notify_mod = require("snipai.notify")
local history_mod = require("snipai.history")
local registry_mod = require("snipai.registry")
local jobs_mod = require("snipai.jobs")
local param_form_mod = require("snipai.ui.param_form")

-- ---------------------------------------------------------------------------
-- Built-in context + buffer helpers (injectable via _deps for tests)
-- ---------------------------------------------------------------------------

local function default_gather_builtins()
  local cursor = vim.api.nvim_win_get_cursor(0)
  return {
    cursor_file = vim.api.nvim_buf_get_name(0),
    cursor_line = cursor[1],
    cursor_col = cursor[2] + 1,
    cwd = vim.fn.getcwd(),
  }
end

local function default_place_insert(buffer, range, text)
  local lines = vim.split(text, "\n", { plain = true })
  vim.api.nvim_buf_set_text(
    buffer,
    range.start.row,
    range.start.col,
    range["end"].row,
    range["end"].col,
    lines
  )
end

local function default_save_buffer(buffer)
  vim.api.nvim_buf_call(buffer, function()
    vim.cmd("silent write")
  end)
end

-- Why this exists: Claude's Edit / Write tools land on disk, but Neovim
-- does not auto-reload open buffers pointing at those files — they keep
-- showing the pre-Claude content until the user hits :e!. :checktime
-- per touched file makes the enrichment visible immediately. Buffers
-- whose file Claude never touched, and files the user never opened,
-- are skipped — nothing to reload in either case.
local function default_refresh_buffers(files_changed)
  if files_changed == nil or #files_changed == 0 then
    return
  end
  local touched = {}
  for _, path in ipairs(files_changed) do
    touched[path] = true
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" and touched[name] then
        vim.api.nvim_buf_call(buf, function()
          vim.cmd("silent! checktime")
        end)
      end
    end
  end
end

local M = {}

-- ---------------------------------------------------------------------------
-- Module-local state
-- ---------------------------------------------------------------------------

local state = {
  opts = nil,
  events = nil,
  notify = nil,
  history = nil,
  registry = nil,
  jobs = nil,
  param_form = nil,
  gather_builtins = nil,
  place_insert = nil,
  save_buffer = nil,
  refresh_buffers = nil,
  _initialized = false,
}

local function ensure_initialized()
  assert(state._initialized, "snipai.setup() must be called before this API")
end

-- ---------------------------------------------------------------------------
-- setup
-- ---------------------------------------------------------------------------

function M.setup(opts)
  opts = opts or {}
  -- _deps is an internal escape hatch for tests; pull it off before the
  -- table reaches config.merge so it can't leak into user-visible config.
  local deps = opts._deps or {}
  opts._deps = nil

  local merged = config.merge(opts, deps.env)

  local events = deps.events or events_mod.new()
  local notify = deps.notify or notify_mod.new({
    backend = merged.ui.notify,
  })

  local history = deps.history
    or history_mod.new({
      path = merged.history.path,
      max_entries = merged.history.max_entries,
      per_project = merged.history.per_project,
    })

  local registry = deps.registry
    or registry_mod.new({
      reader = deps.reader,
      json_decode = deps.json_decode,
      on_warning = function(msg)
        notify:notify("snipai: " .. msg, "warn")
      end,
    })
  registry:load(merged.config_paths)

  local jobs = deps.jobs
    or jobs_mod.new({
      runner = deps.runner or require("snipai.claude.runner"),
      history = history,
      events = events,
      notify = notify,
      claude_opts = merged.claude,
    })

  state.opts = merged
  state.events = events
  state.notify = notify
  state.history = history
  state.registry = registry
  state.jobs = jobs
  state.param_form = deps.param_form or param_form_mod
  state.gather_builtins = deps.gather_builtins or default_gather_builtins
  state.place_insert = deps.place_insert or default_place_insert
  state.save_buffer = deps.save_buffer or default_save_buffer
  state.refresh_buffers = deps.refresh_buffers or default_refresh_buffers
  state._initialized = true

  -- Subscribe once: every finished job hands its files_changed list to
  -- the refresh step so open buffers reload from disk after Claude's
  -- Edit / Write land. Each setup() call binds to a fresh events bus,
  -- so dropping the previous subscription is unnecessary.
  events:subscribe("job_done", function(job)
    local files = job and type(job.files_changed) == "function" and job:files_changed() or {}
    state.refresh_buffers(files)
  end)

  return M
end

-- ---------------------------------------------------------------------------
-- trigger
-- ---------------------------------------------------------------------------

local function resolve_snippet(name_or_snippet)
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
local function apply_insert(snippet, values, ctx)
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

local function spawn_with_insert(snippet, values, ctx)
  local ok, err = apply_insert(snippet, values, ctx)
  if not ok then
    state.notify:notify("snipai: " .. err, "error")
    return nil, err
  end
  return state.jobs:spawn(snippet, values, ctx)
end

function M.trigger(name_or_snippet, ctx)
  ensure_initialized()
  ctx = ctx or {}
  local snippet, err = resolve_snippet(name_or_snippet)
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
    return spawn_with_insert(snippet, ctx.params or {}, ctx)
  end

  -- Form-driven path. A synchronous form backend (tests, sequential
  -- vim.ui.input chain) still lets us return the spawned job; async
  -- popup backends leave the return value nil and callers can rely
  -- on the job_started event.
  local spawned_job, spawn_err
  state.param_form.open(snippet, {
    notify = state.notify,
    on_submit = function(values)
      spawned_job, spawn_err = spawn_with_insert(snippet, values, ctx)
    end,
    on_cancel = function() end,
  })
  return spawned_job, spawn_err
end

-- ---------------------------------------------------------------------------
-- reload
-- ---------------------------------------------------------------------------

function M.reload()
  ensure_initialized()
  state.registry:reload()
  return M
end

-- ---------------------------------------------------------------------------
-- Facade: snipai.jobs.*
-- ---------------------------------------------------------------------------

M.jobs = {}

function M.jobs.list()
  ensure_initialized()
  return state.jobs:list()
end

function M.jobs.get(id)
  ensure_initialized()
  return state.jobs:get(id)
end

function M.jobs.cancel(id)
  ensure_initialized()
  return state.jobs:cancel(id)
end

function M.jobs.cancel_all()
  ensure_initialized()
  return state.jobs:cancel_all()
end

-- ---------------------------------------------------------------------------
-- Facade: snipai.history.*
-- ---------------------------------------------------------------------------

M.history = {}

function M.history.list(o)
  ensure_initialized()
  return state.history:list(o)
end

function M.history.get(id)
  ensure_initialized()
  return state.history:get(id)
end

function M.history.clear()
  ensure_initialized()
  return state.history:clear()
end

-- ---------------------------------------------------------------------------
-- Exposed for plugin/snipai.lua command completion and tests.
-- ---------------------------------------------------------------------------

M._state = state

-- Test-only: reset state between setup() calls. Not called by production.
function M._reset()
  state.opts = nil
  state.events = nil
  state.notify = nil
  state.history = nil
  state.registry = nil
  state.jobs = nil
  state.param_form = nil
  state.gather_builtins = nil
  state.place_insert = nil
  state.save_buffer = nil
  state.refresh_buffers = nil
  state._initialized = false
end

return M
