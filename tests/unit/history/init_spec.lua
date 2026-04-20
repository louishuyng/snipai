local history = require("snipai.history")
local json = require("tests.helpers.json")

-- ---------------------------------------------------------------------------
-- In-memory filesystem matching the one used in store_spec, so the two
-- specs exercise the same shape of fs injectable.
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

-- Deterministic id / clock so specs can assert exact values.
local function counter_id(start)
  local n = start or 0
  return function()
    n = n + 1
    return ("id-%d"):format(n)
  end
end

local function fake_clock(start, step)
  local t = start or 1000
  local s = step or 10
  return function()
    local out = t
    t = t + s
    return out
  end
end

local function new_history(opts)
  opts = opts or {}
  local fs = opts.fs or new_fs()
  local h = history.new({
    path = opts.path or "/history.jsonl",
    max_entries = opts.max_entries or 10,
    fs = fs,
    json_encode = json.encode,
    json_decode = json.decode,
    id = opts.id or counter_id(),
    now = opts.now or fake_clock(),
    cwd = opts.cwd or "/work/proj",
    per_project = opts.per_project,
    setqflist = opts.setqflist,
  })
  return h, fs
end

local function capture_qflist()
  local calls = {}
  return function(items, action, what)
    calls[#calls + 1] = { items = items, action = action, what = what }
  end,
    calls
end

describe("snipai.history", function()
  describe("construction", function()
    it("requires a path", function()
      assert.has_error(function()
        history.new({})
      end)
    end)

    it("exposes configured cwd and underlying path", function()
      local h = new_history({ path = "/foo.jsonl", cwd = "/here" })
      assert.equals("/foo.jsonl", h:path())
      assert.equals("/here", h:cwd())
    end)
  end)

  describe("add_pending", function()
    it("stamps id, cwd, started_at, status, and files_changed", function()
      local h = new_history({
        id = counter_id(),
        now = fake_clock(5000, 100),
        cwd = "/proj",
      })
      local entry = h:add_pending({ snippet = "sample_snippet", params = { name = "x" } })
      assert.equals("id-1", entry.id)
      assert.equals("/proj", entry.cwd)
      assert.equals(5000, entry.started_at)
      assert.equals("running", entry.status)
      assert.are.same({}, entry.files_changed)
      assert.equals("sample_snippet", entry.snippet)
    end)

    it("does not mutate the caller's table", function()
      local h = new_history()
      local input = { snippet = "x" }
      h:add_pending(input)
      assert.is_nil(input.id)
      assert.is_nil(input.status)
    end)

    it("persists the pending entry through the store", function()
      local h = new_history()
      local e = h:add_pending({ snippet = "a" })
      local again = h:get(e.id)
      assert.equals("running", again.status)
      assert.equals("a", again.snippet)
    end)

    it("accepts nil entry and still stamps metadata", function()
      local h = new_history()
      local e = h:add_pending(nil)
      assert.equals("running", e.status)
      assert.truthy(e.id)
    end)

    it("rejects non-table entries", function()
      local h = new_history()
      local ok, err = h:add_pending("nope")
      assert.is_nil(ok)
      assert.matches("must be a table", err)
    end)

    it("respects caller-supplied id / started_at / cwd overrides", function()
      local h = new_history()
      local e = h:add_pending({ id = "mine", cwd = "/custom", started_at = 42 })
      assert.equals("mine", e.id)
      assert.equals("/custom", e.cwd)
      assert.equals(42, e.started_at)
    end)
  end)

  describe("finalize", function()
    it("updates a pending entry with success metadata", function()
      local h = new_history({
        id = counter_id(),
        now = fake_clock(1000, 500),
      })
      local pending = h:add_pending({ snippet = "s" }) -- now=1000, next call =>1500
      local final = h:finalize(pending.id, {
        status = "success",
        exit_code = 0,
        files_changed = { "src/a.ts" },
        stdout = "ok",
      })
      assert.equals("success", final.status)
      assert.equals(0, final.exit_code)
      assert.are.same({ "src/a.ts" }, final.files_changed)
      assert.equals(1500, final.finished_at)
      assert.equals(500, final.duration_ms)
      -- get() returns the finalized row
      local fetched = h:get(pending.id)
      assert.equals("success", fetched.status)
    end)

    it("honors caller-supplied duration_ms verbatim", function()
      local h = new_history({ now = fake_clock(1000, 500) })
      local pending = h:add_pending({ snippet = "s" })
      local final = h:finalize(pending.id, { status = "success", duration_ms = 42 })
      assert.equals(42, final.duration_ms)
    end)

    it("records cancelled status", function()
      local h = new_history()
      local pending = h:add_pending({ snippet = "s" })
      local final = h:finalize(pending.id, { status = "cancelled" })
      assert.equals("cancelled", final.status)
    end)

    it("records error status with stderr", function()
      local h = new_history()
      local pending = h:add_pending({ snippet = "s" })
      local final = h:finalize(pending.id, { status = "error", exit_code = 1, stderr = "bad" })
      assert.equals("error", final.status)
      assert.equals(1, final.exit_code)
      assert.equals("bad", final.stderr)
    end)

    it("rejects a non-terminal status", function()
      local h = new_history()
      local pending = h:add_pending({ snippet = "s" })
      local ok, err = h:finalize(pending.id, { status = "running" })
      assert.is_nil(ok)
      assert.matches("success|error|cancelled", err)
    end)

    it("requires a status in the patch", function()
      local h = new_history()
      local pending = h:add_pending({ snippet = "s" })
      local ok, err = h:finalize(pending.id, {})
      assert.is_nil(ok)
      assert.matches("success|error|cancelled", err)
    end)

    it("rejects a patch of the wrong type", function()
      local h = new_history()
      local pending = h:add_pending({ snippet = "s" })
      local ok, err = h:finalize(pending.id, "nope")
      assert.is_nil(ok)
      assert.matches("must be a table", err)
    end)

    it("returns nil+err when the id does not exist", function()
      local h = new_history()
      local ok, err = h:finalize("missing", { status = "success" })
      assert.is_nil(ok)
      assert.matches("not found", err)
    end)

    it("rejects an empty id", function()
      local h = new_history()
      local ok, err = h:finalize("", { status = "success" })
      assert.is_nil(ok)
      assert.matches("non%-empty id", err)
    end)

    it("leaves non-matching entries intact", function()
      local h = new_history()
      local a = h:add_pending({ snippet = "a" })
      local b = h:add_pending({ snippet = "b" })
      h:finalize(a.id, { status = "success" })
      local b_after = h:get(b.id)
      assert.equals("running", b_after.status)
      assert.equals("b", b_after.snippet)
    end)
  end)

  describe("list", function()
    local function seed(h)
      h:add_pending({ snippet = "p1", cwd = "/proj-a" })
      h:add_pending({ snippet = "p2", cwd = "/proj-a" })
      h:add_pending({ snippet = "q1", cwd = "/proj-b" })
      h:add_pending({ snippet = "q2", cwd = "/proj-b" })
    end

    it("returns all entries when scope = 'all'", function()
      local h = new_history({ cwd = "/proj-a" })
      seed(h)
      local entries = h:list({ scope = "all" })
      assert.equals(4, #entries)
    end)

    it("filters by cwd when scope = 'project'", function()
      local h = new_history({ cwd = "/proj-a" })
      seed(h)
      local entries = h:list({ scope = "project" })
      assert.equals(2, #entries)
      assert.equals("/proj-a", entries[1].cwd)
      assert.equals("/proj-a", entries[2].cwd)
    end)

    it("accepts an explicit cwd override for project scope", function()
      local h = new_history({ cwd = "/proj-a" })
      seed(h)
      local entries = h:list({ scope = "project", cwd = "/proj-b" })
      assert.equals(2, #entries)
      assert.equals("/proj-b", entries[1].cwd)
    end)

    it("defaults to project scope when per_project is true", function()
      local h = new_history({ cwd = "/proj-a", per_project = true })
      seed(h)
      local entries = h:list()
      assert.equals(2, #entries)
    end)

    it("defaults to all scope when per_project is false", function()
      local h = new_history({ cwd = "/proj-a", per_project = false })
      seed(h)
      local entries = h:list()
      assert.equals(4, #entries)
    end)

    it("errors on an unknown scope", function()
      local h = new_history()
      local ok, err = h:list({ scope = "weird" })
      assert.is_nil(ok)
      assert.matches("unknown scope", err)
    end)
  end)

  describe("get / clear", function()
    it("get returns nil when not found or not a string", function()
      local h = new_history()
      h:add_pending({ snippet = "a" })
      assert.is_nil(h:get("missing"))
      assert.is_nil(h:get(nil))
      assert.is_nil(h:get(42))
    end)

    it("clear removes the file", function()
      local h, fs = new_history()
      h:add_pending({ snippet = "a" })
      assert.not_nil(fs._files["/history.jsonl"])
      h:clear()
      assert.is_nil(fs._files["/history.jsonl"])
      assert.are.same({}, h:list({ scope = "all" }))
    end)
  end)

  describe("to_quickfix", function()
    local function seed_success(h, files, snippet)
      local e = h:add_pending({ snippet = snippet or "s" })
      h:finalize(e.id, { status = "success", files_changed = files })
      return e.id
    end

    it("pushes one qf item per files_changed with snippet-named title", function()
      local set, calls = capture_qflist()
      local h = new_history({ setqflist = set })
      local id = seed_success(h, { "src/a.ts", "src/a.test.ts" }, "scaffold")

      local items, err = h:to_quickfix(id)
      assert.is_nil(err)
      assert.equals(2, #items)
      assert.equals("src/a.ts", items[1].filename)
      assert.equals(1, items[1].lnum)
      assert.equals(1, items[1].col)
      assert.equals("scaffold", items[1].text)

      assert.equals(1, #calls)
      local call = calls[1]
      assert.are.same({}, call.items)
      assert.equals(" ", call.action)
      assert.equals("snipai: scaffold", call.what.title)
      assert.equals(2, #call.what.items)
      assert.equals("src/a.test.ts", call.what.items[2].filename)
    end)

    it("honors an opts.action override", function()
      local set, calls = capture_qflist()
      local h = new_history({ setqflist = set })
      local id = seed_success(h, { "x" })
      h:to_quickfix(id, { action = "a" })
      assert.equals("a", calls[1].action)
    end)

    it("rejects an empty or non-string id", function()
      local h = new_history()
      local ok1, err1 = h:to_quickfix("")
      assert.is_nil(ok1)
      assert.matches("non%-empty id", err1)
      local ok2, err2 = h:to_quickfix(nil)
      assert.is_nil(ok2)
      assert.matches("non%-empty id", err2)
    end)

    it("returns nil+err when the id is not found", function()
      local set, calls = capture_qflist()
      local h = new_history({ setqflist = set })
      local ok, err = h:to_quickfix("missing")
      assert.is_nil(ok)
      assert.matches("not found", err)
      assert.equals(0, #calls)
    end)

    it("returns nil+err when the entry has no files_changed", function()
      local set, calls = capture_qflist()
      local h = new_history({ setqflist = set })
      local id = seed_success(h, {})
      local ok, err = h:to_quickfix(id)
      assert.is_nil(ok)
      assert.matches("no file changes", err)
      assert.equals(0, #calls)
    end)

    it("still works when the entry has no snippet name", function()
      local set, calls = capture_qflist()
      local h = new_history({ setqflist = set })
      local e = h:add_pending({}) -- no snippet field
      h:finalize(e.id, { status = "success", files_changed = { "f" } })
      local items = h:to_quickfix(e.id)
      assert.equals("snipai", items[1].text)
      assert.matches("snipai:", calls[1].what.title)
    end)
  end)

  describe("round-trip", function()
    it("survives the add_pending → finalize → get path with nested data", function()
      local h = new_history()
      local pending = h:add_pending({
        snippet = "build_hook",
        prefix = "bh",
        params = { name = "cache", enabled = true },
        prompt = "generate the cache invalidation hook",
      })
      h:finalize(pending.id, {
        status = "success",
        exit_code = 0,
        files_changed = { "src/hooks/cache.ts", "src/hooks/cache.test.ts" },
        stdout = "done",
        usage = { input_tokens = 100, output_tokens = 250 },
      })
      local fetched = h:get(pending.id)
      assert.equals("success", fetched.status)
      assert.equals("build_hook", fetched.snippet)
      assert.equals("bh", fetched.prefix)
      assert.is_true(fetched.params.enabled)
      assert.equals(2, #fetched.files_changed)
      assert.equals(250, fetched.usage.output_tokens)
    end)
  end)
end)
