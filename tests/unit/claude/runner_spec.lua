-- Exercises the session-terminal coordinator in claude/runner.lua.
-- The term_runner + tailer primitives are injected; no real PTY or
-- filesystem is touched.

local runner = require("snipai.claude.runner")

local function fake_term_runner()
  local rec = { spawns = {} }
  rec.spawn = function(opts)
    local slot = { opts = opts, cancelled = false }
    slot.handle = {}
    function slot.handle:cancel()
      slot.cancelled = true
      return true
    end
    function slot.handle:bufnr()
      return 101
    end
    function slot.handle:job_id()
      return 202
    end
    function slot.handle:is_cancelled()
      return slot.cancelled
    end
    function slot.handle:is_done()
      return slot.done == true
    end
    function slot.fire_exit(code, info)
      slot.done = true
      slot.opts.on_exit(code, info or {})
    end
    rec.spawns[#rec.spawns + 1] = slot
    return slot.handle
  end
  rec.last = function()
    return rec.spawns[#rec.spawns]
  end
  return rec
end

local function fake_tailer()
  local rec = { tailers = {} }
  rec.new = function(opts)
    local t = { opts = opts, started = nil, stopped = false, ticks = 0 }
    function t:start(path)
      self.started = path
    end
    function t:tick()
      self.ticks = self.ticks + 1
    end
    function t:stop()
      self.stopped = true
    end
    function t:emit(evt)
      opts.on_event(evt)
    end
    rec.tailers[#rec.tailers + 1] = t
    return t
  end
  rec.last = function()
    return rec.tailers[#rec.tailers]
  end
  return rec
end

describe("snipai.claude.runner (session-terminal coordinator)", function()
  local function spawn(overrides)
    overrides = overrides or {}
    local tr = overrides.term_runner or fake_term_runner()
    local ta = overrides.tailer or fake_tailer()
    local events = {}
    local exit_seen
    local handle = runner.spawn(
      overrides.prompt or "hello",
      {
        term_runner = tr,
        tailer = ta,
        session_paths = overrides.session_paths or {
          session_file = function(o)
            return "/fake/projects/" .. o.session_id .. ".jsonl"
          end,
        },
        session_id_gen = overrides.session_id_gen or function()
          return "11111111-1111-1111-1111-111111111111"
        end,
        cwd = "/proj",
        snippet_name = overrides.snippet_name or "greet",
        extra_args = overrides.extra_args or { "--permission-mode", "acceptEdits" },
      },
      function(evt)
        events[#events + 1] = evt
      end,
      function(code, info)
        exit_seen = { code = code, info = info }
      end
    )
    return {
      handle = handle,
      term_runner = tr,
      tailer = ta,
      events = events,
      exit = function()
        return exit_seen
      end,
    }
  end

  it("starts a tailer on the resolved session file", function()
    local r = spawn()
    assert.equals(
      "/fake/projects/11111111-1111-1111-1111-111111111111.jsonl",
      r.tailer.last().started
    )
  end)

  it("passes session_id and snippet_name through to term_runner", function()
    local r = spawn()
    local o = r.term_runner.last().opts
    assert.equals("11111111-1111-1111-1111-111111111111", o.session_id)
    assert.equals("greet", o.snippet_name)
    assert.same({ "--permission-mode", "acceptEdits" }, o.extra_args)
  end)

  it("exposes session_id / bufnr / job_id / cancel on the handle", function()
    local r = spawn()
    assert.equals("11111111-1111-1111-1111-111111111111", r.handle:session_id())
    assert.equals(101, r.handle:bufnr())
    assert.equals(202, r.handle:job_id())
    assert.is_true(r.handle:cancel())
    assert.is_true(r.term_runner.last().cancelled)
  end)

  it("forwards tailer events to on_event", function()
    local r = spawn()
    r.tailer.last():emit({ kind = "assistant_text", text = "hi" })
    r.tailer.last():emit({ kind = "tool_use", tool = "Edit", input = { file_path = "a.ts" } })
    assert.equals(2, #r.events)
    assert.equals("assistant_text", r.events[1].kind)
    assert.equals("tool_use", r.events[2].kind)
  end)

  it("stops the tailer on PTY exit and fires on_exit exactly once", function()
    local r = spawn()
    r.term_runner.last().fire_exit(0, { cancelled = false })
    assert.is_true(r.tailer.last().stopped)
    assert.equals(0, r.exit().code)
    assert.is_false(r.exit().info.cancelled)

    -- Simulate a late second exit callback — must be ignored.
    r.term_runner.last().opts.on_exit(99, { cancelled = false })
    assert.equals(0, r.exit().code)
  end)

  it("propagates cancelled=true through on_exit when cancel() was called", function()
    local r = spawn()
    r.handle:cancel()
    r.term_runner.last().fire_exit(nil, { cancelled = true, signal = 15 })
    assert.is_true(r.exit().info.cancelled)
  end)

  it("rejects missing callbacks", function()
    assert.has_error(function()
      runner.spawn("x", {}, nil, function() end)
    end)
    assert.has_error(function()
      runner.spawn("x", {}, function() end, nil)
    end)
    assert.has_error(function()
      runner.spawn("", {}, function() end, function() end)
    end)
  end)
end)
