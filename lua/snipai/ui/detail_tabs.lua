-- Tabbed detail popup: Summary + Terminal, <Tab>/<S-Tab> swaps the
-- float's buffer via nvim_win_set_buf (no window recreation).

local detail = require("snipai.ui.detail")

local M = {}

local TABS = { "summary", "terminal" }
local LABELS = { summary = "Summary", terminal = "Terminal" }

-- Pure renderer for the tab bar. Active tab is bracketed; the other
-- is plain. A trailing help hint surfaces <Tab> so users discover the
-- swap without reading docs.
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
  return parts[1] .. " " .. parts[2] .. "   <Tab> swap  ·  q close"
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
  -- bufhidden=hide so tabbing away doesn't wipe the buffer; we clean
  -- it up explicitly when the float closes.
  api.nvim_buf_set_option(buf, "bufhidden", "hide")
  return buf
end

-- open(entry, opts)
--   entry               history row
--   opts.terminal_buf   PTY buffer for live / past sessions; optional
--   opts.api            nvim api override (tests)
function M.open(entry, opts)
  opts = opts or {}
  local api = opts.api or vim.api

  -- bufhidden=hide on both tabs so swapping via nvim_win_set_buf doesn't
  -- wipe the buffer we're leaving. Explicit cleanup below on close().
  local summary_buf, rendered = detail.build_summary_buf(entry, api, { bufhidden = "hide" })
  local terminal_buf = opts.terminal_buf
  local owns_terminal_buf = false
  if not terminal_buf or not api.nvim_buf_is_valid(terminal_buf) then
    terminal_buf = placeholder_terminal_buf(api)
    owns_terminal_buf = true
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

  -- Winbar is the in-float discoverability hook: users see
  -- "[ Summary ]  Terminal   <Tab> swap · q close" the moment the popup
  -- opens. Falls back to a no-op when winbar isn't supported
  -- (<nvim 0.8, or Neovim built without it).
  local function refresh_winbar()
    local ok = pcall(api.nvim_set_option_value, "winbar", M.tab_bar_line(active), { win = win })
    if not ok then
      -- Older Neovim: the per-window option API is different.
      pcall(function()
        vim.wo[win].winbar = M.tab_bar_line(active)
      end)
    end
  end

  local function set_tab(t)
    if t == active then
      return
    end
    local buf = (t == "terminal") and terminal_buf or summary_buf
    api.nvim_win_set_buf(win, buf)
    active = t
    refresh_winbar()
    -- Neovim auto-enters terminal-insert on entering a terminal buffer.
    -- That steals our normal-mode <Tab> mapping, so force normal mode
    -- when the user first lands on the Terminal tab. They press `i` to
    -- start typing to claude.
    if t == "terminal" then
      vim.cmd("stopinsert")
    end
  end

  refresh_winbar()

  local function toggle()
    set_tab(active == "summary" and "terminal" or "summary")
  end

  local function close()
    if api.nvim_win_is_valid(win) then
      api.nvim_win_close(win, true)
    end
    -- We created the summary buf; wipe it. Terminal buf only gets wiped
    -- if we built it as a placeholder — a live PTY buffer is owned by
    -- the job and must survive the popup closing.
    if api.nvim_buf_is_valid(summary_buf) then
      pcall(api.nvim_buf_delete, summary_buf, { force = true })
    end
    if owns_terminal_buf and api.nvim_buf_is_valid(terminal_buf) then
      pcall(api.nvim_buf_delete, terminal_buf, { force = true })
    end
  end

  -- vim.keymap.set supports Lua callbacks; nvim_buf_set_keymap does not
  -- (the `callback` option silently falls on the floor). Use vim.keymap
  -- everywhere so Tab / Shift-Tab / q / <Esc> actually fire.
  --
  -- <Tab> is also bound in terminal-mode (`t`) on the PTY buffer so the
  -- user can swap tabs without manually escaping terminal-insert first.
  -- Tradeoff: Tab no longer reaches claude for autocomplete while the
  -- snipai float is open. Users who need Tab-in-claude can `<C-\><C-n>`
  -- then `i` to loop, same as any terminal buffer.
  local function map(buf, modes, lhs, fn)
    vim.keymap.set(modes, lhs, fn, {
      buffer = buf,
      nowait = true,
      silent = true,
    })
  end

  for _, b in ipairs({ summary_buf, terminal_buf }) do
    map(b, { "n" }, "<Tab>", toggle)
    map(b, { "n" }, "<S-Tab>", toggle)
    map(b, { "n" }, "q", close)
    map(b, { "n" }, "<Esc>", close)
  end
  -- Terminal buffers only — let the user swap tabs from within claude.
  map(terminal_buf, { "t" }, "<Tab>", function()
    -- Leave terminal-insert first so the buffer swap doesn't leave the
    -- summary buffer in a pseudo-insert state.
    vim.cmd("stopinsert")
    vim.schedule(toggle)
  end)

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
