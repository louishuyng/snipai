-- Job: one snippet execution, cradle to grave.
--
-- Owns the wiring between claude/runner, history, the event bus, and the
-- notifier for a single run. Everything else (pickers, UI, cmp source)
-- subscribes to the bus or reads history; it never pokes at Job state.
--
-- Lifecycle:
--   pending ──► running ⇄ idle ──► complete | cancelled | error
--
-- running↔idle flips on parser "result" events (turn done → idle;
-- any subsequent event → running). Terminal transitions fire in
-- :_on_exit() based on the PTY's exit code + cancelled flag.
--
-- files_changed accumulation:
--   Edit / Write / MultiEdit tool_use events carry an input.file_path.
--   We collect the set (deduplicated, insertion-ordered) and hand it to
--   history.finalize so :SnipaiToQuickfix can build qf entries later.
--
-- stderr policy:
--   * complete  -> persist, no notification
--   * error     -> persist, first non-blank stderr line (or "exit N")
--                  in the "failed" notification
--   * cancelled -> persist whatever was buffered before SIGTERM, but do
--                  not splice stderr into the notification (it's noise
--                  from the interrupt, not a real failure)
--
-- Injection:
--   opts.runner   module with runner.spawn(prompt, opts, on_event, on_exit)
--   opts.history  history object (add_pending / finalize)
--   opts.events   event bus (emits job_started / job_progress / job_done)
--   opts.notify   notifier (progress() returns a handle with update/finish)
--   opts.snippet  Snippet object (for .name / .prefix)
--   opts.params   resolved param values table
--   opts.prompt   rendered prompt string (already substituted)
--   opts.claude_opts  table passed through to runner.spawn
--   opts.now      () -> ms; defaults to os.time()*1000
--   opts.id       () -> string; defaults to hex-ms-randomish

local M = {}

-- ---------------------------------------------------------------------------
-- Tool whitelist for files_changed extraction
-- ---------------------------------------------------------------------------

local FILE_TOOLS = { Edit = true, Write = true, MultiEdit = true }

-- ---------------------------------------------------------------------------
-- Defaults
-- ---------------------------------------------------------------------------

local function default_now()
  return os.time() * 1000
end

local function default_id()
  local t = default_now()
  local r = math.random(0, 0xffffff)
  return string.format("%x-%06x", t, r)
end

-- ---------------------------------------------------------------------------
-- Formatting helpers (pure)
-- ---------------------------------------------------------------------------

local function format_duration(ms)
  if type(ms) ~= "number" or ms < 0 then
    return "?"
  end
  if ms < 1000 then
    return ("%dms"):format(ms)
  end
  local s = ms / 1000
  if s < 60 then
    return ("%.1fs"):format(s)
  end
  local mins = math.floor(s / 60)
  local rem = math.floor(s - mins * 60)
  return ("%dm%02ds"):format(mins, rem)
end

local function first_nonblank_line(s)
  if type(s) ~= "string" or s == "" then
    return nil
  end
  for line in s:gmatch("[^\n]*") do
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed and trimmed ~= "" then
      return trimmed
    end
  end
  return nil
end

local function success_message(files_changed, duration_ms)
  local n = #files_changed
  return ("%d file%s · %s"):format(n, n == 1 and "" or "s", format_duration(duration_ms))
end

local function error_message(stderr, code)
  local tail = first_nonblank_line(stderr)
  if tail then
    return "failed: " .. tail
  end
  return ("failed: exit %s"):format(tostring(code))
end

-- ---------------------------------------------------------------------------
-- Job class
-- ---------------------------------------------------------------------------

local Job = {}
Job.__index = Job

function M.new(opts)
  opts = opts or {}
  assert(type(opts.runner) == "table", "job requires opts.runner")
  assert(type(opts.history) == "table", "job requires opts.history")
  assert(type(opts.events) == "table", "job requires opts.events")
  assert(type(opts.notify) == "table", "job requires opts.notify")
  assert(type(opts.snippet) == "table", "job requires opts.snippet")
  assert(type(opts.prompt) == "string" and opts.prompt ~= "", "job requires opts.prompt")

  return setmetatable({
    _runner = opts.runner,
    _history = opts.history,
    _events = opts.events,
    _notify = opts.notify,
    _snippet = opts.snippet,
    _params = opts.params or {},
    _prompt = opts.prompt,
    _claude_opts = opts.claude_opts or {},
    _now = opts.now or default_now,
    _id = (opts.id or default_id)(),
    _cursor_file = opts.cursor_file,
    _status = "pending",
    _files_changed = {},
    _files_seen = {},
    _progress = nil,
    _handle = nil,
    _history_entry = nil,
    _started_at = nil,
    _exit_code = nil,
  }, Job)
end

-- ---------------------------------------------------------------------------
-- Read-only accessors
-- ---------------------------------------------------------------------------

function Job:id()
  return self._id
end

function Job:status()
  return self._status
end

function Job:snippet_name()
  return self._snippet.name
end

function Job:prefix()
  return self._snippet.prefix
end

function Job:params()
  return self._params
