-- snipai top-level: composes the plugin from its leaf modules and
-- exposes the public surface.
--
-- setup(opts) resolves config defaults, constructs the event bus,
-- notifier, history, registry, and jobs manager, loads snippet
-- configs, wires the job_done -> buffer-refresh subscription, and
-- stashes everything in a module-local state table. Subsequent
-- setup() calls rebuild state.
--
-- Public surface:
--   snipai.setup(opts?)
--   snipai.trigger(name_or_snippet, ctx?)   -- delegates to snipai.trigger.run
--   snipai.reload()
--   snipai.jobs.list() / get(id) / cancel(id) / cancel_all()
--   snipai.history.list({scope}) / get(id) / clear()
--
-- Statusline integration lives in snipai.statusline (snipai.statusline.status).
-- Trigger dispatch (insert + auto-save + form + spawn) lives in snipai.trigger.
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
local trigger_mod = require("snipai.trigger")

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
-- trigger — thin wrapper around snipai.trigger (state-pure implementation)
-- ---------------------------------------------------------------------------

function M.trigger(name_or_snippet, ctx)
  ensure_initialized()
  return trigger_mod.run(state, name_or_snippet, ctx)
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
