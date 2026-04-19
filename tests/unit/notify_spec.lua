local notify = require("snipai.notify")

-- Minimal level table so tests don't depend on vim.log.levels being loaded.
local LEVELS = { TRACE = 0, DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4, OFF = 5 }

-- Build a fake `require` that succeeds only for the listed module names.
local function fake_require(modules)
  return function(name)
    local mod = modules[name]
    if mod == nil then
      error(("module '%s' not found"):format(name), 2)
    end
    return mod
  end
end

-- Recording sink to plug into every backend shape the probes accept.
local function recorder()
  local r = { calls = {} }
  function r.callable(msg, level, opts)
    table.insert(r.calls, { msg = msg, level = level, opts = opts })
  end
  return r
end

describe("snipai.notify", function()
  describe("resolve_level", function()
    it("maps string levels via the levels table", function()
      assert.equals(LEVELS.INFO, notify._resolve_level("info", LEVELS))
      assert.equals(LEVELS.WARN, notify._resolve_level("warn", LEVELS))
      assert.equals(LEVELS.ERROR, notify._resolve_level("error", LEVELS))
      assert.equals(LEVELS.DEBUG, notify._resolve_level("debug", LEVELS))
    end)

    it("passes through numeric levels", function()
      assert.equals(42, notify._resolve_level(42, LEVELS))
    end)

    it("falls back to INFO for unknown / nil levels", function()
      assert.equals(LEVELS.INFO, notify._resolve_level(nil, LEVELS))
      assert.equals(LEVELS.INFO, notify._resolve_level("nope", LEVELS))
    end)

    it("accepts upper-case string levels", function()
      assert.equals(LEVELS.ERROR, notify._resolve_level("ERROR", LEVELS))
    end)
  end)

  describe("backend = 'auto'", function()
    it("prefers nvim-notify when installed", function()
      local rec = recorder()
      local n = notify.new({
        backend = "auto",
        require = fake_require({ notify = rec.callable }),
        levels = LEVELS,
      })
      assert.equals("nvim-notify", n:name())
      n:notify("hi", "info")
      assert.equals(1, #rec.calls)
      assert.equals("hi", rec.calls[1].msg)
      assert.equals(LEVELS.INFO, rec.calls[1].level)
    end)

    it("accepts nvim-notify exporting {notify = fn}", function()
      local rec = recorder()
      local n = notify.new({
        backend = "auto",
        require = fake_require({ notify = { notify = rec.callable } }),
        levels = LEVELS,
      })
      assert.equals("nvim-notify", n:name())
      n:notify("x", "warn")
      assert.equals(LEVELS.WARN, rec.calls[1].level)
    end)

    it("falls through to fidget when nvim-notify is absent", function()
      local rec = recorder()
      local n = notify.new({
        backend = "auto",
        require = fake_require({ fidget = { notify = rec.callable } }),
        levels = LEVELS,
      })
      assert.equals("fidget", n:name())
      n:notify("hey", "error")
      assert.equals(LEVELS.ERROR, rec.calls[1].level)
    end)

    it("falls through to vim.notify when neither is installed", function()
      local rec = recorder()
      local n = notify.new({
        backend = "auto",
        require = fake_require({}),
        vim_notify = rec.callable,
        levels = LEVELS,
      })
      assert.equals("vim.notify", n:name())
      n:notify("last resort")
      assert.equals("last resort", rec.calls[1].msg)
      assert.equals(LEVELS.INFO, rec.calls[1].level)
    end)

    it("skips nvim-notify if it does not export a callable", function()
      local rec = recorder()
      local n = notify.new({
        backend = "auto",
        require = fake_require({ notify = { version = "x" }, fidget = { notify = rec.callable } }),
        levels = LEVELS,
      })
      assert.equals("fidget", n:name())
    end)
  end)

  describe("explicit backend selection", function()
    it("nvim-notify: uses it when installed", function()
      local rec = recorder()
      local n = notify.new({
        backend = "nvim-notify",
        require = fake_require({ notify = rec.callable }),
        levels = LEVELS,
      })
      assert.equals("nvim-notify", n:name())
    end)

    it("nvim-notify: errors when missing", function()
      assert.has_error(function()
        notify.new({
          backend = "nvim-notify",
          require = fake_require({}),
          levels = LEVELS,
        })
      end)
    end)

    it("fidget: errors when missing", function()
      assert.has_error(function()
        notify.new({
          backend = "fidget",
          require = fake_require({}),
          levels = LEVELS,
        })
      end)
    end)

    it("vim.notify: always resolves to the injected emitter", function()
      local rec = recorder()
      local n = notify.new({
        backend = "vim.notify",
        require = fake_require({ notify = rec.callable }), -- should be ignored
        vim_notify = rec.callable,
        levels = LEVELS,
      })
      assert.equals("vim.notify", n:name())
      n:notify("direct", "info")
      assert.equals(1, #rec.calls)
      assert.equals("direct", rec.calls[1].msg)
    end)

    it("rejects unknown backend names", function()
      assert.has_error(function()
        notify.new({ backend = "bogus", levels = LEVELS })
      end)
    end)
  end)

  describe("custom backend", function()
    it("accepts a plain function emitter", function()
      local rec = recorder()
      local n = notify.new({ backend = rec.callable, levels = LEVELS })
      assert.equals("custom", n:name())
      n:notify("yo", "warn", { id = 1 })
      assert.equals("yo", rec.calls[1].msg)
      assert.equals(LEVELS.WARN, rec.calls[1].level)
      assert.are.same({ id = 1 }, rec.calls[1].opts)
    end)

    it("accepts a {name, emit} table", function()
      local rec = recorder()
      local n = notify.new({
        backend = { name = "inmem", emit = rec.callable },
        levels = LEVELS,
      })
      assert.equals("inmem", n:name())
      n:notify("tap")
      assert.equals("tap", rec.calls[1].msg)
    end)

    it("rejects a table without an emit function", function()
      assert.has_error(function()
        notify.new({ backend = { name = "bad" }, levels = LEVELS })
      end)
    end)
  end)

  describe("progress handle", function()
    it("update and finish emit prefixed messages", function()
      local rec = recorder()
      local n = notify.new({ backend = rec.callable, levels = LEVELS })
      local p = n:progress("sample_snippet")
      p:update("running", "info")
      p:finish("done (1 file, 2.0s)")
      assert.equals(2, #rec.calls)
      assert.equals("sample_snippet: running", rec.calls[1].msg)
      assert.equals(LEVELS.INFO, rec.calls[1].level)
      assert.equals("sample_snippet: done (1 file, 2.0s)", rec.calls[2].msg)
      assert.equals(LEVELS.INFO, rec.calls[2].level)
    end)

    it("initial message fires immediately when provided", function()
      local rec = recorder()
      local n = notify.new({ backend = rec.callable, levels = LEVELS })
      n:progress("title", "starting")
      assert.equals(1, #rec.calls)
      assert.equals("title: starting", rec.calls[1].msg)
    end)

    it("finish respects an explicit level (e.g. error)", function()
      local rec = recorder()
      local n = notify.new({ backend = rec.callable, levels = LEVELS })
      local p = n:progress("t")
      p:finish("failed", "error")
      assert.equals(LEVELS.ERROR, rec.calls[1].level)
    end)

    it("omitted title emits plain messages", function()
      local rec = recorder()
      local n = notify.new({ backend = rec.callable, levels = LEVELS })
      local p = n:progress(nil)
      p:update("bare", "info")
      assert.equals("bare", rec.calls[1].msg)
    end)
  end)
end)
