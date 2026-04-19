local snipai = require("snipai")
local events_mod = require("snipai.events")
local notify_mod = require("snipai.notify")
local history_mod = require("snipai.history")
local json = require("tests.helpers.json")

-- ---------------------------------------------------------------------------
-- Fakes: in-memory fs, recording notifier, fake runner, preseeded reader.
-- ---------------------------------------------------------------------------

local function new_in_memory_fs()
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

local function json_reader(contents)
  -- Map path -> serialized JSON string; return (nil, "No such file") otherwise.
  return function(path)
    if contents[path] == nil then
      return nil, "No such file"
    end
    return contents[path]
  end
end

-- Default fake param form: auto-submits empty values so existing tests
-- exercise the "ctx.params nil but snippet has defaults" path exactly
-- as they did before the form wiring landed (snippet:render fills in
-- declared defaults for missing keys).
local function auto_submit_form()
  return {
    open = function(_, form_opts)
      form_opts.on_submit({})
    end,
  }
end

-- Headless-safe built-ins: concrete non-empty cursor_file so insert-
-- flavored snippets don't trip the unnamed-buffer refusal, but tests
-- that care about the value can override via overrides.gather_builtins.
local function default_test_builtins()
  return {
    cursor_file = "/test/x.lua",
    cursor_line = 1,
    cursor_col = 1,
    cwd = "/test",
  }
end

