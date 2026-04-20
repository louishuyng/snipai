local detail = require("snipai.ui.detail")

-- Helpers ----------------------------------------------------------------

local function find_line(lines, needle)
  for i, l in ipairs(lines) do
    if l:find(needle, 1, true) then
      return i, l
    end
  end
  return nil, nil
end

local function lines_joined(lines)
  return table.concat(lines, "\n")
end

-- Tests ------------------------------------------------------------------

describe("snipai.ui.detail", function()
  describe("render", function()
    local function success_entry()
      return {
        id = "abc-001",
        snippet = "scaffold",
        prefix = "sf",
        status = "success",
        exit_code = 0,
        duration_ms = 2300,
        cwd = "/work/snipai",
        started_at = 1700000000000,
        finished_at = 1700000002300,
        params = { name = "cache", enabled = true },
        files_changed = { "src/a.ts", "src/a.test.ts" },
        prompt = "Generate cache at src/a.ts\nand a test file",
      }
    end

    it("starts with a status line naming the snippet and decorating with duration + exit", function()
      local r = detail.render(success_entry())
      assert.equals("snipai · scaffold", r.title)
      assert.matches("snipai: scaffold", r.lines[1])
      assert.matches("%[success%]", r.lines[1])
      assert.matches("2%.3s", r.lines[1])
      assert.matches("exit 0", r.lines[1])
    end)

    it("always shows Started and Finished (even if missing, as '-')", function()
      local r = detail.render({
        id = "x",
        snippet = "s",
        status = "running",
        started_at = 1700000000000,
      })
      assert.truthy(find_line(r.lines, "Started:"))
      local _, finished = find_line(r.lines, "Finished:")
      assert.matches("%-$", finished)
    end)

    it("omits optional meta rows when the field is nil or empty", function()
      local r = detail.render({
        id = "x",
        snippet = "s",
        status = "success",
      })
      assert.is_nil(find_line(r.lines, "Prefix:"))
      assert.is_nil(find_line(r.lines, "Cwd:"))
    end)

    it("renders a parameters block sorted by key, with typed values", function()
      local r = detail.render(success_entry())
      local joined = lines_joined(r.lines)
      assert.truthy(joined:find("Parameters:", 1, true))
      local enabled_idx = select(1, find_line(r.lines, "enabled = true"))
      local name_idx = select(1, find_line(r.lines, "name = cache"))
      assert.truthy(enabled_idx and name_idx)
      assert.is_true(enabled_idx < name_idx) -- sorted alphabetically
    end)

    it("shows '(none)' when parameters are absent or empty", function()
      local r1 = detail.render({ id = "x", snippet = "s", status = "success" })
      assert.truthy(find_line(r1.lines, "Parameters: (none)"))
      local r2 = detail.render({ id = "x", snippet = "s", status = "success", params = {} })
      assert.truthy(find_line(r2.lines, "Parameters: (none)"))
    end)

    it("files block lists each path on its own line, with a count header", function()
      local r = detail.render(success_entry())
      assert.truthy(find_line(r.lines, "Files changed (2):"))
      assert.truthy(find_line(r.lines, "- src/a.ts"))
      assert.truthy(find_line(r.lines, "- src/a.test.ts"))
    end)

    it("shows '(none)' when no files were changed", function()
      local r = detail.render({
        id = "x",
        snippet = "s",
        status = "success",
        files_changed = {},
      })
      assert.truthy(find_line(r.lines, "Files changed: (none)"))
    end)

    it("renders the prompt block, indented, preserving embedded newlines", function()
      local r = detail.render(success_entry())
      assert.truthy(find_line(r.lines, "Prompt:"))
      assert.truthy(find_line(r.lines, "  Generate cache at src/a.ts"))
      assert.truthy(find_line(r.lines, "  and a test file"))
    end)

    it("omits the prompt block when the prompt is missing or empty", function()
      local r = detail.render({ id = "x", snippet = "s", status = "success" })
      assert.is_nil(find_line(r.lines, "Prompt:"))
    end)

    it("renders a stderr block only for errored entries with stderr", function()
      local r = detail.render({
        id = "x",
        snippet = "s",
        status = "error",
        stderr = "boom\nstack frame",
      })
      assert.truthy(find_line(r.lines, "Stderr:"))
      assert.truthy(find_line(r.lines, "  boom"))
      assert.truthy(find_line(r.lines, "  stack frame"))
    end)

    it("omits stderr for success entries even if the field is populated", function()
      local r = detail.render({
        id = "x",
        snippet = "s",
        status = "success",
        stderr = "should not show",
      })
      assert.is_nil(find_line(r.lines, "Stderr:"))
    end)

    it("separates sections with a single blank line", function()
      local r = detail.render(success_entry())
      -- no two consecutive blank lines
      for i = 2, #r.lines do
        assert.is_false(r.lines[i] == "" and r.lines[i - 1] == "")
      end
    end)

    it("title falls back to id when no snippet name", function()
      local r = detail.render({ id = "abc", status = "success" })
      assert.equals("snipai · abc", r.title)
    end)
  end)

  describe("formatting helpers", function()
    it("fmt_duration matches jobs/job's shape", function()
      assert.equals("-", detail._fmt_duration(nil))
      assert.equals("500ms", detail._fmt_duration(500))
      assert.equals("2.3s", detail._fmt_duration(2300))
      assert.equals("1m05s", detail._fmt_duration(65000))
    end)

    it("fmt_timestamp renders ms-since-epoch as a date string, '-' for nil", function()
      assert.equals("-", detail._fmt_timestamp(nil))
      local stamp = detail._fmt_timestamp(1700000000000)
      -- Exact date depends on TZ; just check the shape.
      assert.matches("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d$", stamp)
    end)

    it("split_lines drops trailing empty lines from a trailing newline", function()
      assert.are.same({ "a", "b" }, detail._split_lines("a\nb\n"))
      assert.are.same({}, detail._split_lines(""))
      assert.are.same({}, detail._split_lines(nil))
    end)
  end)
end)
