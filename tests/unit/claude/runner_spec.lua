local runner = require("snipai.claude.runner")

-- ---------------------------------------------------------------------------
-- Fake vim.system: records argv, exposes a driver that pumps stdout/stderr
-- chunks and fires the exit callback. Pass-through scheduler keeps the
-- spec synchronous.
-- ---------------------------------------------------------------------------

local function fake_system()
  local rec = {
    argv = nil,
    sys_opts = nil,
    stdout_cb = nil,
    stderr_cb = nil,
    on_exit = nil,
    killed = nil,
    kill_calls = 0,
  }
  local sysobj = {
    kill = function(self, sig)
      rec.kill_calls = rec.kill_calls + 1
      rec.killed = sig
      return true
    end,
    pid = 4242,
  }
  rec.sysobj = sysobj
  rec.fn = function(argv, sys_opts, on_exit)
    rec.argv = argv
    rec.sys_opts = sys_opts
    rec.stdout_cb = sys_opts.stdout
    rec.stderr_cb = sys_opts.stderr
    rec.on_exit = on_exit
    return sysobj
  end
  rec.driver = {
    stdout = function(data)
      rec.stdout_cb(nil, data)
    end,
    stderr = function(data)
      rec.stderr_cb(nil, data)
    end,
    stdout_err = function(err)
      rec.stdout_cb(err, nil)
    end,
    finish = function(code, signal)
      rec.on_exit({ code = code, signal = signal, stdout = "", stderr = "" })
    end,
  }
  return rec
end

local function sync(fn)
  fn()
end

-- Read fixture once so later tests can share.
local function read_fixture(relpath)
  local root = debug.getinfo(1, "S").source:sub(2):match("(.*)tests/unit/claude/")
  local f = assert(io.open(root .. relpath, "r"))
  local content = f:read("*a")
  f:close()
  return content
end

