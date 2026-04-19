local snippet = require("snipai.snippet")

local function make(raw)
  return snippet.new("test_snippet", raw)
end

describe("snipai.snippet", function()
  -- =========================================================================
  -- constructor
  -- =========================================================================
  describe("new", function()
    it("rejects empty or non-string names", function()
      assert.has_error(function()
        snippet.new("", {})
      end)
      assert.has_error(function()
        snippet.new(nil, {})
      end)
    end)

    it("rejects non-table definitions", function()
      assert.has_error(function()
        snippet.new("x", "oops")
      end)
    end)

    it("stores declared fields", function()
      local s = snippet.new("typescript_file", {
        description = "make a TS file",
        prefix = "aits",
        body = "Make {{name}}.ts",
        parameter = { name = { type = "string" } },
      })
      assert.equals("typescript_file", s.name)
      assert.equals("make a TS file", s.description)
      assert.equals("aits", s.prefix)
      assert.equals("Make {{name}}.ts", s.body)
      assert.is_table(s.parameter)
    end)

    it("defaults parameter to an empty table when omitted", function()
      local s = snippet.new("x", { prefix = "p", body = "b" })
      assert.are.same({}, s.parameter)
    end)
  end)

  -- =========================================================================
  -- validate
  -- =========================================================================
  describe("validate", function()
    it("accepts a minimal snippet with no params", function()
      local ok = make({ prefix = "hello", body = "Say hello." }):validate()
      assert.is_true(ok)
    end)

    it("accepts a snippet whose body uses only declared params", function()
      local s = make({
        prefix = "ts",
        body = "Create {{name}}.ts with {{content}}",
        parameter = {
          name = { type = "string" },
          content = { type = "text" },
        },
      })
      assert.is_true(s:validate())
    end)

    it("rejects a missing prefix", function()
      local ok, err = make({ body = "x" }):validate()
      assert.is_false(ok)
      assert.matches("prefix", err)
    end)

    it("rejects an empty prefix", function()
      local ok, err = make({ prefix = "", body = "x" }):validate()
      assert.is_false(ok)
      assert.matches("prefix", err)
    end)

    it("rejects a missing body", function()
      local ok, err = make({ prefix = "p" }):validate()
      assert.is_false(ok)
      assert.matches("body", err)
    end)

    it("rejects an empty body", function()
      local ok, err = make({ prefix = "p", body = "" }):validate()
      assert.is_false(ok)
      assert.matches("body", err)
    end)

    it("forwards parameter-definition errors with the param name", function()
      local ok, err = make({
        prefix = "p",
        body = "b",
        parameter = { name = { type = "number" } },
      }):validate()
      assert.is_false(ok)
      assert.matches("parameter \"name\"", err)
      assert.matches("invalid type", err)
    end)

    it("rejects an empty parameter name", function()
      local ok, err = make({
        prefix = "p",
        body = "b",
        parameter = { [""] = { type = "string" } },
      }):validate()
      assert.is_false(ok)
      assert.matches("parameter name", err)
    end)

    it("rejects body that references an undeclared parameter", function()
      local ok, err = make({
        prefix = "p",
        body = "Make {{name}} and {{missing}}",
        parameter = { name = { type = "string" } },
      }):validate()
      assert.is_false(ok)
      assert.matches("unknown parameter \"missing\"", err)
    end)

    it("accepts body that references declared params with surrounding whitespace", function()
      local s = make({
        prefix = "p",
        body = "Hi {{ name }}, welcome.",
        parameter = { name = { type = "string" } },
      })
      assert.is_true(s:validate())
    end)

    it("accepts a string filetype", function()
      local s = make({ prefix = "p", body = "x", filetype = "lua" })
      assert.is_true(s:validate())
    end)

    it("accepts a non-empty array filetype", function()
      local s = make({ prefix = "p", body = "x", filetype = { "lua", "luau" } })
      assert.is_true(s:validate())
    end)

    it("rejects an empty filetype string", function()
      local ok, err = make({ prefix = "p", body = "x", filetype = "" }):validate()
      assert.is_false(ok)
      assert.matches("filetype", err)
    end)

    it("rejects an empty filetype array", function()
      local ok, err = make({ prefix = "p", body = "x", filetype = {} }):validate()
      assert.is_false(ok)
      assert.matches("filetype", err)
    end)

    it("rejects filetype arrays containing non-strings or empty strings", function()
      for _, bad in ipairs({ { "lua", 1 }, { "", "lua" }, { "lua", {} } }) do
        local ok, err = make({ prefix = "p", body = "x", filetype = bad }):validate()
        assert.is_false(ok)
        assert.matches("filetype", err)
      end
    end)

    it("rejects a filetype of an unsupported type", function()
      local ok, err = make({ prefix = "p", body = "x", filetype = 42 }):validate()
      assert.is_false(ok)
      assert.matches("filetype", err)
    end)

    it("accepts an insert field that is a non-empty string", function()
      local s = make({ prefix = "p", body = "b", insert = "-- stub\n" })
      assert.is_true(s:validate())
    end)

    it("accepts insert that references declared params", function()
      local s = make({
        prefix = "p",
        body = "b",
        insert = "-- {{purpose}}\n",
        parameter = { purpose = { type = "text" } },
      })
      assert.is_true(s:validate())
    end)

    it("accepts insert and body that reference reserved built-ins without declaring them", function()
      local s = make({
        prefix = "p",
        body = "enrich {{cursor_file}} at line {{cursor_line}}",
        insert = "-- {{cursor_file}}:{{cursor_line}} in {{cwd}}\n",
      })
      assert.is_true(s:validate())
    end)

    it("rejects insert that is an empty string", function()
      local ok, err = make({ prefix = "p", body = "b", insert = "" }):validate()
      assert.is_false(ok)
      assert.matches("insert", err)
    end)

    it("rejects insert that is not a string", function()
      local ok, err = make({ prefix = "p", body = "b", insert = 42 }):validate()
      assert.is_false(ok)
      assert.matches("insert", err)
    end)

    it("rejects insert that references an undeclared non-reserved placeholder", function()
      local ok, err = make({
        prefix = "p",
        body = "b",
        insert = "hello {{missing}}",
      }):validate()
      assert.is_false(ok)
      assert.matches("insert", err)
      assert.matches("missing", err)
    end)

    it("rejects a declared parameter whose name collides with a reserved built-in", function()
      for name in pairs(require("snipai.snippet").RESERVED) do
        local ok, err = make({
          prefix = "p",
          body = "b",
          parameter = { [name] = { type = "string" } },
        }):validate()
        assert.is_false(ok, "expected " .. name .. " to be rejected")
        assert.matches("reserved", err)
      end
    end)
  end)

  -- =========================================================================
  -- render
  -- =========================================================================
  describe("render", function()
    it("substitutes a single placeholder", function()
      local s = make({
        prefix = "p",
        body = "Create file {{name}}.",
        parameter = { name = { type = "string" } },
      })
      assert.equals("Create file app.ts.", s:render({ name = "app.ts" }))
    end)

    it("substitutes repeated placeholders", function()
      local s = make({
        prefix = "p",
        body = "{{x}} and {{x}} and {{x}}",
        parameter = { x = { type = "string" } },
      })
      assert.equals("hi and hi and hi", s:render({ x = "hi" }))
    end)

    it("allows surrounding whitespace inside {{ }}", function()
      local s = make({
        prefix = "p",
        body = "Hi {{ name }}!",
        parameter = { name = { type = "string" } },
      })
      assert.equals("Hi alice!", s:render({ name = "alice" }))
    end)

    it("fills in defaults when a value is missing", function()
      local s = make({
        prefix = "p",
        body = "Lang: {{lang}}",
        parameter = {
          lang = { type = "select", options = { "ts", "js" }, default = "ts" },
        },
      })
      assert.equals("Lang: ts", s:render({}))
    end)

    it("renders boolean true/false as the literal strings", function()
      local s = make({
        prefix = "p",
        body = "verbose={{v}}",
        parameter = { v = { type = "boolean", default = false } },
      })
      assert.equals("verbose=true", s:render({ v = true }))
      assert.equals("verbose=false", s:render({ v = false }))
    end)

    it("renders nil for optional params with no default as empty string", function()
      local s = make({
        prefix = "p",
        body = "hello{{suffix}}",
        parameter = { suffix = { type = "string", optional = true } },
      })
      assert.equals("hello", s:render({}))
    end)

    it("drops unknown keys from values", function()
      local s = make({
        prefix = "p",
        body = "just {{known}}",
        parameter = { known = { type = "string" } },
      })
      assert.equals("just X", s:render({ known = "X", bogus = "leaks?" }))
    end)

    it("returns nil + per-field errors when validation fails", function()
      local s = make({
        prefix = "p",
        body = "Hi {{name}}",
        parameter = { name = { type = "string" } },
      })
      local out, errors = s:render({}) -- required but missing
      assert.is_nil(out)
      assert.is_table(errors)
      assert.matches("required", errors.name)
    end)

    it("leaves literal text alone when the body has no placeholders", function()
      local s = make({ prefix = "p", body = "Just do it." })
      assert.equals("Just do it.", s:render({}))
    end)

    it("does not recurse into rendered values (a value containing {{x}} stays literal)", function()
      local s = make({
        prefix = "p",
        body = "{{msg}}",
        parameter = {
          msg = { type = "string" },
          other = { type = "string", optional = true },
        },
      })
      assert.equals("hello {{other}}", s:render({ msg = "hello {{other}}" }))
    end)

    it("substitutes reserved built-ins from ctx alongside user params", function()
      local s = make({
        prefix = "p",
        body = "enrich {{cursor_file}}:{{cursor_line}} for {{purpose}}",
        parameter = { purpose = { type = "text" } },
      })
      local out = s:render({ purpose = "logging" }, {
        cursor_file = "/tmp/x.lua",
        cursor_line = 42,
      })
      assert.equals("enrich /tmp/x.lua:42 for logging", out)
    end)

    it("renders missing ctx built-ins as empty strings", function()
      local s = make({
        prefix = "p",
        body = "at {{cursor_file}}!",
      })
      assert.equals("at !", s:render({}, {}))
      assert.equals("at !", s:render({}))
    end)
  end)

  describe("render_insert", function()
    it("returns nil when the snippet has no insert field", function()
      local s = make({ prefix = "p", body = "b" })
      assert.is_nil(s:render_insert({}))
    end)

    it("substitutes user params in the insert template", function()
      local s = make({
        prefix = "p",
        body = "b",
        insert = "-- purpose: {{purpose}}\n",
        parameter = { purpose = { type = "text" } },
      })
      assert.equals("-- purpose: logging\n", s:render_insert({ purpose = "logging" }))
    end)

    it("substitutes reserved built-ins from ctx alongside user params", function()
      local s = make({
        prefix = "p",
        body = "b",
        insert = "-- @{{cursor_file}}:{{cursor_line}} ({{purpose}})\n",
        parameter = { purpose = { type = "text" } },
      })
      local out = s:render_insert(
        { purpose = "auth" },
        { cursor_file = "/proj/auth.lua", cursor_line = 10 }
      )
      assert.equals("-- @/proj/auth.lua:10 (auth)\n", out)
    end)

    it("returns nil + errors on validation failure (same contract as render)", function()
      local s = make({
        prefix = "p",
        body = "b",
        insert = "-- {{purpose}}\n",
        parameter = { purpose = { type = "string" } }, -- required
      })
      local out, errors = s:render_insert({})
      assert.is_nil(out)
      assert.is_table(errors)
      assert.matches("required", errors.purpose)
    end)
  end)

  -- =========================================================================
  -- has_required_params / placeholders
  -- =========================================================================
  describe("has_required_params", function()
    it("is true when any param is required", function()
      local s = make({
        prefix = "p",
        body = "x",
        parameter = {
          a = { type = "string" }, -- required (no default, not optional)
          b = { type = "string", default = "ok" },
        },
      })
      assert.is_true(s:has_required_params())
    end)

    it("is false when all params have defaults or are optional", function()
      local s = make({
        prefix = "p",
        body = "x",
        parameter = {
          a = { type = "string", default = "x" },
          b = { type = "string", optional = true },
        },
      })
      assert.is_false(s:has_required_params())
    end)

    it("is false when there are no params", function()
      assert.is_false(make({ prefix = "p", body = "x" }):has_required_params())
    end)
  end)

  describe("placeholders", function()
    it("returns declared placeholder names, de-duplicated", function()
      local s = make({ prefix = "p", body = "{{a}} {{b}} {{a}} {{ c }}" })
      local list = s:placeholders()
      table.sort(list)
      assert.are.same({ "a", "b", "c" }, list)
    end)

    it("returns an empty table when body has no placeholders", function()
      local s = make({ prefix = "p", body = "plain text" })
      assert.are.same({}, s:placeholders())
    end)
  end)

  describe("matches_filetype", function()
    it("returns true for every buffer when filetype is nil", function()
      local s = make({ prefix = "p", body = "x" })
      assert.is_true(s:matches_filetype("lua"))
      assert.is_true(s:matches_filetype(""))
      assert.is_true(s:matches_filetype("markdown"))
    end)

    it("matches a single filetype string exactly", function()
      local s = make({ prefix = "p", body = "x", filetype = "lua" })
      assert.is_true(s:matches_filetype("lua"))
      assert.is_false(s:matches_filetype("markdown"))
      assert.is_false(s:matches_filetype(""))
    end)

    it("matches any entry in an array filetype", function()
      local s = make({ prefix = "p", body = "x", filetype = { "lua", "luau" } })
      assert.is_true(s:matches_filetype("lua"))
      assert.is_true(s:matches_filetype("luau"))
      assert.is_false(s:matches_filetype("markdown"))
    end)
  end)
end)
