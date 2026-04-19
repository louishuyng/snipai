local cmp_source = require("snipai.sources.cmp")

-- Build a fake snipai top-level: minimum surface the source touches
-- (trigger + _state.{_initialized,registry}). Records trigger calls so
-- execute() can be asserted against the user-visible effect.
local function make_fake_snipai(opts)
  opts = opts or {}
  local trigger_calls = {}
  return {
    trigger = function(name, ctx)
      trigger_calls[#trigger_calls + 1] = { name = name, ctx = ctx }
    end,
    _state = {
      _initialized = opts.initialized ~= false,
      registry = opts.registry,
    },
    _trigger_calls = trigger_calls,
  }
end

local function make_registry(snippets_by_name)
  return {
    lookup_prefix = function(_, query)
      query = query or ""
      local out = {}
      for _, s in pairs(snippets_by_name) do
        if query == "" or s.prefix:sub(1, #query) == query then
          out[#out + 1] = s
        end
      end
      return out
    end,
    get = function(_, name)
      return snippets_by_name[name]
    end,
  }
end

describe("snipai.sources.cmp", function()
  describe("_extract_query", function()
    it("uses params.offset to slice the cursor_before_line", function()
      local q = cmp_source._extract_query({
        context = { cursor_before_line = "local x = sa" },
        offset = 11,
      })
      assert.equals("sa", q)
    end)

    it("falls back to the trailing word pattern when offset is missing", function()
      local q = cmp_source._extract_query({
        context = { cursor_before_line = "local x = sa" },
      })
      assert.equals("sa", q)
    end)

    it("returns empty string when nothing word-like is under the cursor", function()
      local q = cmp_source._extract_query({
        context = { cursor_before_line = "   " },
      })
      assert.equals("", q)
    end)

    it("handles nil params gracefully", function()
      assert.equals("", cmp_source._extract_query(nil))
    end)
  end)

  describe("_to_item", function()
    it("maps snippet fields to a cmp completion item", function()
      local item = cmp_source._to_item({
        name = "sample",
        prefix = "sa",
        body = "generate a {{thing}}",
        description = "sample desc",
      })
      assert.equals("sample", item.label)
      assert.equals("sa", item.filterText)
      -- insertText re-inserts the typed prefix itself so the buffer
      -- stays visually stable until trigger() swaps it for the
      -- rendered template; see _build_trigger_ctx below.
      assert.equals("sa", item.insertText)
      assert.equals(15, item.kind)
      assert.equals("[AI]", item.menu)
      assert.equals("sample desc", item.detail)
      assert.equals("sample", item.data.snippet_name)
    end)

    it("falls back to the body when description is absent", function()
      local item = cmp_source._to_item({
        name = "n",
        prefix = "n",
        body = "hello world",
      })
      assert.equals("hello world", item.detail)
    end)

    it("truncates long bodies with an ellipsis", function()
      local body = string.rep("x", 100)
      local item = cmp_source._to_item({
        name = "n",
        prefix = "n",
        body = body,
      })
      assert.equals(60, #item.detail)
      assert.equals("...", item.detail:sub(-3))
    end)
  end)

  describe("Source:is_available", function()
    it("returns true once setup has run and the registry is present", function()
      local fake = make_fake_snipai({ registry = make_registry({}) })
      local s = cmp_source.new(fake)
      assert.is_true(s:is_available())
    end)

    it("returns false before setup", function()
      local fake = make_fake_snipai({ initialized = false })
      local s = cmp_source.new(fake)
      assert.is_false(s:is_available())
    end)

    it("returns false when the registry is missing", function()
      local fake = make_fake_snipai({ registry = nil })
      local s = cmp_source.new(fake)
      assert.is_false(s:is_available())
    end)
  end)

  describe("Source:get_trigger_characters", function()
    it("returns an empty list (prefix-based matching only)", function()
      local s = cmp_source.new(make_fake_snipai({ registry = make_registry({}) }))
      assert.are.same({}, s:get_trigger_characters())
    end)
  end)

  describe("Source:complete", function()
    it("returns items for snippets whose prefix matches the typed query", function()
      local registry = make_registry({
        sample = { name = "sample", prefix = "sa", body = "generate {{x}}" },
        other = { name = "other", prefix = "ot", body = "do y" },
      })
      local s = cmp_source.new(make_fake_snipai({ registry = registry }))

      local got
      s:complete({
        context = { cursor_before_line = "sa" },
        offset = 1,
      }, function(response)
        got = response
      end)

      assert.truthy(got)
      assert.equals(1, #got.items)
      assert.equals("sample", got.items[1].label)
      assert.is_false(got.isIncomplete)
    end)

    it("returns an empty list when nothing matches the query", function()
      local registry = make_registry({
        only = { name = "only", prefix = "only", body = "b" },
      })
      local s = cmp_source.new(make_fake_snipai({ registry = registry }))
      local got
      s:complete({
        context = { cursor_before_line = "zz" },
        offset = 1,
      }, function(response)
        got = response
      end)
      assert.are.same({}, got.items)
    end)

    it("returns an empty list when state is missing", function()
      local fake = make_fake_snipai({ initialized = false })
      local s = cmp_source.new(fake)
      local got
      s:complete({ context = { cursor_before_line = "sa" } }, function(r)
        got = r
      end)
      assert.are.same({}, got.items)
    end)
  end)

  describe("Source:complete filetype filter", function()
    local snippet_mod = require("snipai.snippet")
    local function make_snip(raw)
      return snippet_mod.new(raw.name, raw)
    end

    local function items_in(registry, ft)
      local s = cmp_source.new(make_fake_snipai({ registry = registry }), {
        filetype = function()
          return ft
        end,
      })
      local got
      s:complete({ context = { cursor_before_line = "" }, offset = 1 }, function(r)
        got = r
      end)
      return got.items
    end

    it("includes snippets with no filetype constraint in every buffer", function()
      local registry = make_registry({
        any = make_snip({ name = "any", prefix = "an", body = "b" }),
      })
      assert.equals(1, #items_in(registry, "markdown"))
      assert.equals(1, #items_in(registry, "lua"))
      assert.equals(1, #items_in(registry, ""))
    end)

    it("includes a string-filetype snippet only in a matching buffer", function()
      local registry = make_registry({
        lua_only = make_snip({
          name = "lua_only",
          prefix = "lu",
          body = "b",
          filetype = "lua",
        }),
      })
      assert.equals(1, #items_in(registry, "lua"))
      assert.equals(0, #items_in(registry, "markdown"))
    end)

    it("includes an array-filetype snippet in any listed buffer", function()
      local registry = make_registry({
        multi = make_snip({
          name = "multi",
          prefix = "mu",
          body = "b",
          filetype = { "lua", "luau" },
        }),
      })
      assert.equals(1, #items_in(registry, "lua"))
      assert.equals(1, #items_in(registry, "luau"))
      assert.equals(0, #items_in(registry, "markdown"))
    end)

    it("mixes filtered and unfiltered snippets in a single buffer", function()
      local registry = make_registry({
        any = make_snip({ name = "any", prefix = "an", body = "b" }),
        lua_only = make_snip({
          name = "lua_only",
          prefix = "lu",
          body = "b",
          filetype = "lua",
        }),
        md_only = make_snip({
          name = "md_only",
          prefix = "md",
          body = "b",
          filetype = "markdown",
        }),
      })
      local names = {}
      for _, item in ipairs(items_in(registry, "lua")) do
        names[#names + 1] = item.label
      end
      table.sort(names)
      assert.are.same({ "any", "lua_only" }, names)
    end)

    it("defaults to vim.bo.filetype when no resolver is injected", function()
      -- In the headless test env we have access to vim; pin a filetype
      -- on the current buffer and assert the built-in path observes it.
      local saved = vim.bo.filetype
      vim.bo.filetype = "lua"
      local registry = make_registry({
        lua_only = make_snip({
          name = "lua_only",
          prefix = "lu",
          body = "b",
          filetype = "lua",
        }),
      })
      local s = cmp_source.new(make_fake_snipai({ registry = registry }))
      local got
      s:complete({ context = { cursor_before_line = "" }, offset = 1 }, function(r)
        got = r
      end)
      vim.bo.filetype = saved
      assert.equals(1, #got.items)
    end)
  end)

  describe("Source:execute", function()
    it("delegates to snipai.trigger with the selected snippet name", function()
      local fake = make_fake_snipai({ registry = make_registry({}) })
      local s = cmp_source.new(fake)
      local cb_called = false
      s:execute({ data = { snippet_name = "sample" } }, function()
        cb_called = true
      end)
      assert.equals(1, #fake._trigger_calls)
      assert.equals("sample", fake._trigger_calls[1].name)
      assert.is_true(cb_called)
    end)

    it("is a no-op when the completion item carries no snipai data", function()
      local fake = make_fake_snipai({ registry = make_registry({}) })
      local s = cmp_source.new(fake)
      s:execute({ label = "something" }, function() end)
      assert.equals(0, #fake._trigger_calls)
    end)

    it("tolerates a nil callback", function()
      local fake = make_fake_snipai({ registry = make_registry({}) })
      local s = cmp_source.new(fake)
      assert.has_no_error(function()
        s:execute({ data = { snippet_name = "sample" } }, nil)
      end)
      assert.equals(1, #fake._trigger_calls)
    end)
  end)

  describe("_build_trigger_ctx", function()
    local snippet_mod = require("snipai.snippet")
    local function make_snip(raw)
      return snippet_mod.new(raw.name, raw)
    end

    it("captures the buffer + the range covering the typed prefix", function()
      local buf = vim.api.nvim_create_buf(false, true)
      -- Trailing space keeps col 9 a valid normal-mode cursor position
      -- (nvim clamps past-last-char in normal mode, which would otherwise
      -- leave us one col short of the intended "cmp-just-confirmed" state).
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "foo ailua bar" })
      vim.api.nvim_set_current_buf(buf)
      vim.api.nvim_win_set_cursor(0, { 1, 9 }) -- just past "ailua"
      local registry = make_registry({
        ailua_module = make_snip({
          name = "ailua_module",
          prefix = "ailua",
          body = "b",
        }),
      })

      local ctx = cmp_source._build_trigger_ctx("ailua_module", registry)

      assert.equals(buf, ctx.buffer)
      assert.truthy(ctx.replace_range)
      assert.equals(0, ctx.replace_range.start.row)
      assert.equals(4, ctx.replace_range.start.col)
      assert.equals(0, ctx.replace_range["end"].row)
      assert.equals(9, ctx.replace_range["end"].col)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("returns just buffer when the snippet is missing from the registry", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(buf)
      local ctx = cmp_source._build_trigger_ctx("missing", make_registry({}))
      assert.equals(buf, ctx.buffer)
      assert.is_nil(ctx.replace_range)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("tolerates a registry without a get method (defensive)", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(buf)
      local ctx = cmp_source._build_trigger_ctx("x", { lookup_prefix = function() end })
      assert.equals(buf, ctx.buffer)
      assert.is_nil(ctx.replace_range)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  describe("register", function()
    it("returns true and registers the source when cmp is available", function()
      cmp_source._reset()
      local registered_name, registered_source
      local fake_cmp = {
        register_source = function(name, src)
          registered_name = name
          registered_source = src
        end,
      }
      local ok = cmp_source.register(make_fake_snipai({ registry = make_registry({}) }), fake_cmp)
      assert.is_true(ok)
      assert.equals("snipai", registered_name)
      assert.truthy(registered_source)
      assert.equals("function", type(registered_source.complete))
    end)

    it("is idempotent: repeat calls do not re-register", function()
      cmp_source._reset()
      local calls = 0
      local fake_cmp = {
        register_source = function()
          calls = calls + 1
        end,
      }
      cmp_source.register(make_fake_snipai({ registry = make_registry({}) }), fake_cmp)
      cmp_source.register(make_fake_snipai({ registry = make_registry({}) }), fake_cmp)
      assert.equals(1, calls)
    end)
  end)
end)