-- Builds a setup() args table wired entirely with fakes.
local function build_test_setup(overrides)
  overrides = overrides or {}

  local runner = overrides.runner or new_fake_runner()
  local events = events_mod.new()
  local notify, notify_calls = new_recording_notify()
  local param_form = overrides.param_form or auto_submit_form()

  local history = history_mod.new({
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

  local deps = {
    events = events,
    notify = notify,
    history = history,
    runner = runner,
    param_form = param_form,
    gather_builtins = overrides.gather_builtins or default_test_builtins,
    place_insert = overrides.place_insert or function() end,
    save_buffer = overrides.save_buffer or function() end,
    reader = overrides.reader,
    json_decode = overrides.json_decode or json.decode,
  }

  local opts = {
    config_paths = overrides.config_paths or {},
    claude = { cmd = "claude" },
    history = { path = "/history.jsonl", max_entries = 500, per_project = true },
    ui = { notify = "auto" },
    _deps = deps,
  }

  return opts, {
    runner = runner,
    events = events,
    notify = notify,
    notify_calls = notify_calls,
    history = history,
    param_form = param_form,
  }
end

local FIXTURE_CONFIG_PATH = "/snippets.json"
local FIXTURE_CONFIG_JSON = json.encode({
  sample_snippet = {
    prefix = "sa",
    body = "generate a {{thing}}",
    parameter = { thing = { type = "string", default = "widget" } },
  },
  no_params = {
    prefix = "np",
    body = "do the thing",
  },
  ailua_module = {
    prefix = "ailua",
    body = "enrich {{cursor_file}}:{{cursor_line}} — {{purpose}}",
    insert = "-- purpose: {{purpose}}\n",
    parameter = { purpose = { type = "text", default = "stub" } },
  },
})

local function setup_with_fixture(extra)
  extra = extra or {}
  extra.reader = json_reader({ [FIXTURE_CONFIG_PATH] = FIXTURE_CONFIG_JSON })
  extra.config_paths = { FIXTURE_CONFIG_PATH }
  local opts, deps = build_test_setup(extra)
  snipai.setup(opts)
  return deps
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

describe("snipai (top-level)", function()
  before_each(function()
    snipai._reset()
  end)

  describe("setup", function()
    it("marks the module initialized and stores merged opts", function()
      local opts = build_test_setup()
      snipai.setup(opts)
      assert.is_true(snipai._state._initialized)
      assert.equals("claude", snipai._state.opts.claude.cmd)
    end)

    it("loads snippet configs into the registry", function()
      setup_with_fixture()
      assert.truthy(snipai._state.registry:get("sample_snippet"))
      assert.truthy(snipai._state.registry:get("no_params"))
    end)
  end)

  describe("guards", function()
    it("trigger before setup errors", function()
      assert.has_error(function()
        snipai.trigger("x")
      end)
    end)

    it("reload before setup errors", function()
      assert.has_error(function()
        snipai.reload()
      end)
    end)

    it("facade accessors error before setup", function()
      assert.has_error(function()
        snipai.jobs.list()
      end)
      assert.has_error(function()
        snipai.history.list()
      end)
    end)
  end)

  describe("trigger", function()
    it("looks up by name, renders, and spawns the runner", function()
      local deps = setup_with_fixture()
      local job = snipai.trigger("sample_snippet")
      assert.truthy(job)
      assert.equals("generate a widget", deps.runner.spawns[1].prompt)
      assert.equals("running", job:status())
    end)

    it("accepts a pre-resolved snippet object", function()
      local deps = setup_with_fixture()
      local snippet = snipai._state.registry:get("no_params")
      local job = snipai.trigger(snippet)
      assert.truthy(job)
      assert.equals("do the thing", deps.runner.spawns[1].prompt)
    end)

    it("passes ctx.params through to snippet:render", function()
      local deps = setup_with_fixture()
      local job = snipai.trigger("sample_snippet", { params = { thing = "rocket" } })
      assert.truthy(job)
      assert.equals("generate a rocket", deps.runner.spawns[1].prompt)
    end)

    it("errors + notifies on unknown snippet name", function()
      local deps = setup_with_fixture()
      local job, err = snipai.trigger("nope")
      assert.is_nil(job)
      assert.matches("unknown snippet", err)
      -- last notify call surfaces the error at ERROR level
      local last = deps.notify_calls[#deps.notify_calls]
      assert.matches("unknown snippet", last.msg)
      assert.equals(4, last.level)
    end)

    it("rejects empty / non-string / non-table argument", function()
      setup_with_fixture()
      local _, err = snipai.trigger("")
      assert.matches("requires a snippet name", err)
      local _, err2 = snipai.trigger(42)
      assert.matches("requires a snippet name", err2)
    end)
  end)

  describe("trigger with param form", function()
    it("opens the form when ctx.params is nil and snippet declares params", function()
      local captured
      local form = {
        open = function(snippet, form_opts)
          captured = { snippet = snippet, form_opts = form_opts }
          form_opts.on_submit({ thing = "rocket" })
        end,
      }
      local deps = setup_with_fixture({ param_form = form })
      local job = snipai.trigger("sample_snippet")
      assert.truthy(captured)
      assert.equals("sample_snippet", captured.snippet.name)
      assert.equals(deps.notify, captured.form_opts.notify)
      assert.truthy(job)
      assert.equals("generate a rocket", deps.runner.spawns[1].prompt)
    end)

    it("skips the form when ctx.params is an empty table", function()
      local opens = 0
      local form = {
        open = function()
          opens = opens + 1
        end,
      }
      local deps = setup_with_fixture({ param_form = form })
      local job = snipai.trigger("sample_snippet", { params = {} })
      assert.equals(0, opens)
      assert.truthy(job)
      assert.equals("generate a widget", deps.runner.spawns[1].prompt)
    end)

    it("skips the form when the snippet declares no params", function()
      local opens = 0
      local form = {
        open = function()
          opens = opens + 1
        end,
      }
      local deps = setup_with_fixture({ param_form = form })
      local job = snipai.trigger("no_params")
      assert.equals(0, opens)
      assert.truthy(job)
      assert.equals("do the thing", deps.runner.spawns[1].prompt)
    end)

    it("returns nil and spawns no job when the form is cancelled", function()
      local form = {
        open = function(_, form_opts)
          form_opts.on_cancel()
        end,
      }
      local deps = setup_with_fixture({ param_form = form })
      local job, err = snipai.trigger("sample_snippet")
      assert.is_nil(job)
      assert.is_nil(err)
      assert.equals(0, #deps.runner.spawns)
    end)
  end)

  describe("trigger with insert-flavored snippet", function()
    it("places rendered insert, saves the buffer, spawns with builtins in prompt", function()
      local place_calls, save_calls = {}, {}
      local range = {
        start = { row = 2, col = 0 },
        ["end"] = { row = 2, col = 5 },
      }
      local deps = setup_with_fixture({
        gather_builtins = function()
          return {
            cursor_file = "/proj/a.lua",
            cursor_line = 3,
            cursor_col = 2,
            cwd = "/proj",
          }
        end,
        place_insert = function(buffer, r, text)
          place_calls[#place_calls + 1] = { buffer = buffer, range = r, text = text }
        end,
        save_buffer = function(buffer)
          save_calls[#save_calls + 1] = buffer
        end,
      })

      local job = snipai.trigger("ailua_module", {
        params = { purpose = "logging" },
        buffer = 7,
        replace_range = range,
      })

      assert.truthy(job)
      assert.equals(1, #place_calls)
      assert.equals(7, place_calls[1].buffer)
      assert.are.same(range, place_calls[1].range)
      assert.equals("-- purpose: logging\n", place_calls[1].text)
      assert.equals(1, #save_calls)
      assert.equals(7, save_calls[1])
      -- body rendered against user params + builtins
      assert.equals("enrich /proj/a.lua:3 — logging", deps.runner.spawns[1].prompt)
    end)

    it("refuses on unnamed buffer (cursor_file is empty) and skips spawn", function()
      local place_calls, save_calls = {}, {}
      local deps = setup_with_fixture({
        gather_builtins = function()
          return {
            cursor_file = "",
            cursor_line = 1,
            cursor_col = 1,
            cwd = "/nowhere",
          }
        end,
        place_insert = function()
          place_calls[#place_calls + 1] = true
        end,
        save_buffer = function()
          save_calls[#save_calls + 1] = true
        end,
      })

      local job, err = snipai.trigger("ailua_module", { params = { purpose = "x" } })

      assert.is_nil(job)
      assert.truthy(err)
      assert.equals(0, #place_calls)
      assert.equals(0, #save_calls)
      assert.equals(0, #deps.runner.spawns)
      local last = deps.notify_calls[#deps.notify_calls]
      assert.matches("save", last.msg)
      assert.equals(4, last.level) -- error
    end)

    it("does not touch the buffer when the snippet has no insert field", function()
      local place_calls, save_calls = {}, {}
      local deps = setup_with_fixture({
        place_insert = function()
          place_calls[#place_calls + 1] = true
        end,
        save_buffer = function()
          save_calls[#save_calls + 1] = true
        end,
      })

      snipai.trigger("no_params")

      assert.equals(0, #place_calls)
      assert.equals(0, #save_calls)
      assert.equals(1, #deps.runner.spawns)
    end)

    it("falls back to a cursor-at-point range when the caller didn't supply one", function()
      local captured
      setup_with_fixture({
        gather_builtins = function()
          return {
            cursor_file = "/proj/a.lua",
            cursor_line = 5,
            cursor_col = 3,
            cwd = "/proj",
          }
        end,
        place_insert = function(buffer, r, text)
          captured = { buffer = buffer, range = r, text = text }
        end,
      })

      snipai.trigger("ailua_module", { params = { purpose = "x" }, buffer = 9 })

      -- Range collapses to the cursor point (start == end) when no
      -- replace_range was supplied — programmatic triggers just insert
      -- at the cursor rather than replacing a typed prefix.
      assert.equals(9, captured.buffer)
      assert.equals(4, captured.range.start.row) -- cursor_line 5, 0-based
      assert.equals(2, captured.range.start.col) -- cursor_col 3, 0-based
      assert.equals(4, captured.range["end"].row)
      assert.equals(2, captured.range["end"].col)
    end)
  end)

  describe("reload", function()
    it("re-reads the configured paths", function()
      local mutable_content = { [FIXTURE_CONFIG_PATH] = FIXTURE_CONFIG_JSON }
      local opts = build_test_setup({
        reader = function(path)
          if mutable_content[path] == nil then
            return nil, "No such file"
          end
          return mutable_content[path]
        end,
        config_paths = { FIXTURE_CONFIG_PATH },
      })
      snipai.setup(opts)
      assert.truthy(snipai._state.registry:get("sample_snippet"))
      assert.is_nil(snipai._state.registry:get("new_snippet"))

      -- Mutate the "on disk" JSON and reload.
      mutable_content[FIXTURE_CONFIG_PATH] = json.encode({
        new_snippet = { prefix = "ns", body = "hello" },
      })
      snipai.reload()

      assert.is_nil(snipai._state.registry:get("sample_snippet"))
      assert.truthy(snipai._state.registry:get("new_snippet"))
    end)
  end)

  describe("jobs facade", function()
    it("list / get / cancel / cancel_all all delegate to the manager", function()
      local deps = setup_with_fixture()
      local a = snipai.trigger("no_params")
      local b = snipai.trigger("no_params")

      local list = snipai.jobs.list()
      assert.equals(2, #list)
      assert.equals(a, snipai.jobs.get(a:id()))

      assert.is_true(snipai.jobs.cancel(a:id()))
      assert.is_true(deps.runner.spawns[1].cancelled)

      -- b still runs; finalize it and verify cancel_all takes nothing left
      deps.runner.spawns[2].on_exit(0, { cancelled = false, stderr = "", parser_errors = {} })
      deps.runner.spawns[1].on_exit(nil, { cancelled = true, stderr = "", parser_errors = {}, signal = 15 })
      assert.equals(0, snipai.jobs.cancel_all())
      assert.equals(0, #snipai.jobs.list())
    end)
  end)

  describe("history facade", function()
    it("list reflects jobs spawned through trigger", function()
      local deps = setup_with_fixture()
      local job = snipai.trigger("no_params")
      deps.runner.spawns[1].on_exit(0, { cancelled = false, stderr = "", parser_errors = {} })

      local entries = snipai.history.list({ scope = "all" })
      assert.equals(1, #entries)
      assert.equals(job:id(), entries[1].id)
      assert.equals("success", entries[1].status)
    end)

    it("get and clear work through the facade", function()
      local deps = setup_with_fixture()
      local job = snipai.trigger("no_params")
      deps.runner.spawns[1].on_exit(0, { cancelled = false, stderr = "", parser_errors = {} })

      assert.equals("success", snipai.history.get(job:id()).status)
      snipai.history.clear()
      assert.are.same({}, snipai.history.list({ scope = "all" }))
    end)
  end)

  describe("end-to-end: :SnipaiTrigger-style flow", function()
    it("success: pending history row, events emitted, success notification", function()
      local deps = setup_with_fixture()

      local bus_events = {}
      deps.events:subscribe("job_started", function(j)
        bus_events[#bus_events + 1] = { name = "started", id = j:id() }
      end)
      deps.events:subscribe("job_done", function(j, code)
        bus_events[#bus_events + 1] = { name = "done", id = j:id(), code = code }
      end)

      local job = snipai.trigger("sample_snippet")
      assert.equals("running", snipai.history.get(job:id()).status)

      deps.runner.spawns[1].on_event({ kind = "tool_use", tool = "Edit", input = { file_path = "x.ts" } })
      deps.runner.spawns[1].on_exit(0, { cancelled = false, stderr = "", parser_errors = {} })

      local entry = snipai.history.get(job:id())
      assert.equals("success", entry.status)
      assert.are.same({ "x.ts" }, entry.files_changed)

      assert.equals(2, #bus_events)
      assert.equals("started", bus_events[1].name)
      assert.equals("done", bus_events[2].name)

      -- running... notification + success finish
      assert.is_true(#deps.notify_calls >= 2)
      assert.matches("running", deps.notify_calls[1].msg)
      assert.matches("1 file", deps.notify_calls[#deps.notify_calls].msg)
    end)

    it("cancel: history marked cancelled, files captured before SIGTERM preserved", function()
      local deps = setup_with_fixture()
      local job = snipai.trigger("sample_snippet")

      deps.runner.spawns[1].on_event({ kind = "tool_use", tool = "Write", input = { file_path = "p.ts" } })
      snipai.jobs.cancel(job:id())
      deps.runner.spawns[1].on_exit(nil, { cancelled = true, stderr = "", parser_errors = {}, signal = 15 })

      local entry = snipai.history.get(job:id())
      assert.equals("cancelled", entry.status)
      assert.are.same({ "p.ts" }, entry.files_changed)
      assert.equals(15, entry.signal)
    end)
  end)
end)
