local registry = require("snipai.registry")

-- --------------------------------------------------------------------------
-- Minimal JSON decoder for tests so this spec runs under standalone busted
-- without a Neovim bootstrap. Only handles the shapes our fixtures use
-- (object at top level, string/bool/nested objects/arrays of strings).
-- If you need a case it doesn't cover, inject vim.json.decode or dkjson.
-- --------------------------------------------------------------------------

local json_decode
do
  local ok, dkjson = pcall(require, "dkjson")
  if ok then
    json_decode = function(s)
      local data, _, err = dkjson.decode(s, 1, nil)
      if err then
        return nil, err
      end
      return data
    end
  elseif vim and vim.json and vim.json.decode then
    json_decode = function(s)
      local okd, result = pcall(vim.json.decode, s)
      if not okd then
        return nil, result
      end
      return result
    end
  else
    -- hand-rolled fallback: just enough to unblock tests under bare Lua.
    -- Uses loadstring (Lua 5.1) / load (Lua 5.2+).
    local load_fn = loadstring or load
    json_decode = function(s)
      -- trivially map JSON true/false/null to Lua literals, then eval as a
      -- Lua table literal. This is NOT general JSON — it works because our
      -- fixtures avoid exotic shapes. Good enough for unit tests; production
      -- always uses vim.json.decode.
      local lua_src = s:gsub(":%s*true", " = true")
        :gsub(":%s*false", " = false")
        :gsub(":%s*null", " = nil")
        :gsub('"([^"]+)"%s*:', "[%q]=")
        :gsub("{", "{")
        :gsub("}", "}")
      local chunk, err = load_fn("return " .. lua_src)
      if not chunk then
        return nil, err
      end
      local okc, result = pcall(chunk)
      if not okc then
        return nil, result
      end
      return result
    end
  end
end

-- Helper: build a registry backed by an in-memory file table with the
-- injected json_decode. Captures warnings into an array the test can read.
local function new_registry(files)
  local warnings = {}
  local r = registry.new({
    reader = function(path)
      if files[path] ~= nil then
        return files[path]
      end
      return nil, "No such file"
    end,
    json_decode = json_decode,
    on_warning = function(msg)
      table.insert(warnings, msg)
    end,
  })
  return r, warnings
end

