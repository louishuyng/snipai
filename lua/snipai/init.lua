-- snipai top-level: composes the plugin from its leaf modules and
-- exposes the public surface.
--
-- setup(opts) resolves config defaults, constructs the event bus,
-- notifier, history, registry, and jobs manager, loads snippet
-- configs, wires the statusline spinner + buffer-refresh subscribers,
-- installs default keymaps, and stashes everything in a module-local
-- state table. Subsequent setup() calls rebuild state.
--
-- This file intentionally stays composition-only: Neovim-side defaults
-- for trigger live in snipai.trigger; the job_done → :checktime
-- subscription lives in snipai.buffer_refresh.attach.
--
-- Public surface:
--   snipai.setup(opts?)
--   snipai.trigger(name_or_snippet, ctx?)   -- delegates to snipai.trigger.run
--   snipai.reload()
--   snipai.jobs.list() / get(id) / cancel(id) / cancel_all()
--   snipai.history.list({scope}) / get(id) / clear() / to_quickfix(id)
--
-- Testing: pass opts._deps to inject any or all of { env, events,
-- notify, history, registry, jobs, runner, reader, json_decode,
-- param_form, gather_builtins, place_insert, save_buffer,
-- refresh_buffers, keymap_set }. Not part of the public API; leading
-- underscore signals internal.

local config = require("snipai.config")
local events_mod = require("snipai.events")
local notify_mod = require("snipai.notify")
local history_mod = require("snipai.history")
local registry_mod = require("snipai.registry")
local jobs_mod = require("snipai.jobs")
local param_form_mod = require("snipai.ui.param_form")
local trigger_mod = require("snipai.trigger")
local statusline_mod = require("snipai.statusline")
local keymaps_mod = require("snipai.keymaps")
local buffer_refresh_mod = require("snipai.buffer_refresh")

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
  -- Trigger-side hooks pipe straight through; nil triggers trigger.lua's
  -- own defaults. No need for this module to know about cursor, buffer
  -- edits, or file save.
  state.gather_builtins = deps.gather_builtins
  state.place_insert = deps.place_insert
  state.save_buffer = deps.save_buffer
  state._initialized = true

  -- Each setup() rebuilds subscribers against the fresh events bus.
  buffer_refresh_mod.attach(events, deps.refresh_buffers)
  statusline_mod.attach(events)

  -- Default <leader>sr / <leader>sh / <leader>sH mappings. Skipped
  -- entirely if setup({ keymaps = false }); individual keys can be
  -- turned off via setup({ keymaps = { running = false } }). A repeat
  -- setup() call re-applies — vim.keymap.set overwrites the previous
  -- binding for the same lhs, so no cleanup needed.
  keymaps_mod.apply(merged.keymaps, { keymap_set = deps.keymap_set })

  -- Soft-stop active PTY sessions when Neovim quits, so no orphan
  -- `claude` processes survive the editor. The autocmd is idempotent:
  -- a re-setup replaces the group.
  if vim and vim.api and vim.api.nvim_create_augroup then
    local group = vim.api.nvim_create_augroup("snipai_cleanup", { clear = true })
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = group,
      callback = function()
        M._on_vim_leave_pre()
      end,
    })
  end

  return M
end

function M._on_vim_leave_pre()
  if state.jobs and type(state.jobs.cancel_all) == "function" then
    state.jobs:cancel_all()
  end
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

function M.history.to_quickfix(id)
  ensure_initialized()
  return state.history:to_quickfix(id)
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
  state._initialized = false
end

return M
