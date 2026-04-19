local params = require("snipai.params")
local T = params.TYPES

describe("snipai.params", function()
  -- =========================================================================
  -- is_valid_type / is_required
  -- =========================================================================
  describe("is_valid_type", function()
    it("accepts the four declared types", function()
      assert.is_true(params.is_valid_type("string"))
      assert.is_true(params.is_valid_type("text"))
      assert.is_true(params.is_valid_type("select"))
      assert.is_true(params.is_valid_type("boolean"))
    end)

    it("rejects unknown or non-string types", function()
      assert.is_false(params.is_valid_type("number"))
      assert.is_false(params.is_valid_type(""))
      assert.is_false(params.is_valid_type(nil))
      assert.is_false(params.is_valid_type(42))
    end)
  end)

  describe("is_required", function()
    it("is required when there is no default and not marked optional", function()
      assert.is_true(params.is_required({ type = T.STRING }))
    end)

    it("is not required when a default is declared", function()
      assert.is_false(params.is_required({ type = T.STRING, default = "x" }))
    end)

    it("is not required when optional = true", function()
      assert.is_false(params.is_required({ type = T.STRING, optional = true }))
    end)

    it("treats a boolean default=false as still having a default", function()
      -- false is a valid default; don't confuse it with "no default"
      assert.is_false(params.is_required({ type = T.BOOLEAN, default = false }))
    end)
  end)

  -- =========================================================================
  -- validate_definition
  -- =========================================================================
  describe("validate_definition", function()
    it("accepts a minimal string definition", function()
      local ok, err = params.validate_definition({ type = T.STRING })
      assert.is_true(ok)
      assert.is_nil(err)
    end)

    it("accepts string/text/boolean with a valid default", function()
      assert.is_true(params.validate_definition({ type = T.STRING, default = "hi" }))
      assert.is_true(params.validate_definition({ type = T.TEXT, default = "multi\nline" }))
      assert.is_true(params.validate_definition({ type = T.BOOLEAN, default = true }))
      assert.is_true(params.validate_definition({ type = T.BOOLEAN, default = false }))
    end)

    it("accepts select with non-empty options and a default that is in options", function()
      local ok = params.validate_definition({
        type = T.SELECT,
        options = { "ts", "js" },
        default = "ts",
      })
      assert.is_true(ok)
    end)

    it("rejects non-table definitions", function()
      local ok, err = params.validate_definition("nope")
      assert.is_false(ok)
      assert.matches("must be a table", err)
    end)

    it("rejects missing or invalid type", function()
      local ok, err = params.validate_definition({})
      assert.is_false(ok)
      assert.matches("invalid type", err)

      ok, err = params.validate_definition({ type = "number" })
      assert.is_false(ok)
      assert.matches("invalid type", err)
    end)

    it("rejects select without options", function()
      local ok, err = params.validate_definition({ type = T.SELECT })
      assert.is_false(ok)
      assert.matches("non%-empty options", err)
    end)

    it("rejects select with empty options", function()
      local ok, err = params.validate_definition({ type = T.SELECT, options = {} })
      assert.is_false(ok)
      assert.matches("non%-empty options", err)
    end)

    it("rejects select with non-string options", function()
      local ok, err = params.validate_definition({ type = T.SELECT, options = { "ts", 42 } })
      assert.is_false(ok)
      assert.matches("options%[2%] must be a string", err)
    end)

    it("rejects select default not in options", function()
      local ok, err = params.validate_definition({
        type = T.SELECT,
        options = { "ts", "js" },
        default = "rust",
      })
      assert.is_false(ok)
      assert.matches("default value does not match", err)
    end)

    it("rejects default whose type doesn't match (string def, number default)", function()
      local ok, err = params.validate_definition({ type = T.STRING, default = 123 })
      assert.is_false(ok)
      assert.matches("default value does not match", err)
    end)

    it("rejects boolean default on a string def", function()
      local ok, err = params.validate_definition({ type = T.STRING, default = true })
      assert.is_false(ok)
      assert.matches("default value does not match", err)
    end)

    it("rejects string default on a boolean def", function()
      local ok, err = params.validate_definition({ type = T.BOOLEAN, default = "true" })
      assert.is_false(ok)
      assert.matches("default value does not match", err)
    end)
  end)

  -- =========================================================================
  -- validate_value
  -- =========================================================================
  describe("validate_value", function()
    describe("string", function()
      local def = { type = T.STRING }

      it("accepts a non-empty string", function()
        assert.is_true(params.validate_value(def, "hello"))
      end)

      it("rejects empty string when required", function()
        local ok, err = params.validate_value(def, "")
        assert.is_false(ok)
        assert.matches("required", err)
      end)

      it("rejects nil when required", function()
        local ok, err = params.validate_value(def, nil)
        assert.is_false(ok)
        assert.matches("required", err)
      end)

      it("accepts empty when optional", function()
        assert.is_true(params.validate_value({ type = T.STRING, optional = true }, ""))
        assert.is_true(params.validate_value({ type = T.STRING, optional = true }, nil))
      end)

      it("accepts empty when a default is set", function()
        assert.is_true(params.validate_value({ type = T.STRING, default = "x" }, nil))
      end)

      it("rejects a non-string value", function()
        local ok, err = params.validate_value(def, 42)
        assert.is_false(ok)
        assert.matches("expected string", err)
      end)

      it("rejects strings containing newlines", function()
        local ok, err = params.validate_value(def, "line1\nline2")
        assert.is_false(ok)
        assert.matches("newlines", err)
      end)
    end)

    describe("text", function()
      local def = { type = T.TEXT }

      it("accepts multi-line content", function()
        assert.is_true(params.validate_value(def, "line1\nline2\nline3"))
      end)

      it("rejects empty when required", function()
        local ok, err = params.validate_value(def, "")
        assert.is_false(ok)
        assert.matches("required", err)
      end)

      it("rejects non-string values", function()
        local ok, err = params.validate_value(def, true)
        assert.is_false(ok)
        assert.matches("expected string", err)
      end)
    end)

    describe("select", function()
      local def = { type = T.SELECT, options = { "ts", "js", "lua" } }

      it("accepts a value in options", function()
        assert.is_true(params.validate_value(def, "ts"))
        assert.is_true(params.validate_value(def, "lua"))
      end)

      it("rejects a value not in options", function()
        local ok, err = params.validate_value(def, "rust")
        assert.is_false(ok)
        assert.matches("not in options", err)
      end)

      it("rejects non-string values", function()
        local ok, err = params.validate_value(def, 1)
        assert.is_false(ok)
        assert.matches("expected string", err)
      end)
    end)

    describe("boolean", function()
      local def = { type = T.BOOLEAN }

      it("accepts true and false", function()
        assert.is_true(params.validate_value(def, true))
        assert.is_true(params.validate_value(def, false))
      end)

      it('rejects strings like "true"', function()
        local ok, err = params.validate_value(def, "true")
        assert.is_false(ok)
        assert.matches("expected boolean", err)
      end)

      it("rejects nil when required", function()
        local ok, err = params.validate_value(def, nil)
        assert.is_false(ok)
        assert.matches("required", err)
      end)

      it("accepts nil when a default is set", function()
        assert.is_true(params.validate_value({ type = T.BOOLEAN, default = true }, nil))
      end)
    end)
  end)

  -- =========================================================================
  -- validate_all
  -- =========================================================================
  describe("validate_all", function()
    local defs = {
      name = { type = T.STRING },
      language = { type = T.SELECT, options = { "ts", "js" }, default = "ts" },
      run_tests = { type = T.BOOLEAN, default = false },
    }

    it("returns true when every field validates", function()
      local ok, errors = params.validate_all(defs, {
        name = "x.ts",
        language = "ts",
        run_tests = true,
      })
      assert.is_true(ok)
      assert.is_nil(errors)
    end)

    it("allows optional fields to be absent", function()
      local ok = params.validate_all(defs, { name = "x.ts" })
      assert.is_true(ok)
    end)

    it("collects errors per field", function()
      local ok, errors = params.validate_all(defs, {
        name = "",
        language = "rust",
      })
      assert.is_false(ok)
      assert.matches("required", errors.name)
      assert.matches("not in options", errors.language)
      assert.is_nil(errors.run_tests)
    end)

    it("accepts empty defs with no values", function()
      assert.is_true(params.validate_all({}, {}))
      assert.is_true(params.validate_all(nil, nil))
    end)
  end)

  -- =========================================================================
  -- resolve_defaults
  -- =========================================================================
  describe("resolve_defaults", function()
    it("fills in defaults for missing values", function()
      local defs = {
        name = { type = T.STRING, default = "untitled" },
        lang = { type = T.SELECT, options = { "ts", "js" }, default = "ts" },
      }
      local resolved = params.resolve_defaults(defs, {})
      assert.equals("untitled", resolved.name)
      assert.equals("ts", resolved.lang)
    end)

    it("fills in default when string value is empty", function()
      local defs = { name = { type = T.STRING, default = "x" } }
      assert.equals("x", params.resolve_defaults(defs, { name = "" }).name)
    end)

    it("keeps the explicit value when present", function()
      local defs = { name = { type = T.STRING, default = "untitled" } }
      assert.equals("custom", params.resolve_defaults(defs, { name = "custom" }).name)
    end)

    it("does NOT replace boolean false with a default of true", function()
      -- false is a valid intentional value and must not be overridden.
      local defs = { flag = { type = T.BOOLEAN, default = true } }
      assert.is_false(params.resolve_defaults(defs, { flag = false }).flag)
    end)

    it("leaves missing values nil when there is no default", function()
      local defs = { name = { type = T.STRING } }
      local resolved = params.resolve_defaults(defs, {})
      assert.is_nil(resolved.name)
    end)

    it("drops keys that aren't declared in defs", function()
      local defs = { name = { type = T.STRING } }
      local resolved = params.resolve_defaults(defs, { name = "a", bogus = "b" })
      assert.equals("a", resolved.name)
      assert.is_nil(resolved.bogus)
    end)

    it("tolerates nil defs and values", function()
      assert.are.same({}, params.resolve_defaults(nil, nil))
    end)
  end)
end)
