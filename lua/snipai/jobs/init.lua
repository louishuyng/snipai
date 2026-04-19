-- Jobs manager: tracks the set of currently-running Job instances.
--
-- Responsibilities:
--   * render the snippet prompt from the caller's param values
--   * construct a Job with shared deps (runner / history / events / notify)
--   * call job:start() and retain it until job_done fires on the bus
--   * expose list / get / cancel for pickers and :SnipaiCancel
--
-- Finished jobs drop out of the active set automatically; their
-- canonical persistence is in history, not here.
--
-- Concurrency: not capped (phase-2 scope). Every :spawn makes a new
-- runner process. A concurrent-job cap can land later as a simple
-- length check against self._active before starting.

local job_mod = require("snipai.jobs.job")

local M = {}

local Manager = {}
Manager.__index = Manager

function M.new(opts)
  opts = opts or {}
  assert(type(opts.runner) == "table", "jobs manager requires opts.runner")
  assert(type(opts.history) == "table", "jobs manager requires opts.history")
  assert(type(opts.events) == "table", "jobs manager requires opts.events")
  assert(type(opts.notify) == "table", "jobs manager requires opts.notify")

  return setmetatable({
    _runner = opts.runner,
    _history = opts.history,
    _events = opts.events,
    _notify = opts.notify,
    _claude_opts = opts.claude_opts or {},
    _now = opts.now,
    _id = opts.id,
    _job_factory = opts.job_factory or job_mod.new,
    _active = {},
  }, Manager)
end

function Manager:spawn(snippet, params, ctx)
  assert(type(snippet) == "table", "spawn requires a snippet object")
  local builtins = ctx and ctx.builtins
  local prompt, render_err = snippet:render(params or {}, builtins)
  if prompt == nil then
    return nil, render_err
  end

  local job = self._job_factory({
    runner = self._runner,
    history = self._history,
    events = self._events,
    notify = self._notify,
    snippet = snippet,
    params = params or {},
    prompt = prompt,
    claude_opts = self._claude_opts,
    now = self._now,
    id = self._id,
  })

  -- Subscribe BEFORE start so a synchronous on_exit (fake runner in tests)
  -- still triggers auto-removal.
  local unsub
  unsub = self._events:subscribe("job_done", function(done_job)
    if done_job == job then
      self._active[job:id()] = nil
      if unsub then
        unsub()
        unsub = nil
      end
    end
  end)

  self._active[job:id()] = job
  local ok, start_err = job:start()
  if not ok then
    if unsub then
      unsub()
    end
    self._active[job:id()] = nil
    return nil, start_err
  end

  return job
end

function Manager:get(id)
  return self._active[id]
end

function Manager:list()
  local out = {}
  for _, job in pairs(self._active) do
    out[#out + 1] = job
  end
  return out
end

function Manager:count()
  local n = 0
  for _ in pairs(self._active) do
    n = n + 1
  end
  return n
end

function Manager:cancel(id)
  local job = self._active[id]
  if not job then
    return false, ("no active job with id %s"):format(tostring(id))
  end
  return job:cancel()
end

function Manager:cancel_all()
  local cancelled = 0
  for _, job in pairs(self._active) do
    if job:cancel() then
      cancelled = cancelled + 1
    end
  end
  return cancelled
end

return M