end

function Job:prompt()
  return self._prompt
end

function Job:files_changed()
  -- Return a shallow copy so callers can't mutate internal state.
  local out = {}
  for i, p in ipairs(self._files_changed) do
    out[i] = p
  end
  return out
end

-- Absolute path of the buffer the snippet was triggered from (may be nil
-- for programmatic / headless triggers). Captured once at spawn time so
-- statusline attribution works from the instant the job starts, before
-- any tool_use event has fired.
function Job:cursor_file()
  return self._cursor_file
end

function Job:started_at()
  return self._started_at
end

function Job:exit_code()
  return self._exit_code
end

function Job:history_entry()
  return self._history_entry
end

function Job:is_running()
  return self._status == "running" or self._status == "idle"
end

function Job:is_done()
  return self._status == "complete" or self._status == "cancelled" or self._status == "error"
end

function Job:session_id()
  return self._session_id
end

function Job:terminal_buf()
  if self._handle and type(self._handle.bufnr) == "function" then
    return self._handle:bufnr()
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function Job:start()
  if self._status ~= "pending" then
    return nil, ("job already %s"):format(self._status)
  end

  -- Mint the session id up front so history.add_pending writes it in
  -- the initial row (not a separate patch later). The runner accepts
  -- opts.session_id and uses it verbatim; if no runner exposes session
  -- ids (e.g. a hand-rolled fake runner in tests), the field is nil
  -- and downstream code treats the job as legacy.
  local claude_opts = self._claude_opts or {}
  local runner_has_session_ids = self._runner.generate_session_id ~= nil
  if runner_has_session_ids and not claude_opts.session_id then
    claude_opts = vim.tbl_extend("force", {}, claude_opts, {
      session_id = self._runner.generate_session_id(),
    })
  end
  self._session_id = claude_opts.session_id
  self._claude_opts = claude_opts

  self._started_at = self._now()
  local entry, err = self._history:add_pending({
    id = self._id,
    snippet = self._snippet.name,
    prefix = self._snippet.prefix,
    params = self._params,
    prompt = self._prompt,
    started_at = self._started_at,
    session_id = self._session_id,
  })
  if not entry then
    self._status = "error"
    return nil, err
  end
  self._history_entry = entry

  self._progress = self._notify:progress(self._snippet.name, "running…")
  self._status = "running"
  self._events:emit("job_started", self)

  self._handle = self._runner.spawn(self._prompt, claude_opts, function(evt)
    self:_on_event(evt)
  end, function(code, info)
    self:_on_exit(code, info)
  end)

  return self
end

function Job:cancel()
  if self._status ~= "running" then
    return false
  end
  if self._handle and type(self._handle.cancel) == "function" then
    return self._handle:cancel()
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Internal callbacks
-- ---------------------------------------------------------------------------

function Job:_track_file(evt)
  if evt.kind ~= "tool_use" then
    return
  end
  if not FILE_TOOLS[evt.tool] then
    return
  end
  local path = evt.input and evt.input.file_path
  if type(path) ~= "string" or path == "" then
    return
  end
  if self._files_seen[path] then
    return
  end
  self._files_seen[path] = true
  self._files_changed[#self._files_changed + 1] = path
end

function Job:_on_event(evt)
  -- Turn boundaries drive the running↔idle split. A "result" event
  -- ends the current turn; any later event means Claude is working
  -- again (the user typed a follow-up or the next turn started).
  if evt.kind == "result" and self._status == "running" then
    self._status = "idle"
  elseif evt.kind ~= "result" and self._status == "idle" then
    self._status = "running"
  end
  self:_track_file(evt)
  self._events:emit("job_progress", self, evt)
end

function Job:_classify(code, info)
  if info and info.cancelled then
    return "cancelled"
  end
  if code == 0 then
    return "complete"
  end
  return "error"
end

function Job:_on_exit(code, info)
  info = info or {}
  self._exit_code = code
  local status = self:_classify(code, info)
  self._status = status

  local duration_ms = self._now() - (self._started_at or self._now())

  local patch = {
    status = status,
    exit_code = code,
    duration_ms = duration_ms,
    files_changed = self:files_changed(),
    stderr = info.stderr,
  }
  if info.signal ~= nil then
    patch.signal = info.signal
  end
  if info.parser_errors and #info.parser_errors > 0 then
    patch.parser_errors = info.parser_errors
  end
  if info.error then
    patch.runner_error = info.error
  end
  if self._history_entry then
    self._history:finalize(self._history_entry.id, patch)
  end

  if self._progress then
    if status == "complete" then
      self._progress:finish(success_message(self._files_changed, duration_ms), "info")
    elseif status == "cancelled" then
      self._progress:finish("cancelled", "warn")
    else
      self._progress:finish(error_message(info.stderr, code), "error")
    end
  end

  self._events:emit("job_done", self, code)
end

-- Exposed for tests that want to verify formatting without spinning up
-- a Job instance.
M._format_duration = format_duration
M._first_nonblank_line = first_nonblank_line
M._success_message = success_message
M._error_message = error_message

return M
