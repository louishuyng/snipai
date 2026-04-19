-- Claude CLI runner: spawns `claude -p <prompt> --output-format stream-json
-- --verbose`, feeds stdout chunks through snipai.claude.parser, and emits
-- normalized events to the caller.
--
-- Contract:
--   spawn(prompt, opts, on_event, on_exit) -> handle
--     on_event(evt)     fires per parsed event (may fan multiple per chunk)
--     on_exit(code,info) fires exactly once; info = {
--                          signal, stderr, parser_errors, cancelled, error }
--     handle:cancel()    SIGTERMs the process; on_exit still fires
--     handle:is_cancelled() / handle:is_done()
--
-- Injection seams (all in opts; fall back to live vim.* in production):
--   opts.system      replaces vim.system for tests
--   opts.scheduler   replaces vim.schedule (pass-through fn in sync tests)
--   opts.parser_new  replaces snipai.claude.parser.new (for parser stubs)
--
-- vim.system streams stdout via its `stdout` callback; when that callback
-- is set, out.stdout on completion is empty, so the runner owns its own
-- stderr buffer and parser-error accumulator.
--
-- Cancellation semantics: once :cancel() has been called, further parsed
-- events are dropped even if late stdout arrives before SIGTERM takes
-- effect. on_exit still fires, with cancelled=true in info.

local parser_mod = require("snipai.claude.parser")

local M = {}

local DEFAULT_CMD = "claude"
local STREAM_ARGS = { "--output-format", "stream-json", "--verbose" }

-- ---------------------------------------------------------------------------
-- argv
-- ---------------------------------------------------------------------------

local function build_argv(prompt, opts)
  local argv = { opts.cmd or DEFAULT_CMD, "-p", prompt }
  for _, a in ipairs(STREAM_ARGS) do
    argv[#argv + 1] = a
  end
  if type(opts.extra_args) == "table" then
    for _, a in ipairs(opts.extra_args) do
      argv[#argv + 1] = a
    end
  end
  return argv
end

-- ---------------------------------------------------------------------------
-- Defaults
-- ---------------------------------------------------------------------------

local function default_scheduler(fn)
  if vim and vim.schedule then
    vim.schedule(fn)
  else
    fn()
  end
end

local function resolve_system(opts)
  if opts.system ~= nil then
    return opts.system
  end
  if vim and vim.system then
    return vim.system
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Handle
-- ---------------------------------------------------------------------------

local Handle = {}
Handle.__index = Handle

function Handle:cancel()
  if self._cancelled or self._done then
    return false
  end
  self._cancelled = true
  if self._sysobj and type(self._sysobj.kill) == "function" then
    -- SIGTERM (15). Job layer will see the on_exit callback flip
    -- cancelled=true and route through history.finalize as "cancelled".
    self._sysobj:kill(15)
  end
  return true
end

function Handle:is_cancelled()
  return self._cancelled == true
end

function Handle:is_done()
  return self._done == true
end

function Handle:pid()
  if self._sysobj and type(self._sysobj.pid) == "function" then
    return self._sysobj:pid()
  end
  if self._sysobj and type(self._sysobj.pid) == "number" then
    return self._sysobj.pid
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- spawn
-- ---------------------------------------------------------------------------

function M.spawn(prompt, opts, on_event, on_exit)
  opts = opts or {}
  assert(type(prompt) == "string" and prompt ~= "", "prompt must be a non-empty string")
  assert(type(on_event) == "function", "on_event must be a function")
  assert(type(on_exit) == "function", "on_exit must be a function")

  local system = resolve_system(opts)
  assert(type(system) == "function", "vim.system not available (and none injected via opts.system)")
  local scheduler = opts.scheduler or default_scheduler
  local parser_new = opts.parser_new or parser_mod.new

  local parser = parser_new()
  local handle = setmetatable({
    _cancelled = false,
    _done = false,
  }, Handle)

  local stderr_parts = {}
  local parser_errors = {}

  local function emit(evt)
    if handle._cancelled then
      return
    end
    scheduler(function()
      on_event(evt)
    end)
  end

  local function drain(events, errs)
    for _, e in ipairs(events or {}) do
      emit(e)
    end
    for _, e in ipairs(errs or {}) do
      parser_errors[#parser_errors + 1] = e
    end
  end

  local function on_stdout(err, data)
    if err then
      stderr_parts[#stderr_parts + 1] = ("[stdout callback error] %s\n"):format(tostring(err))
      return
    end
    if data == nil then
      return -- EOF; flush happens in on_exit
    end
    drain(parser:feed(data))
  end

  local function on_stderr(err, data)
    if err or data == nil then
      return
    end
    stderr_parts[#stderr_parts + 1] = data
  end

  local function finalize(completed)
    drain(parser:flush())
    handle._done = true
    local code
    if type(completed) == "table" then
      code = completed.code
    else
      code = completed
    end
    local signal = type(completed) == "table" and completed.signal or nil
    scheduler(function()
      on_exit(code or 0, {
        signal = signal,
        stderr = table.concat(stderr_parts, ""),
        parser_errors = parser_errors,
        cancelled = handle._cancelled,
      })
    end)
  end

  local ok, sysobj_or_err = pcall(system, build_argv(prompt, opts), {
    stdout = on_stdout,
    stderr = on_stderr,
    text = true,
    timeout = opts.timeout_ms,
  }, finalize)

  if not ok then
    -- Synthesize a failure on_exit so callers see the full lifecycle even
    -- when vim.system itself raises (e.g. argv validation blew up).
    handle._done = true
    scheduler(function()
      on_exit(-1, {
        error = tostring(sysobj_or_err),
        stderr = "",
        parser_errors = {},
        cancelled = false,
      })
    end)
    return handle
  end

  handle._sysobj = sysobj_or_err
  return handle
end

-- Exposed so tests (and fake runners) can see the same argv template.
M._STREAM_ARGS = STREAM_ARGS
M._build_argv = build_argv

return M
