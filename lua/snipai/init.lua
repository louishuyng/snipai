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
-- param_form }. Not part of the public API; leading underscore
-- signals internal.

local config = require("snipai.config")
local events_mod = require("snipai.events")
local notify_mod = require("snipai.notify")
local history_mod = require("snipai.history")
local registry_mod = require("snipai.registry")
local jobs_mod = require("snipai.jobs")
local param_form_mod = require("snipai.ui.param_form")

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
  local notify = deps.notify
    or notify_mod.new({
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
  state._initialized = true

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

function M.trigger(name_or_snippet, ctx)
  ensure_initialized()
  ctx = ctx or {}
  local snippet, err = resolve_snippet(name_or_snippet)
  if not snippet then
    state.notify:notify(err, "error")
    return nil, err
  end

  if ctx.params ~= nil or not snippet_has_params(snippet) then
    return state.jobs:spawn(snippet, ctx.params or {}, ctx)
  end

  -- Form-driven path. If the form backend submits synchronously (tests,
  -- sequential vim.ui.input chains) we can still return the spawned job
  -- to the caller; an async popup backend leaves the return value nil.
  local spawned_job, spawn_err
  state.param_form.open(snippet, {
    notify = state.notify,
    on_submit = function(values)
      spawned_job, spawn_err = state.jobs:spawn(snippet, values, ctx)
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
  state._initialized = false
end

return M
