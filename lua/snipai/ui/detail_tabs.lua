-- Tabbed detail popup: Summary + Terminal, <Tab>/<S-Tab> swaps the
-- float's buffer via nvim_win_set_buf (no window recreation).

local detail = require("snipai.ui.detail")

local M = {}

local TABS = { "summary", "terminal" }
local LABELS = { summary = "Summary", terminal = "Terminal" }

-- Pure renderer for the tab bar. Active tab is bracketed; the other
-- is plain. Two spaces between entries so the inactive label doesn't
-- visually blur with the active one.
function M.tab_bar_line(active)
  if active ~= "summary" and active ~= "terminal" then
    active = "summary"
  end
  local parts = {}
  for _, t in ipairs(TABS) do
    if t == active then
      parts[#parts + 1] = "[ " .. LABELS[t] .. " ]"
    else
      parts[#parts + 1] = "  " .. LABELS[t] .. " "
    end
  end
  return parts[1] .. " " .. parts[2]
end

local function clamp(v, lo, hi)
  if v < lo then
    return lo
  end
  if v > hi then
    return hi
  end
  return v
end

local function placeholder_terminal_buf(api)
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, {
    "(no terminal — session not active)",
    "",
    "This history entry was not produced under the session-terminal",
    "backend, or its PTY has already been closed.",
  })
  api.nvim_buf_set_option(buf, "modifiable", false)
  api.nvim_buf_set_option(buf, "bufhidden", "wipe")
  return buf
end

-- open(entry, opts)
--   entry               history row
--   opts.terminal_buf   PTY buffer for live / past sessions; optional
--   opts.api            nvim api override (tests)
function M.open(entry, opts)
  opts = opts or {}
  local api = opts.api or vim.api

  local summary_buf, rendered = detail.build_summary_buf(entry, api)
  local terminal_buf = opts.terminal_buf
  if not terminal_buf or not api.nvim_buf_is_valid(terminal_buf) then
    terminal_buf = placeholder_terminal_buf(api)
  end

  local columns = vim.o.columns or 120
  local lines_total = vim.o.lines or 40
  local width = clamp(math.max(70, math.floor(columns * 0.7)), 70, columns - 4)
  local height = clamp(math.max(16, #rendered.lines + 4), 16, math.max(16, lines_total - 6))
  local row = math.floor((lines_total - height) / 2)
  local col = math.floor((columns - width) / 2)

  local win = api.nvim_open_win(summary_buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    border = "rounded",
    title = " " .. rendered.title .. " ",
    title_pos = "center",
  })

  local active = "summary"

  local function set_tab(t)
    if t == active then
      return
    end
    local buf = (t == "terminal") and terminal_buf or summary_buf
    api.nvim_win_set_buf(win, buf)
    active = t
  end

  local function toggle()
    set_tab(active == "summary" and "terminal" or "summary")
  end

  local function close()
    if api.nvim_win_is_valid(win) then
      api.nvim_win_close(win, true)
    end
  end

  for _, b in ipairs({ summary_buf, terminal_buf }) do
    api.nvim_buf_set_keymap(b, "n", "<Tab>", "", {
      nowait = true,
      noremap = true,
      silent = true,
      callback = toggle,
    })
    api.nvim_buf_set_keymap(b, "n", "<S-Tab>", "", {
      nowait = true,
      noremap = true,
      silent = true,
      callback = toggle,
    })
    api.nvim_buf_set_keymap(b, "n", "q", "", {
      nowait = true,
      noremap = true,
      silent = true,
      callback = close,
    })
    api.nvim_buf_set_keymap(b, "n", "<Esc>", "", {
      nowait = true,
      noremap = true,
      silent = true,
      callback = close,
    })
  end

  return {
    win = win,
    summary_buf = summary_buf,
    terminal_buf = terminal_buf,
    set_tab = set_tab,
    current_tab = function()
      return active
    end,
    close = close,
  }
end

return M
