local picker = require("snipai.pickers.history")

-- Helpers ----------------------------------------------------------------

local function make_entry(overrides)
  local o = overrides or {}
  return {
    id = o.id or "abcdef1234",
    snippet = o.snippet,
    prefix = o.prefix,
    status = o.status or "success",
    started_at = o.started_at,
    finished_at = o.finished_at,
    duration_ms = o.duration_ms,
    files_changed = o.files_changed,
    cwd = o.cwd,
    params = o.params,
    prompt = o.prompt,
    stderr = o.stderr,
  }
end

local function make_notify()
  local calls = {}
  return {
    notify = function(self, msg, level)
      calls[#calls + 1] = { msg = msg, level = level }
    end,
  },
    calls
end

local function make_history(list_result, err)
  local qcalls = {}
  return {
    list = function(self, opts)
      return list_result, err
    end,
    to_quickfix = function(self, id)
      qcalls[#qcalls + 1] = id
      return { { filename = "x" } }
    end,
  },
    qcalls
end

-- Tests ------------------------------------------------------------------

describe("snipai.pickers.history", function()
  describe("format_row", function()
    it("renders glyph, time, name, duration, file-count, short id", function()
      local row = picker.format_row(make_entry({
        id = "abcdef1234",
        snippet = "scaffold",
        status = "success",
        started_at = 1700000000000,
        duration_ms = 2300,
        files_changed = { "a", "b" },
      }))
      assert.matches("^%+", row) -- success glyph
      assert.matches("scaffold", row)
      assert.matches("2%.3s", row)
      assert.matches("2 files", row)
      assert.matches("abcdef12", row)
    end)

    it("singular '1 file' vs plural 'N files'", function()
      local single = picker.format_row(make_entry({ snippet = "s", files_changed = { "a" } }))
      assert.matches("1 file", single)
      assert.is_nil(single:match("1 files"))

      local zero = picker.format_row(make_entry({ snippet = "s", files_changed = {} }))
      assert.matches("0 files", zero)
    end)

    it("glyph varies by status", function()
      assert.matches("^%+", picker.format_row(make_entry({ snippet = "s", status = "success" })))
      assert.matches("^x", picker.format_row(make_entry({ snippet = "s", status = "error" })))
      assert.matches("^~", picker.format_row(make_entry({ snippet = "s", status = "cancelled" })))
      assert.matches("^…", picker.format_row(make_entry({ snippet = "s", status = "running" })))
    end)

    it("falls back to '(unnamed)' when snippet field is nil", function()
      assert.matches("%(unnamed%)", picker.format_row(make_entry({ snippet = nil })))
    end)

    it("omits the timestamp segment when started_at is missing", function()
      local row = picker.format_row(make_entry({ snippet = "s", started_at = nil }))
      assert.is_nil(row:match("%d%d:%d%d:%d%d"))
    end)
  end)

  describe("helpers", function()
    it("format_duration matches the canonical shape", function()
      assert.equals("-", picker._format_duration(nil))
      assert.equals("500ms", picker._format_duration(500))
      assert.equals("2.3s", picker._format_duration(2300))
      assert.equals("1m05s", picker._format_duration(65000))
    end)

    it("format_timestamp returns HH:MM:SS shape or empty", function()
      assert.equals("", picker._format_timestamp(nil))
      local stamp = picker._format_timestamp(1700000000000)
      assert.matches("^%d%d:%d%d:%d%d$", stamp)
    end)

    it("short_id clips", function()
      assert.equals("abcdef12", picker._short_id("abcdef1234567890"))
      assert.equals("", picker._short_id(nil))
    end)

    it("sort_newest_first orders by started_at descending", function()
      local e1 = { started_at = 100 }
      local e2 = { started_at = 300 }
      local e3 = { started_at = 200 }
      local sorted = picker._sort_newest_first({ e1, e2, e3 })
      assert.equals(300, sorted[1].started_at)
      assert.equals(200, sorted[2].started_at)
      assert.equals(100, sorted[3].started_at)
    end)

    it("sort_newest_first sends missing timestamps to the end", function()
      local e1 = { started_at = 100 }
      local e2 = {} -- no started_at
      local e3 = { started_at = 200 }
      local sorted = picker._sort_newest_first({ e2, e1, e3 })
      assert.equals(200, sorted[1].started_at)
      assert.equals(100, sorted[2].started_at)
      assert.is_nil(sorted[3].started_at)
    end)
  end)

  describe("open soft-fails", function()
    it("requires opts.history", function()
      assert.has_error(function()
        picker.open({})
      end)
    end)

    it("rejects unknown scope", function()
      local n, calls = make_notify()
      picker.open({ history = make_history({}), notify = n, scope = "weird" })
      assert.equals(1, #calls)
      assert.matches("unknown scope", calls[1].msg)
      assert.equals("warn", calls[1].level)
    end)

    it("notifies when the list is empty", function()
      local n, calls = make_notify()
      picker.open({ history = make_history({}), notify = n })
      assert.equals(1, #calls)
      assert.matches("no history entries %(project scope%)", calls[1].msg)
    end)

    it("surfaces list() errors", function()
      local n, calls = make_notify()
      picker.open({ history = make_history(nil, "bad json"), notify = n })
      assert.equals(1, #calls)
      assert.matches("history list failed", calls[1].msg)
      assert.equals("error", calls[1].level)
    end)

    it("notifies when Telescope is forced absent", function()
      local n, calls = make_notify()
      picker.open({
        history = make_history({ make_entry({ snippet = "s", started_at = 1 }) }),
        notify = n,
        telescope = false,
      })
      assert.equals(1, #calls)
      assert.matches("Telescope not installed", calls[1].msg)
      assert.equals("warn", calls[1].level)
    end)
  end)
end)
