-- End-to-end verification that <Tab> / <S-Tab> actually swap the float's
-- buffer when driven by real Neovim keymaps. A unit test with a stubbed
-- api misses mistakes like "callback option silently falls on the
-- floor of nvim_buf_set_keymap" — which is how the v0.2.0 pre-release
-- shipped a popup where pressing Tab did nothing.

local detail_tabs = require("snipai.ui.detail_tabs")

-- Invoke the buffer-local Lua callback bound to `lhs` in normal mode.
-- nvim_feedkeys in headless mode is flaky across versions — go straight
-- to the keymap entry so we assert what actually matters: "<Tab> is
-- wired to a callable that swaps buffers."
local function trigger(buf, lhs)
  for _, km in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if km.lhs == lhs and type(km.callback) == "function" then
      km.callback()
      return
    end
  end
  error(("no normal-mode keymap for %s on buf %d"):format(lhs, buf))
end

local function current_buf(handle)
  return vim.api.nvim_win_get_buf(handle.win)
end

local function feed_tab(handle)
  trigger(current_buf(handle), "<Tab>")
end

local function feed_stab(handle)
  trigger(current_buf(handle), "<S-Tab>")
end

local function feed_close(handle, lhs)
  trigger(current_buf(handle), lhs)
end

local function make_entry()
  return {
    id = "smoke-1",
    snippet = "smoke",
    prefix = "sm",
    status = "complete",
    exit_code = 0,
    started_at = 1700000000000,
    finished_at = 1700000002300,
    duration_ms = 2300,
    params = { name = "x" },
    files_changed = { "/tmp/smoke.txt" },
    prompt = "do the thing",
  }
end

local function make_terminal_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "fake terminal line" })
  return buf
end

describe("detail_tabs keymap smoke", function()
  local handle

  after_each(function()
    if handle then
      pcall(handle.close)
      handle = nil
    end
  end)

  it("<Tab> in normal mode swaps Summary -> Terminal -> Summary", function()
    local term_buf = make_terminal_buf()
    handle = detail_tabs.open(make_entry(), { terminal_buf = term_buf })

    assert.equals("summary", handle.current_tab())
    assert.equals(handle.summary_buf, current_buf(handle))

    feed_tab(handle)
    assert.equals("terminal", handle.current_tab())
    assert.equals(term_buf, current_buf(handle))

    feed_tab(handle)
    assert.equals("summary", handle.current_tab())
    assert.equals(handle.summary_buf, current_buf(handle))
  end)

  it("<S-Tab> also toggles", function()
    local term_buf = make_terminal_buf()
    handle = detail_tabs.open(make_entry(), { terminal_buf = term_buf })

    feed_stab(handle)
    assert.equals("terminal", handle.current_tab())
    feed_stab(handle)
    assert.equals("summary", handle.current_tab())
  end)

  it("q closes the popup window", function()
    local term_buf = make_terminal_buf()
    handle = detail_tabs.open(make_entry(), { terminal_buf = term_buf })
    local win = handle.win
    assert.is_true(vim.api.nvim_win_is_valid(win))

    feed_close(handle, "q")
    assert.is_false(vim.api.nvim_win_is_valid(win))
  end)

  it("<Esc> closes the popup window", function()
    local term_buf = make_terminal_buf()
    handle = detail_tabs.open(make_entry(), { terminal_buf = term_buf })
    local win = handle.win

    feed_close(handle, "<Esc>")
    assert.is_false(vim.api.nvim_win_is_valid(win))
  end)

  it("falls back to a placeholder when no terminal_buf is provided", function()
    handle = detail_tabs.open(make_entry(), { terminal_buf = nil })
    feed_tab(handle)
    assert.equals("terminal", handle.current_tab())
    local shown = current_buf(handle)
    local lines = vim.api.nvim_buf_get_lines(shown, 0, -1, false)
    assert.matches("no terminal", lines[1])
  end)

  it("every buffer has the <Tab> / <S-Tab> / q / <Esc> callback wired", function()
    local term_buf = make_terminal_buf()
    handle = detail_tabs.open(make_entry(), { terminal_buf = term_buf })
    for _, buf in ipairs({ handle.summary_buf, handle.terminal_buf }) do
      local found = { ["<Tab>"] = false, ["<S-Tab>"] = false, ["q"] = false, ["<Esc>"] = false }
      for _, km in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
        if found[km.lhs] ~= nil then
          assert.is_function(km.callback, km.lhs .. " keymap must carry a Lua callback")
          found[km.lhs] = true
        end
      end
      for lhs, ok in pairs(found) do
        assert.is_true(ok, ("buf %d missing %s"):format(buf, lhs))
      end
    end
  end)
end)
