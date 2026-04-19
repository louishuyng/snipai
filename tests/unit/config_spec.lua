local config = require("snipai.config")

-- Deterministic env for every test: no reliance on the user's real
-- XDG_* or $HOME. Path resolution is pure XDG now (no vim.fn.stdpath),
-- so an injected env.config_dir / env.data_dir pins the XDG roots
-- directly.
local TEST_ENV = { config_dir = "/tmp/cfg", data_dir = "/tmp/data" }

describe("snipai.config", function()
  -- ========================================================================
  -- default_config_paths
  -- ========================================================================
  describe("default_config_paths", function()
    it("returns global config + per-project override, in that order", function()
      local paths = config.default_config_paths(TEST_ENV)
      assert.equals("/tmp/cfg/snipai/snippets.json", paths[1])
      assert.equals(".snipai.json", paths[2])
      assert.equals(2, #paths)
    end)

    it("falls back to XDG env vars when no env is injected", function()
      -- setenv is not portable from pure Lua, so just exercise the
      -- fallback path and assert a well-formed non-empty string.
      local paths = config.default_config_paths()
      assert.is_string(paths[1])
      assert.not_equals("", paths[1])
      assert.truthy(paths[1]:find("/snipai/snippets.json", 1, true))
    end)
  end)

  -- ========================================================================
  -- defaults
  -- ========================================================================
  describe("defaults", function()
    it("resolves history.path under the injected data_dir", function()
      local d = config.defaults(TEST_ENV)
      assert.equals("/tmp/data/snipai/history.jsonl", d.history.path)
    end)

    it("produces a complete config surface", function()
      local d = config.defaults(TEST_ENV)

      assert.is_table(d.config_paths)
      assert.is_table(d.history)
      assert.is_table(d.claude)
      assert.is_table(d.ui)
      assert.is_table(d.keymaps)

      assert.equals(500, d.history.max_entries)
      assert.is_true(d.history.per_project)
      assert.equals("claude", d.claude.cmd)
      assert.are.same(
        { "--permission-mode", "acceptEdits", "--setting-sources", "" },
        d.claude.extra_args
      )
      assert.equals(5 * 60 * 1000, d.claude.timeout_ms)
      assert.equals("auto", d.ui.notify)
      assert.equals("telescope", d.ui.picker)
      assert.equals("<leader>sr", d.keymaps.running)
      assert.equals("<leader>sh", d.keymaps.history)
      assert.equals("<leader>sH", d.keymaps.history_all)
    end)

    it("returns a fresh table every call (callers can mutate safely)", function()
      local a = config.defaults(TEST_ENV)
      local b = config.defaults(TEST_ENV)
      a.history.max_entries = 1
      assert.equals(500, b.history.max_entries)
    end)
  end)

  -- ========================================================================
  -- merge
  -- ========================================================================
  describe("merge", function()
    it("returns defaults when user_opts is nil", function()
      local m = config.merge(nil, TEST_ENV)
      assert.equals(500, m.history.max_entries)
    end)

    it("deep-merges history without clobbering other defaults", function()
      local m = config.merge({ history = { max_entries = 42 } }, TEST_ENV)
      assert.equals(42, m.history.max_entries)
      assert.equals("/tmp/data/snipai/history.jsonl", m.history.path)
      assert.is_true(m.history.per_project)
    end)

    it("deep-merges claude", function()
      local m = config.merge({
        claude = { cmd = "/opt/local/claude", timeout_ms = 1000 },
      }, TEST_ENV)
      assert.equals("/opt/local/claude", m.claude.cmd)
      assert.equals(1000, m.claude.timeout_ms)
      assert.are.same(
        { "--permission-mode", "acceptEdits", "--setting-sources", "" },
        m.claude.extra_args
      ) -- untouched
    end)

    it("deep-merges keymaps", function()
      local m = config.merge({ keymaps = { running = "<leader>x" } }, TEST_ENV)
      assert.equals("<leader>x", m.keymaps.running)
      assert.equals("<leader>sh", m.keymaps.history) -- untouched
    end)

    it("accepts keymaps = false to disable all default bindings", function()
      local m = config.merge({ keymaps = false }, TEST_ENV)
      assert.is_false(m.keymaps)
    end)

    it("REPLACES config_paths rather than appending", function()
      local m = config.merge({ config_paths = { "/just/this/one.json" } }, TEST_ENV)
      assert.are.same({ "/just/this/one.json" }, m.config_paths)
    end)

    it("REPLACES nested arrays rather than appending (claude.extra_args)", function()
      local m = config.merge({
        claude = { extra_args = { "--model", "sonnet" } },
      }, TEST_ENV)
      assert.are.same({ "--model", "sonnet" }, m.claude.extra_args)
    end)

    it("preserves non-table user values that shadow defaults", function()
      local m = config.merge({ ui = { notify = "fidget" } }, TEST_ENV)
      assert.equals("fidget", m.ui.notify)
      assert.equals("telescope", m.ui.picker) -- untouched
    end)

    it("includes unknown top-level keys the user passes (extensibility)", function()
      local m = config.merge({ debug = true }, TEST_ENV)
      assert.is_true(m.debug)
    end)

    it("errors on non-table user_opts", function()
      assert.has_error(function()
        config.merge(42, TEST_ENV)
      end)
      assert.has_error(function()
        config.merge("nope", TEST_ENV)
      end)
    end)

    it("does not mutate the user_opts table", function()
      local user = { history = { max_entries = 7 } }
      local snapshot = { history = { max_entries = user.history.max_entries } }
      config.merge(user, TEST_ENV)
      assert.are.same(snapshot, { history = { max_entries = user.history.max_entries } })
    end)
  end)
end)