describe("snipai.registry", function()
  -- ========================================================================
  -- construction
  -- ========================================================================
  describe("new", function()
    it("starts empty", function()
      local r = registry.new()
      assert.are.same({}, r:all())
      assert.are.same({}, r:paths())
    end)

    it("applies defaults when opts are omitted", function()
      local r = registry.new()
      assert.is_function(r._reader)
      assert.is_function(r._json_decode)
      assert.is_function(r._on_warning)
    end)
  end)

  -- ========================================================================
  -- load — happy path
  -- ========================================================================
  describe("load", function()
    it("loads a single file with a valid snippet", function()
      local r, warnings = new_registry({
        ["/a.json"] = [[
          {
            "hello": {
              "prefix": "hi",
              "body": "Say hello"
            }
          }
        ]],
      })
      r:load({ "/a.json" })

      local s = r:get("hello")
      assert.truthy(s)
      assert.equals("hi", s.prefix)
      assert.are.same({}, warnings)
    end)

    it("merges multiple files; later paths override earlier by name", function()
      local r = new_registry({
        ["/global.json"] = [[
          {
            "greeting": { "prefix": "hi",  "body": "global version" }
          }
        ]],
        ["/project.json"] = [[
          {
            "greeting": { "prefix": "hi",  "body": "project version" }
          }
        ]],
      })
      r:load({ "/global.json", "/project.json" })

      assert.equals("project version", r:get("greeting").body)
    end)

    it("loads disjoint snippets from multiple files", function()
      local r = new_registry({
        ["/a.json"] = [[ { "a": { "prefix": "pa", "body": "A" } } ]],
        ["/b.json"] = [[ { "b": { "prefix": "pb", "body": "B" } } ]],
      })
      r:load({ "/a.json", "/b.json" })

      assert.truthy(r:get("a"))
      assert.truthy(r:get("b"))
    end)

    it("silently ignores missing files", function()
      local r, warnings = new_registry({
        ["/present.json"] = [[ { "x": { "prefix": "px", "body": "X" } } ]],
      })
      r:load({ "/missing.json", "/present.json" })

      assert.truthy(r:get("x"))
      assert.are.same({}, warnings)
    end)

    it("warns on unexpected read errors (e.g. permission denied)", function()
      local warnings = {}
      local r = registry.new({
        reader = function(_)
          -- Simulate something that is NOT "file doesn't exist", so the
          -- is_missing_file_error heuristic returns false and the warning
          -- branch runs.
          return nil, "Permission denied"
        end,
        json_decode = json_decode,
        on_warning = function(msg)
          table.insert(warnings, msg)
        end,
      })
      r:load({ "/restricted.json" })

      assert.equals(1, #warnings)
      assert.matches("failed to read /restricted%.json", warnings[1])
      assert.matches("Permission denied", warnings[1])
    end)

    it("clears previous snippets on reload", function()
      local r = new_registry({
        ["/a.json"] = [[ { "keep": { "prefix": "k", "body": "K" } } ]],
      })
      r:load({ "/a.json" })
      assert.truthy(r:get("keep"))

      r:load({}) -- no paths
      assert.is_nil(r:get("keep"))
    end)
  end)

  -- ========================================================================
  -- load — error handling
  -- ========================================================================
  describe("load error handling", function()
    it("warns on invalid JSON and skips that file", function()
      local r, warnings = new_registry({
        ["/bad.json"] = "{ not json",
        ["/good.json"] = [[ { "g": { "prefix": "g", "body": "G" } } ]],
      })
      r:load({ "/bad.json", "/good.json" })

      assert.truthy(r:get("g"))
      assert.equals(1, #warnings)
      assert.matches("invalid JSON in /bad%.json", warnings[1])
    end)

    it("warns when top-level JSON is not an object", function()
      local r, warnings = new_registry({ ["/arr.json"] = "[1,2,3]" })
      r:load({ "/arr.json" })

      assert.equals(1, #warnings)
      assert.matches("expected JSON object", warnings[1])
    end)

    it("warns on invalid snippet but keeps valid siblings", function()
      local r, warnings = new_registry({
        ["/mixed.json"] = [[
          {
            "good":  { "prefix": "g", "body": "ok" },
            "bad":   { "prefix": "b" }
          }
        ]],
      })
      r:load({ "/mixed.json" })

      assert.truthy(r:get("good"))
      assert.is_nil(r:get("bad"))
      assert.equals(1, #warnings)
      assert.matches("skipping snippet \"bad\"", warnings[1])
      assert.matches("body", warnings[1])
    end)

    it("warns on snippet whose body references an undeclared param", function()
      local r, warnings = new_registry({
        ["/mixed.json"] = [[
          {
            "s": {
              "prefix": "p",
              "body":   "Hi {{missing}}",
              "parameter": { "other": { "type": "string" } }
            }
          }
        ]],
      })
      r:load({ "/mixed.json" })

      assert.is_nil(r:get("s"))
      assert.equals(1, #warnings)
      assert.matches("unknown parameter", warnings[1])
    end)

    it("warns when a snippet value is not a table", function()
      -- construct the JSON manually so we can embed a primitive at the value
      local json = [[ { "bad": 42, "ok": { "prefix": "o", "body": "O" } } ]]
      local r, warnings = new_registry({ ["/x.json"] = json })
      r:load({ "/x.json" })

      assert.truthy(r:get("ok"))
      assert.is_nil(r:get("bad"))
      assert.equals(1, #warnings)
      assert.matches("must be a JSON object", warnings[1])
    end)
  end)

  -- ========================================================================
  -- lookup_prefix
  -- ========================================================================
  describe("lookup_prefix", function()
    local r

    before_each(function()
      r = new_registry({
        ["/x.json"] = [[
          {
            "a":  { "prefix": "aits",     "body": "A" },
            "b":  { "prefix": "aigo",     "body": "B" },
            "c":  { "prefix": "blua",     "body": "C" }
          }
        ]],
      })
      r:load({ "/x.json" })
    end)

    it("returns every snippet whose prefix starts with the query", function()
      local hits = r:lookup_prefix("ai")
      assert.equals(2, #hits)
      local names = {}
      for _, s in ipairs(hits) do
        table.insert(names, s.name)
      end
      table.sort(names)
      assert.are.same({ "a", "b" }, names)
    end)

    it("returns just one when the prefix narrows further", function()
      local hits = r:lookup_prefix("ait")
      assert.equals(1, #hits)
      assert.equals("a", hits[1].name)
    end)

    it("returns empty list when nothing matches", function()
      assert.are.same({}, r:lookup_prefix("zzz"))
    end)

    it("returns everything on empty or nil query", function()
      assert.equals(3, #r:lookup_prefix(""))
      assert.equals(3, #r:lookup_prefix(nil))
    end)

    it("is case-sensitive", function()
      assert.equals(0, #r:lookup_prefix("AI"))
    end)
  end)

  -- ========================================================================
  -- reload / paths
  -- ========================================================================
  describe("reload", function()
    it("re-reads the previously-used paths", function()
      local files = {
        ["/a.json"] = [[ { "s": { "prefix": "p", "body": "one" } } ]],
      }
      local warnings = {}
      local r = registry.new({
        reader = function(path)
          return files[path], (files[path] == nil and "No such file" or nil)
        end,
        json_decode = json_decode,
        on_warning = function(msg)
          table.insert(warnings, msg)
        end,
      })
      r:load({ "/a.json" })
      assert.equals("one", r:get("s").body)

      files["/a.json"] = [[ { "s": { "prefix": "p", "body": "two" } } ]]
      r:reload()
      assert.equals("two", r:get("s").body)
    end)
  end)

  describe("paths", function()
    it("returns a copy of the loaded paths", function()
      local r = new_registry({})
      local input = { "/a.json", "/b.json" }
      r:load(input)
      local got = r:paths()
      assert.are.same(input, got)

      -- mutating the result must not affect the registry's internal list
      table.remove(got, 1)
      assert.are.same({ "/a.json", "/b.json" }, r:paths())
    end)
  end)
end)
