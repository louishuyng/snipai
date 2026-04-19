local store = require("snipai.history.store")
local json = require("tests.helpers.json")

-- ---------------------------------------------------------------------------
-- In-memory filesystem: lets specs run under standalone busted with zero
-- disk access. Also makes corruption / pruning scenarios easy to exercise.
-- ---------------------------------------------------------------------------

local function new_fs(seed)
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

local function new_store(opts)
  opts = opts or {}
  local fs = opts.fs or new_fs()
  local warnings = {}
  local s = store.new({
    path = opts.path or "/history.jsonl",
    max_entries = opts.max_entries or 10,
    fs = fs,
    json_encode = json.encode,
    json_decode = json.decode,
    on_warning = function(msg)
      table.insert(warnings, msg)
    end,
  })
  return s, fs, warnings
end

describe("snipai.history.store", function()
  -- ========================================================================
  -- construction
  -- ========================================================================
  describe("new", function()
    it("requires a path", function()
      assert.has_error(function()
        store.new({})
      end)
      assert.has_error(function()
        store.new({ path = "" })
      end)
    end)

    it("exposes the configured path", function()
      local s = new_store({ path = "/foo.jsonl" })
      assert.equals("/foo.jsonl", s:path())
    end)
  end)

  -- ========================================================================
  -- append + read_all round-trip
  -- ========================================================================
  describe("append / read_all", function()
    it("returns empty list when file does not exist", function()
      local s = new_store()
      assert.are.same({}, s:read_all())
    end)

    it("writes one entry per call, preserving insertion order", function()
      local s, fs = new_store()

      assert.is_true(s:append({ id = "a", snippet_name = "first" }))
      assert.is_true(s:append({ id = "b", snippet_name = "second" }))
      assert.is_true(s:append({ id = "c", snippet_name = "third" }))

      local entries = s:read_all()
      assert.equals(3, #entries)
      assert.equals("a", entries[1].id)
      assert.equals("b", entries[2].id)
      assert.equals("c", entries[3].id)

      -- One line per entry on disk
      local lines = 0
      for _ in fs._files["/history.jsonl"]:gmatch("[^\n]+") do
        lines = lines + 1
      end
      assert.equals(3, lines)
    end)

    it("rejects non-table entries", function()
      local s = new_store()
      local ok, err = s:append("nope")
      assert.is_nil(ok)
      assert.matches("must be a table", err)
    end)

    it("preserves nested fields through the codec", function()
      local s = new_store()
      s:append({
        id = "complex",
        params = { name = "app.ts", language = "ts" },
        files_changed = { "src/app.ts", "src/app.test.ts" },
        status = "success",
        duration_ms = 4321,
      })
      local entry = s:read_all()[1]
      assert.equals("app.ts", entry.params.name)
      assert.equals("ts", entry.params.language)
      assert.are.same({ "src/app.ts", "src/app.test.ts" }, entry.files_changed)
      assert.equals("success", entry.status)
      assert.equals(4321, entry.duration_ms)
    end)
  end)

  -- ========================================================================
  -- count
  -- ========================================================================
  describe("count", function()
    it("returns 0 for a missing file", function()
      assert.equals(0, new_store():count())
    end)

    it("counts one per non-empty line", function()
      local s = new_store()
      s:append({ id = "1" })
      s:append({ id = "2" })
      s:append({ id = "3" })
      assert.equals(3, s:count())
    end)
  end)

  -- ========================================================================
  -- prune / auto-prune on append
  -- ========================================================================
  describe("prune", function()
    it("is a no-op when under the cap", function()
      local s = new_store({ max_entries = 5 })
      s:append({ id = "a" })
      s:append({ id = "b" })
      assert.is_true(s:prune(5))
      assert.equals(2, s:count())
    end)

    it("keeps the most-recent N when over the cap", function()
      local s = new_store({ max_entries = 3 })
      for i = 1, 5 do
        s:append({ id = ("e%d"):format(i) })
      end
      local entries = s:read_all()
      assert.equals(3, #entries)
      assert.equals("e3", entries[1].id)
      assert.equals("e4", entries[2].id)
      assert.equals("e5", entries[3].id)
    end)

    it("auto-prunes on append when newly over the cap", function()
      local s = new_store({ max_entries = 2 })
      s:append({ id = "a" })
      s:append({ id = "b" })
      s:append({ id = "c" }) -- pushes "a" out
      local entries = s:read_all()
      assert.equals(2, #entries)
      assert.equals("b", entries[1].id)
      assert.equals("c", entries[2].id)
    end)

    it("prune() with explicit lower max trims further", function()
      local s = new_store({ max_entries = 10 })
      for i = 1, 5 do
        s:append({ id = tostring(i) })
      end
      assert.is_true(s:prune(2))
      local entries = s:read_all()
      assert.equals(2, #entries)
      assert.equals("4", entries[1].id)
      assert.equals("5", entries[2].id)
    end)
  end)

  -- ========================================================================
  -- corrupt lines
  -- ========================================================================
  describe("read_all tolerance", function()
    it("skips invalid JSON lines with a warning and keeps valid siblings", function()
      local fs = new_fs({
        ["/history.jsonl"] = '{"id":"good1"}\nthis is not json\n{"id":"good2"}\n',
      })
      local s, _, warnings = new_store({ fs = fs })
      local entries = s:read_all()
      assert.equals(2, #entries)
      assert.equals("good1", entries[1].id)
      assert.equals("good2", entries[2].id)
      assert.equals(1, #warnings)
      assert.matches("invalid history entry", warnings[1])
    end)

    it("ignores blank lines", function()
      local fs = new_fs({
        ["/history.jsonl"] = '{"id":"a"}\n\n{"id":"b"}\n\n',
      })
      local s = new_store({ fs = fs })
      local entries = s:read_all()
      assert.equals(2, #entries)
    end)
  end)

  -- ========================================================================
  -- clear
  -- ========================================================================
  describe("clear", function()
    it("removes the underlying file", function()
      local s, fs = new_store()
      s:append({ id = "a" })
      assert.not_nil(fs._files["/history.jsonl"])
      s:clear()
      assert.is_nil(fs._files["/history.jsonl"])
      assert.are.same({}, s:read_all())
    end)

    it("is a no-op when the file does not exist", function()
      local s = new_store()
      assert.has_no.errors(function()
        s:clear()
      end)
    end)
  end)
end)