describe("snipai.claude.runner", function()
  describe("argv construction", function()
    it("uses 'claude' as the default cmd and threads stream-json args", function()
      local f = fake_system()
      runner.spawn("do the thing", {
        system = f.fn,
        scheduler = sync,
      }, function() end, function() end)
      assert.are.same({
        "claude",
        "-p",
        "do the thing",
        "--output-format",
        "stream-json",
        "--verbose",
      }, f.argv)
    end)

    it("honors opts.cmd", function()
      local f = fake_system()
      runner.spawn("p", {
        cmd = "/usr/local/bin/claude",
        system = f.fn,
        scheduler = sync,
      }, function() end, function() end)
      assert.equals("/usr/local/bin/claude", f.argv[1])
    end)

    it("appends extra_args after the stream-json flags", function()
      local f = fake_system()
      runner.spawn("p", {
        system = f.fn,
        scheduler = sync,
        extra_args = { "--model", "sonnet", "--max-tokens", "1000" },
      }, function() end, function() end)
      assert.are.same({
        "claude",
        "-p",
        "p",
        "--output-format",
        "stream-json",
        "--verbose",
        "--model",
        "sonnet",
        "--max-tokens",
        "1000",
      }, f.argv)
    end)

    it("passes timeout_ms through to vim.system opts", function()
      local f = fake_system()
      runner.spawn("p", {
        system = f.fn,
        scheduler = sync,
        timeout_ms = 120000,
      }, function() end, function() end)
      assert.equals(120000, f.sys_opts.timeout)
      assert.is_true(f.sys_opts.text)
    end)
  end)

  describe("input validation", function()
    it("rejects a non-string / empty prompt", function()
      assert.has_error(function()
        runner.spawn(nil, { system = fake_system().fn }, function() end, function() end)
      end)
      assert.has_error(function()
        runner.spawn("", { system = fake_system().fn }, function() end, function() end)
      end)
    end)

    it("requires on_event and on_exit to be functions", function()
      local f = fake_system()
      assert.has_error(function()
        runner.spawn("p", { system = f.fn }, nil, function() end)
      end)
      assert.has_error(function()
        runner.spawn("p", { system = f.fn }, function() end, nil)
      end)
    end)

    it("requires vim.system or opts.system", function()
      assert.has_error(function()
        runner.spawn("p", { system = "not a fn" }, function() end, function() end)
      end)
    end)
  end)

  describe("streaming events", function()
    it("parses complete NDJSON lines from stdout chunks", function()
      local f = fake_system()
      local events = {}
      runner.spawn("p", { system = f.fn, scheduler = sync }, function(evt)
        events[#events + 1] = evt
      end, function() end)

      f.driver.stdout('{"type":"system","subtype":"init","session_id":"s","model":"m","tools":[]}\n')
      f.driver.stdout('{"type":"result","subtype":"success","duration_ms":10}\n')

      assert.equals(2, #events)
      assert.equals("system", events[1].kind)
      assert.equals("init", events[1].subtype)
      assert.equals("result", events[2].kind)
      assert.equals("success", events[2].status)
    end)

    it("buffers partial lines across chunks", function()
      local f = fake_system()
      local events = {}
      runner.spawn("p", { system = f.fn, scheduler = sync }, function(evt)
        events[#events + 1] = evt
      end, function() end)

      f.driver.stdout('{"type":"result","subty')
      assert.equals(0, #events)
      f.driver.stdout('pe":"success","duration_ms":5}\n')
      assert.equals(1, #events)
      assert.equals("result", events[1].kind)
    end)

    it("flushes the trailing partial line on exit", function()
      local f = fake_system()
      local events, exit_code = {}, nil
      runner.spawn("p", { system = f.fn, scheduler = sync }, function(evt)
        events[#events + 1] = evt
      end, function(code)
        exit_code = code
      end)

      f.driver.stdout('{"type":"result","subtype":"success"}') -- no trailing newline
      f.driver.finish(0)

      assert.equals(1, #events)
      assert.equals("result", events[1].kind)
      assert.equals(0, exit_code)
    end)
  end)

  describe("stderr + exit info", function()
    it("accumulates stderr chunks and surfaces them in on_exit info", function()
      local f = fake_system()
      local info
      runner.spawn("p", { system = f.fn, scheduler = sync }, function() end, function(_, i)
        info = i
      end)

      f.driver.stderr("oops ")
      f.driver.stderr("something broke\n")
      f.driver.finish(2)

      assert.equals("oops something broke\n", info.stderr)
      assert.is_false(info.cancelled)
    end)

    it("reports signal on exit info", function()
      local f = fake_system()
      local code, info
      runner.spawn("p", { system = f.fn, scheduler = sync }, function() end, function(c, i)
        code, info = c, i
      end)
      f.driver.finish(nil, 15)
      assert.equals(0, code) -- default 0 when code is nil
      assert.equals(15, info.signal)
    end)
  end)

  describe("cancel", function()
    it("sends SIGTERM via sysobj:kill(15) and flips is_cancelled", function()
      local f = fake_system()
      local h = runner.spawn("p", { system = f.fn, scheduler = sync }, function() end, function() end)

      assert.is_false(h:is_cancelled())
      assert.is_true(h:cancel())
      assert.equals(15, f.killed)
      assert.is_true(h:is_cancelled())
    end)

    it("is a no-op after cancel or completion", function()
      local f = fake_system()
      local h = runner.spawn("p", { system = f.fn, scheduler = sync }, function() end, function() end)
      h:cancel()
      assert.equals(1, f.kill_calls)
      assert.is_false(h:cancel())
      assert.equals(1, f.kill_calls)
    end)

    it("marks cancelled=true in on_exit info", function()
      local f = fake_system()
      local info
      local h = runner.spawn("p", { system = f.fn, scheduler = sync }, function() end, function(_, i)
        info = i
      end)
      h:cancel()
      f.driver.finish(nil, 15)
      assert.is_true(info.cancelled)
    end)

    it("drops further events once cancelled", function()
      local f = fake_system()
      local events = {}
      local h = runner.spawn("p", { system = f.fn, scheduler = sync }, function(evt)
        events[#events + 1] = evt
      end, function() end)

      f.driver.stdout('{"type":"result","subtype":"success"}\n')
      assert.equals(1, #events)

      h:cancel()
      f.driver.stdout('{"type":"result","subtype":"success"}\n') -- arrives post-cancel
      assert.equals(1, #events) -- not 2
    end)
  end)

  describe("spawn failure", function()
    it("synthesizes on_exit(-1, {error=...}) when vim.system raises", function()
      local code, info
      local fail = function()
        error("boom")
      end
      runner.spawn("p", { system = fail, scheduler = sync }, function() end, function(c, i)
        code, info = c, i
      end)
      assert.equals(-1, code)
      assert.matches("boom", info.error)
      assert.is_false(info.cancelled)
    end)
  end)

  describe("fixture round-trip", function()
    it("yields tool_use and result events from success_multi.jsonl", function()
      local fixture = read_fixture("tests/fixtures/claude/success_multi.jsonl")
      local f = fake_system()
      local events = {}
      runner.spawn("p", { system = f.fn, scheduler = sync }, function(evt)
        events[#events + 1] = evt
      end, function() end)

      f.driver.stdout(fixture)
      f.driver.finish(0)

      local has_tool_use, has_result, has_system = false, false, false
      for _, e in ipairs(events) do
        if e.kind == "tool_use" then
          has_tool_use = true
        end
        if e.kind == "result" then
          has_result = true
        end
        if e.kind == "system" then
          has_system = true
        end
      end
      assert.is_true(has_system)
      assert.is_true(has_tool_use)
      assert.is_true(has_result)
    end)
  end)
end)
