local job_mod = require("snipai.jobs.job")
local history_mod = require("snipai.history")
local events_mod = require("snipai.events")
local notify_mod = require("snipai.notify")
local snippet_mod = require("snipai.snippet")
local json = require("tests.helpers.json")

-- ---------------------------------------------------------------------------
-- Fakes
-- ---------------------------------------------------------------------------

local function new_in_memory_fs(seed)
  local files = {}
  for k, v in pairs(seed or {}) do
    files[k] = v
  end
  return {
    _files = files,
    read_all = function(path)
      if files[path] == nil then
        return nil, "No such file"
      end
      return files[path]
    end,
    append = function(path, text)
      files[path] = (files[path] or "") .. text
      return true
    end,
    write_all = function(path, text)
      files[path] = text
      return true
    end,
    remove = function(path)
      files[path] = nil
      return true
    end,
    mkdir_p = function()
      return true
    end,
  }
end

local function new_history()
  return history_mod.new({
    path = "/history.jsonl",
    fs = new_in_memory_fs(),
    json_encode = json.encode,
    json_decode = json.decode,
    cwd = "/proj",
    now = (function()
      local t = 0
      return function()
        t = t + 1
        return 10000 + t
      end
    end)(),
  })
end

-- Fake runner: records spawn invocations and exposes a driver per spawn.
local function new_fake_runner()
  local rec = { spawns = {} }
  rec.spawn = function(prompt, opts, on_event, on_exit)
    local slot = {
      prompt = prompt,
      opts = opts,
      on_event = on_event,
      on_exit = on_exit,
      cancelled = false,
      kill_calls = 0,
    }
    slot.handle = {
      cancel = function(self)
        slot.cancelled = true
        slot.kill_calls = slot.kill_calls + 1
        return true
      end,
      is_cancelled = function()
        return slot.cancelled
      end,
    }
    rec.spawns[#rec.spawns + 1] = slot
    return slot.handle
  end
  rec.last = function()
    return rec.spawns[#rec.spawns]
  end
  return rec
end

-- Recording notifier backend.
local function new_recording_notify()
  local calls = {}
  local notify = notify_mod.new({
    backend = function(msg, level, opts)
      calls[#calls + 1] = { msg = msg, level = level, opts = opts }
    end,
    levels = { TRACE = 0, DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4, OFF = 5 },
  })
  return notify, calls
end

-- Deterministic id + clock for Job.
local function counter_id(prefix)
  local n = 0
  return function()
    n = n + 1
    return (prefix or "job") .. "-" .. tostring(n)
  end
end

local function fake_clock(start, step)
  local t = start or 1000
  local s = step or 500
  return function()
    local out = t
    t = t + s
    return out
  end
end

local function make_snippet()
  local s = snippet_mod.new("sample_snippet", {
    prefix = "sa",
    body = "generate a thing for {{name}}",
    parameter = { name = { type = "string" } },
  })
  assert(s:validate())
  return s
end

local function make_job(overrides)
  overrides = overrides or {}
  local events = overrides.events or events_mod.new()
  local history = overrides.history or new_history()
  local notify, notify_calls = new_recording_notify()
  local runner = overrides.runner or new_fake_runner()
  local snippet = overrides.snippet or make_snippet()
  local prompt = overrides.prompt or snippet:render({ name = "x" })

  local job = job_mod.new({
    runner = runner,
    history = history,
    events = events,
    notify = notify,
    snippet = snippet,
    params = overrides.params or { name = "x" },
    prompt = prompt,
    claude_opts = overrides.claude_opts or { cmd = "claude" },
    now = overrides.now or fake_clock(1000, 500),
    id = overrides.id or counter_id(),
  })

  return job, {
    events = events,
    history = history,
    notify_calls = notify_calls,
    runner = runner,
  }
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

describe("snipai.jobs.job", function()
  describe("formatting helpers", function()
    it("format_duration renders ms, seconds, and minutes", function()
      assert.equals("42ms", job_mod._format_duration(42))
      assert.equals("1.5s", job_mod._format_duration(1500))
      assert.equals("1m23s", job_mod._format_duration(83 * 1000))
      assert.equals("?", job_mod._format_duration(-1))
      assert.equals("?", job_mod._format_duration("nope"))
    end)

    it("first_nonblank_line returns the first line with content", function()
      assert.equals("bar", job_mod._first_nonblank_line("\n\n  \nbar\nbaz"))
      assert.is_nil(job_mod._first_nonblank_line(""))
      assert.is_nil(job_mod._first_nonblank_line("   \n\n"))
    end)

    it("success_message pluralizes files and formats duration", function()
      assert.equals("0 files · 1.2s", job_mod._success_message({}, 1200))
      assert.equals("1 file · 500ms", job_mod._success_message({ "a" }, 500))
      assert.equals("3 files · 2.5s", job_mod._success_message({ "a", "b", "c" }, 2500))
    end)

    it("error_message uses first stderr line, falling back to exit code", function()
      assert.equals("failed: permission denied", job_mod._error_message("permission denied\n", 1))
      assert.equals("failed: exit 2", job_mod._error_message("", 2))
      assert.equals("failed: exit 7", job_mod._error_message("   \n", 7))
    end)
  end)

  describe("construction", function()
    it("rejects missing deps", function()
      assert.has_error(function()
        job_mod.new({})
      end)
    end)

    it("starts in pending state with a stable id", function()
      local job = make_job({ id = counter_id("run") })
      assert.equals("run-1", job:id())
      assert.equals("pending", job:status())
      assert.is_false(job:is_running())
      assert.is_false(job:is_done())
    end)
  end)

  describe("start", function()
    it("writes a pending history row and spawns the runner", function()
      local job, deps = make_job({ id = counter_id("run") })
      assert.truthy(job:start())
      assert.equals("running", job:status())
      assert.is_true(job:is_running())

      local entry = deps.history:get("run-1")
      assert.equals("running", entry.status)
      assert.equals("sample_snippet", entry.snippet)
      assert.equals("sa", entry.prefix)

      local spawn = deps.runner.last()
      assert.truthy(spawn)
      assert.equals("generate a thing for x", spawn.prompt)
      assert.equals("claude", spawn.opts.cmd)
    end)

    it("emits job_started on the bus", function()
      local bus = events_mod.new()
      local received = {}
      bus:subscribe("job_started", function(j)
        received[#received + 1] = j
      end)
      local job = make_job({ events = bus })
      job:start()
      assert.equals(1, #received)
      assert.equals(job, received[1])
    end)

    it("opens a progress notification with the snippet name", function()
      local job, deps = make_job()
      job:start()
      assert.equals(1, #deps.notify_calls)
      assert.equals("sample_snippet: running…", deps.notify_calls[1].msg)
    end)

    it("refuses to start a second time", function()
      local job = make_job()
      job:start()
      local ok, err = job:start()
      assert.is_nil(ok)
      assert.matches("already", err)
    end)
  end)

  describe("success path", function()
    it("finalizes history with status=success, duration, and files_changed", function()
      local job, deps = make_job({
        id = counter_id("r"),
        now = fake_clock(1000, 500),
      })
      job:start()
      local spawn = deps.runner.last()

      spawn.on_event({ kind = "tool_use", tool = "Edit", input = { file_path = "src/a.ts" } })
      spawn.on_event({ kind = "tool_use", tool = "Write", input = { file_path = "src/a.test.ts" } })
      spawn.on_event({
        kind = "result",
        status = "success",
        duration_ms = 1234,
        usage = { input_tokens = 10 },
      })
      spawn.on_exit(0, { cancelled = false, stderr = "", parser_errors = {}, signal = nil })

      assert.equals("success", job:status())
      local entry = deps.history:get("r-1")
      assert.equals("success", entry.status)
      assert.equals(0, entry.exit_code)
      assert.are.same({ "src/a.ts", "src/a.test.ts" }, entry.files_changed)
      -- now() fired at: start(1000) start_at_ms=1000; history now fires during
      -- add_pending but history has its own injected clock — job.now is separate
      assert.truthy(entry.duration_ms)
    end)

    it("deduplicates repeated file paths across events", function()
      local job, deps = make_job()
      job:start()
      local spawn = deps.runner.last()
      spawn.on_event({ kind = "tool_use", tool = "Edit", input = { file_path = "src/x.ts" } })
      spawn.on_event({ kind = "tool_use", tool = "Edit", input = { file_path = "src/x.ts" } })
      spawn.on_event({ kind = "tool_use", tool = "Write", input = { file_path = "src/y.ts" } })
      spawn.on_exit(0, { cancelled = false, stderr = "", parser_errors = {} })
      assert.are.same({ "src/x.ts", "src/y.ts" }, job:files_changed())
    end)

    it("ignores non-file tool_use events (Bash, Glob, etc.)", function()
      local job, deps = make_job()
      job:start()
      local spawn = deps.runner.last()
      spawn.on_event({ kind = "tool_use", tool = "Bash", input = { command = "npm test" } })
      spawn.on_event({ kind = "tool_use", tool = "Glob", input = { pattern = "**/*.ts" } })
      spawn.on_exit(0, { cancelled = false, stderr = "", parser_errors = {} })
      assert.are.same({}, job:files_changed())
    end)

    it("emits job_done with the job and exit code on the bus", function()
      local bus = events_mod.new()
      local recv
      bus:subscribe("job_done", function(j, code)
        recv = { j = j, code = code }
      end)
      local job, deps = make_job({ events = bus })
      job:start()
      deps.runner.last().on_exit(0, { cancelled = false, stderr = "", parser_errors = {} })
      assert.equals(job, recv.j)
      assert.equals(0, recv.code)
    end)

    it("finishes the notification with a success message", function()
      local job, deps = make_job()
      job:start()
      local spawn = deps.runner.last()
      spawn.on_event({ kind = "tool_use", tool = "Edit", input = { file_path = "src/a.ts" } })
      spawn.on_exit(0, { cancelled = false, stderr = "", parser_errors = {} })
      -- progress:update on start + progress:finish on exit
      assert.equals(2, #deps.notify_calls)
      assert.matches("1 file", deps.notify_calls[2].msg)
      assert.equals(2, deps.notify_calls[2].level) -- INFO
    end)

    it("emits job_progress for every event", function()
      local bus = events_mod.new()
      local progress_count = 0
      bus:subscribe("job_progress", function()
        progress_count = progress_count + 1
      end)
      local job, deps = make_job({ events = bus })
      job:start()
      local spawn = deps.runner.last()
      spawn.on_event({ kind = "assistant_text", text = "hi" })
      spawn.on_event({ kind = "tool_use", tool = "Edit", input = { file_path = "x" } })
      spawn.on_event({ kind = "result", status = "success" })
      spawn.on_exit(0, { cancelled = false, stderr = "", parser_errors = {} })
      assert.equals(3, progress_count)
    end)
  end)

  describe("error path", function()
    it("classifies non-zero exit as error and surfaces stderr in notification", function()
      local job, deps = make_job()
      job:start()
      local spawn = deps.runner.last()
      spawn.on_exit(1, { cancelled = false, stderr = "auth failed\nsecond line\n", parser_errors = {} })

      assert.equals("error", job:status())
      local entry = deps.history:get(job:id())
      assert.equals("error", entry.status)
      assert.equals(1, entry.exit_code)
      assert.equals("auth failed\nsecond line\n", entry.stderr)
      -- notification uses the first stderr line
      local finish = deps.notify_calls[#deps.notify_calls]
      assert.matches("failed: auth failed", finish.msg)
      assert.equals(4, finish.level) -- ERROR
    end)

    it("falls back to 'exit N' when stderr is empty", function()
      local job, deps = make_job()
      job:start()
      deps.runner.last().on_exit(2, { cancelled = false, stderr = "", parser_errors = {} })
      local finish = deps.notify_calls[#deps.notify_calls]
      assert.equals("sample_snippet: failed: exit 2", finish.msg)
    end)

    it("captures runner_error when vim.system raised", function()
      local job, deps = make_job()
      job:start()
      deps.runner.last().on_exit(-1, {
        cancelled = false,
        stderr = "",
        parser_errors = {},
        error = "boom",
      })
      local entry = deps.history:get(job:id())
      assert.equals("boom", entry.runner_error)
      assert.equals("error", entry.status)
    end)
  end)

  describe("cancel path", function()
    it("routes through history.finalize with status='cancelled'", function()
      local job, deps = make_job()
      job:start()
      assert.is_true(job:cancel())

      -- runner would normally deliver on_exit after SIGTERM
      deps.runner.last().on_exit(nil, { cancelled = true, stderr = "", parser_errors = {}, signal = 15 })

      assert.equals("cancelled", job:status())
      local entry = deps.history:get(job:id())
      assert.equals("cancelled", entry.status)
      assert.equals(15, entry.signal)
    end)

    it("uses a 'cancelled' notification without splicing stderr", function()
      local job, deps = make_job()
      job:start()
      job:cancel()
      deps.runner.last().on_exit(nil, {
        cancelled = true,
        stderr = "terminated: signal 15\n",
        parser_errors = {},
      })
      local finish = deps.notify_calls[#deps.notify_calls]
      assert.equals("sample_snippet: cancelled", finish.msg)
      assert.equals(3, finish.level) -- WARN
    end)

    it("retains files captured before SIGTERM", function()
      local job, deps = make_job()
      job:start()
      local spawn = deps.runner.last()
      spawn.on_event({ kind = "tool_use", tool = "Edit", input = { file_path = "partial.ts" } })
      job:cancel()
      spawn.on_exit(nil, { cancelled = true, stderr = "", parser_errors = {} })
      local entry = deps.history:get(job:id())
      assert.are.same({ "partial.ts" }, entry.files_changed)
    end)

    it("cancel before start is a no-op", function()
      local job = make_job()
      assert.is_false(job:cancel())
    end)

    it("cancel after completion is a no-op", function()
      local job, deps = make_job()
      job:start()
      deps.runner.last().on_exit(0, { cancelled = false, stderr = "", parser_errors = {} })
      assert.is_false(job:cancel())
    end)
  end)

  describe("failure at add_pending", function()
    it("bubbles the error and does not spawn the runner", function()
      local failing_history = {
        add_pending = function()
          return nil, "disk full"
        end,
        finalize = function() end,
      }
      local runner = new_fake_runner()
      local notify, _ = new_recording_notify()
      local snippet = make_snippet()
      local job = job_mod.new({
        runner = runner,
        history = failing_history,
        events = events_mod.new(),
        notify = notify,
        snippet = snippet,
        prompt = snippet:render({ name = "x" }),
      })
      local ok, err = job:start()
      assert.is_nil(ok)
      assert.matches("disk full", err)
      assert.equals(0, #runner.spawns)
      assert.equals("error", job:status())
    end)
  end)
end)
