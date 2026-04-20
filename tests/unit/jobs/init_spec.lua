local jobs_mod = require("snipai.jobs")
local history_mod = require("snipai.history")
local events_mod = require("snipai.events")
local notify_mod = require("snipai.notify")
local snippet_mod = require("snipai.snippet")
local json = require("tests.helpers.json")

-- ---------------------------------------------------------------------------
-- Fakes / helpers (mirrors job_spec so each file reads standalone)
-- ---------------------------------------------------------------------------

local function new_fs()
  local files = {}
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
    fs = new_fs(),
    json_encode = json.encode,
    json_decode = json.decode,
    cwd = "/proj",
    now = (function()
      local t = 0
      return function()
        t = t + 1
        return t
      end
    end)(),
  })
end

local function new_fake_runner()
  local rec = { spawns = {} }
  rec.spawn = function(prompt, opts, on_event, on_exit)
    local slot = {
      prompt = prompt,
      opts = opts,
      on_event = on_event,
      on_exit = on_exit,
      cancelled = false,
    }
    slot.handle = {
      cancel = function()
        slot.cancelled = true
        return true
      end,
    }
    rec.spawns[#rec.spawns + 1] = slot
    return slot.handle
  end
  return rec
end

local function new_notify()
  local calls = {}
  local notify = notify_mod.new({
    backend = function(msg, level, opts)
      calls[#calls + 1] = { msg = msg, level = level, opts = opts }
    end,
    levels = { TRACE = 0, DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4, OFF = 5 },
  })
  return notify, calls
end

local function counter_id(prefix)
  local n = 0
  return function()
    n = n + 1
    return (prefix or "job") .. "-" .. tostring(n)
  end
end

local function fake_clock()
  local t = 1000
  return function()
    t = t + 100
    return t
  end
end

local function make_snippet(name, body, params)
  local s = snippet_mod.new(name or "sample_snippet", {
    prefix = "sa",
    body = body or "do {{thing}}",
    parameter = params or { thing = { type = "string" } },
  })
  assert(s:validate())
  return s
end

local function new_manager(overrides)
  overrides = overrides or {}
  local runner = overrides.runner or new_fake_runner()
  local history = overrides.history or new_history()
  local events = overrides.events or events_mod.new()
  local notify, notify_calls = new_notify()
  local mgr = jobs_mod.new({
    runner = runner,
    history = history,
    events = events,
    notify = notify,
    claude_opts = overrides.claude_opts or { cmd = "claude" },
    now = overrides.now or fake_clock(),
    id = overrides.id or counter_id("j"),
  })
  return mgr,
    {
      runner = runner,
      history = history,
      events = events,
      notify_calls = notify_calls,
    }
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

describe("snipai.jobs (manager)", function()
  describe("construction", function()
    it("rejects missing deps", function()
      assert.has_error(function()
        jobs_mod.new({})
      end)
    end)
  end)

  describe("spawn", function()
    it("renders the snippet prompt and calls runner.spawn", function()
      local mgr, deps = new_manager()
      local snippet = make_snippet()
      local job = mgr:spawn(snippet, { thing = "widget" })
      assert.truthy(job)
      assert.equals(1, #deps.runner.spawns)
      assert.equals("do widget", deps.runner.spawns[1].prompt)
    end)

    it("surfaces render errors (missing required param)", function()
      local mgr = new_manager()
      local snippet = make_snippet() -- 'thing' has no default, no optional
      local job, err = mgr:spawn(snippet, {})
      assert.is_nil(job)
      assert.truthy(err)
    end)

    it("tracks the job in the active set until job_done fires", function()
      local mgr, deps = new_manager()
      local snippet = make_snippet()
      local job = mgr:spawn(snippet, { thing = "x" })
      assert.equals(1, mgr:count())
      assert.equals(job, mgr:get(job:id()))

      deps.runner.spawns[1].on_exit(0, { cancelled = false, stderr = "", parser_errors = {} })
      assert.equals(0, mgr:count())
      assert.is_nil(mgr:get(job:id()))
    end)

    it("removes the right job when multiple run concurrently", function()
      local mgr, deps = new_manager()
      local s = make_snippet()
      local a = mgr:spawn(s, { thing = "a" })
      local b = mgr:spawn(s, { thing = "b" })
      assert.equals(2, mgr:count())

      -- finish b first
      deps.runner.spawns[2].on_exit(0, { cancelled = false, stderr = "", parser_errors = {} })
      assert.equals(1, mgr:count())
      assert.truthy(mgr:get(a:id()))
      assert.is_nil(mgr:get(b:id()))

      deps.runner.spawns[1].on_exit(0, { cancelled = false, stderr = "", parser_errors = {} })
      assert.equals(0, mgr:count())
    end)

    it("threads claude_opts into runner.spawn", function()
      local mgr, deps = new_manager({ claude_opts = { cmd = "/bin/claude", timeout_ms = 1000 } })
      mgr:spawn(make_snippet(), { thing = "x" })
      local spawn = deps.runner.spawns[1]
      assert.equals("/bin/claude", spawn.opts.cmd)
      assert.equals(1000, spawn.opts.timeout_ms)
    end)
  end)

  describe("list / get", function()
    it("list returns every active job (unspecified order)", function()
      local mgr = new_manager()
      local s = make_snippet()
      mgr:spawn(s, { thing = "a" })
      mgr:spawn(s, { thing = "b" })
      mgr:spawn(s, { thing = "c" })
      local active = mgr:list()
      assert.equals(3, #active)
    end)

    it("get returns nil for unknown ids", function()
      local mgr = new_manager()
      assert.is_nil(mgr:get("missing"))
    end)
  end)

  describe("cancel / cancel_all", function()
    it("cancel delegates to the job and its runner handle", function()
      local mgr, deps = new_manager()
      local job = mgr:spawn(make_snippet(), { thing = "x" })
      assert.is_true(mgr:cancel(job:id()))
      assert.is_true(deps.runner.spawns[1].cancelled)
    end)

    it("cancel returns false+err for unknown id", function()
      local mgr = new_manager()
      local ok, err = mgr:cancel("nope")
      assert.is_false(ok)
      assert.matches("no active job", err)
    end)

    it("cancel_all SIGTERMs every active runner", function()
      local mgr, deps = new_manager()
      local s = make_snippet()
      mgr:spawn(s, { thing = "a" })
      mgr:spawn(s, { thing = "b" })
      assert.equals(2, mgr:cancel_all())
      assert.is_true(deps.runner.spawns[1].cancelled)
      assert.is_true(deps.runner.spawns[2].cancelled)
    end)
  end)

  describe("history wiring", function()
    it("writes a pending row on spawn and finalizes on exit", function()
      local mgr, deps = new_manager()
      local job = mgr:spawn(make_snippet(), { thing = "x" })
      local entry = deps.history:get(job:id())
      assert.equals("running", entry.status)
      assert.equals("sample_snippet", entry.snippet)

      deps.runner.spawns[1].on_event({
        kind = "tool_use",
        tool = "Edit",
        input = { file_path = "a.ts" },
      })
      deps.runner.spawns[1].on_exit(0, { cancelled = false, stderr = "", parser_errors = {} })

      local final = deps.history:get(job:id())
      assert.equals("complete", final.status)
      assert.are.same({ "a.ts" }, final.files_changed)
    end)
  end)
end)
