local picker = require("snipai.pickers.running")

-- Helpers ----------------------------------------------------------------

local function make_job(overrides)
  local o = overrides or {}
  local job = {}
  job.id = function()
    return o.id or "abcdef1234567890"
  end
  job.snippet_name = function()
    return o.snippet_name
  end
  job.status = function()
    return o.status or "running"
  end
  job.started_at = function()
    return o.started_at
  end
  job.cursor_file = function()
    return o.cursor_file
  end
  return job
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

local function make_jobs(list)
  return {
    list = function()
      return list or {}
    end,
    cancel = function() end,
    get = function() end,
  }
end

local function make_history()
  return { get = function() end }
end

-- Tests ------------------------------------------------------------------

describe("snipai.pickers.running", function()
  describe("format_row", function()
    it("renders glyph, name, duration, short id, and file basename", function()
      local job = make_job({
        id = "abcdef1234",
        snippet_name = "scaffold",
        status = "running",
        started_at = 1000,
        cursor_file = "/work/proj/src/init.lua",
      })
      local row = picker.format_row(job, 3100)
      assert.matches("^…", row) -- running glyph leads the row
      assert.matches("scaffold", row)
      assert.matches("2%.1s", row)
      assert.matches("abcdef12", row)
      assert.matches("%(init%.lua%)", row)
    end)

    it("exposes one glyph per state via _glyph", function()
      assert.equals("…", picker._glyph("running"))
      assert.equals("◦", picker._glyph("idle"))
      assert.equals("✓", picker._glyph("complete"))
      assert.equals("✓", picker._glyph("success")) -- legacy alias
      assert.equals("✗", picker._glyph("cancelled"))
      assert.equals("!", picker._glyph("error"))
      assert.equals("?", picker._glyph("weird"))
    end)

    it("omits duration when started_at or now is missing", function()
      local job = make_job({ snippet_name = "s", status = "running", started_at = nil })
      local row = picker.format_row(job, 100)
      -- duration segment is skipped; id still present
      assert.is_nil(row:match("%d%.%ds"))
      assert.is_nil(row:match("%dms"))
    end)

    it("omits the cursor-file segment when unset or empty", function()
      local job = make_job({ snippet_name = "s", cursor_file = nil })
      assert.is_nil(picker.format_row(job, 1):match("%(.-%)"))

      local job2 = make_job({ snippet_name = "s", cursor_file = "" })
      assert.is_nil(picker.format_row(job2, 1):match("%(.-%)"))
    end)

    it("falls back to '(unknown)' when the snippet name is missing", function()
      local job = make_job({ snippet_name = nil })
      assert.matches("%(unknown%)", picker.format_row(job, 1))
    end)

    it("leads with the correct glyph per status", function()
      local j = make_job({ snippet_name = "s", status = "cancelled" })
      assert.matches("^✗", picker.format_row(j, 1))
    end)
  end)

  describe("format_duration helper", function()
    it("matches the known shape", function()
      assert.equals("-", picker._format_duration(nil))
      assert.equals("500ms", picker._format_duration(500))
      assert.equals("2.3s", picker._format_duration(2300))
      assert.equals("1m05s", picker._format_duration(65000))
    end)
  end)

  describe("short_id / basename helpers", function()
    it("short_id clips to n chars (default 8)", function()
      assert.equals("abcdef12", picker._short_id("abcdef1234567890"))
      assert.equals("abc", picker._short_id("abcdef", 3))
      assert.equals("", picker._short_id(nil))
    end)

    it("basename returns the last path segment", function()
      assert.equals("init.lua", picker._basename("/a/b/init.lua"))
      assert.equals("init.lua", picker._basename("init.lua"))
      assert.equals("", picker._basename(""))
      assert.equals("", picker._basename(nil))
    end)
  end)

  describe("open soft-fails", function()
    it("notifies and returns when no jobs are active", function()
      local n, calls = make_notify()
      picker.open({
        jobs = make_jobs({}),
        history = make_history(),
        notify = n,
        telescope = { pickers = error, finders = {}, conf = {}, actions = {}, action_state = {} }, -- should never be reached
      })
      assert.equals(1, #calls)
      assert.matches("no active jobs", calls[1].msg)
    end)

    it("notifies and returns when Telescope is unavailable (telescope = false sentinel)", function()
      local n, calls = make_notify()
      picker.open({
        jobs = make_jobs({ make_job({ snippet_name = "s" }) }),
        history = make_history(),
        notify = n,
        telescope = false,
      })
      assert.equals(1, #calls)
      assert.matches("Telescope not installed", calls[1].msg)
      assert.equals("warn", calls[1].level)
    end)

    it("requires opts.jobs and opts.history", function()
      assert.has_error(function()
        picker.open({})
      end)
      assert.has_error(function()
        picker.open({ jobs = make_jobs({}) })
      end)
    end)
  end)
end)
