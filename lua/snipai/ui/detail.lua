-- Detail popup for a single history entry.
--
-- Shape: floating window over a read-only scratch buffer, markdown
-- filetype so statuslines / colorschemes treat it sensibly, centered
-- on the editor. Closed with `q` or `<Esc>`.
--
-- The rendering is split in two for testability:
--   M.render(entry) -> { lines, title }   pure; unit-tested
--   M.open(entry, opts?)                  nvim-facing wrapper
--
-- The pure half accepts any entry table shaped like a finalized
-- history row (snippet, prefix, status, duration_ms, exit_code, cwd,
-- started_at, finished_at, params, files_changed, prompt, stderr);
-- missing fields render as `-` or the section is dropped entirely.

local M = {}

-- ---------------------------------------------------------------------------
-- Formatting helpers (pure, local-only)
-- ---------------------------------------------------------------------------

local function fmt_timestamp(ms)
  if type(ms) ~= "number" then
    return "-"
  end
  local ok, s = pcall(os.date, "%Y-%m-%d %H:%M:%S", math.floor(ms / 1000))
  if not ok or type(s) ~= "string" then
    return "-"
  end
  return s
end

-- Same shape as jobs/job's format_duration; duplicated to keep the UI
-- layer free of a jobs dependency (which would pull in claude/runner).
local function fmt_duration(ms)
  if type(ms) ~= "number" or ms < 0 then
    return "-"
  end
  if ms < 1000 then
    return ("%dms"):format(ms)
  end
  local s = ms / 1000
  if s < 60 then
    return ("%.1fs"):format(s)
  end
  local mins = math.floor(s / 60)
  local rem = math.floor(s - mins * 60)
  return ("%dm%02ds"):format(mins, rem)
end

local function fmt_value(v)
  if v == nil then
    return ""
  end
  if type(v) == "string" then
    return v
  end
  if type(v) == "boolean" or type(v) == "number" then
    return tostring(v)
  end
  return vim and vim.inspect and vim.inspect(v) or tostring(v)
end

local function split_lines(s)
  if type(s) ~= "string" or s == "" then
    return {}
  end
  local out = {}
  for line in (s .. "\n"):gmatch("([^\n]*)\n") do
    out[#out + 1] = line
  end
  -- strip trailing empties so "foo\n" renders as { "foo" }, not { "foo", "" }
  while #out > 0 and out[#out] == "" do
    out[#out] = nil
  end
  return out
end

local function sorted_keys(t)
  local keys = {}
  for k in pairs(t) do
    keys[#keys + 1] = k
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  return keys
end

-- ---------------------------------------------------------------------------
-- Pure renderer
-- ---------------------------------------------------------------------------

-- 'success' is the legacy token (pre-v0.2.0) for what the 5-state
-- lifecycle now calls 'complete'. Both map to the same badge so old
-- history rows render with current terminology.
local STATUS_BADGE = {
  success = "[complete]",
  complete = "[complete]",
  running = "[running]",
  idle = "[idle]",
  cancelled = "[cancelled]",
  error = "[error]",
}

local function status_line(entry)
  local name = entry.snippet or entry.id or "(unnamed)"
  local badge = STATUS_BADGE[entry.status] or ("[" .. tostring(entry.status or "?") .. "]")
  local tail = {}
  if type(entry.duration_ms) == "number" then
    tail[#tail + 1] = fmt_duration(entry.duration_ms)
  end
  if entry.exit_code ~= nil then
    tail[#tail + 1] = ("exit %s"):format(tostring(entry.exit_code))
  end
  if #tail == 0 then
    return ("snipai: %s  %s"):format(name, badge)
  end
  return ("snipai: %s  %s  %s"):format(name, badge, table.concat(tail, " · "))
end

local function meta_block(entry)
  local lines = {}
  local function row(label, value, always)
    if always or (value ~= nil and value ~= "") then
      lines[#lines + 1] = ("%-10s %s"):format(label .. ":", tostring(value))
    end
  end
  row("ID", entry.id)
  row("Prefix", entry.prefix)
  row("Cwd", entry.cwd)
  row("Started", fmt_timestamp(entry.started_at), true)
  row("Finished", fmt_timestamp(entry.finished_at), true)
  return lines
end

local function params_block(entry)
  local params = entry.params
  if type(params) ~= "table" or next(params) == nil then
    return { "Parameters: (none)" }
  end
  local lines = { "Parameters:" }
  for _, k in ipairs(sorted_keys(params)) do
    lines[#lines + 1] = ("  %s = %s"):format(tostring(k), fmt_value(params[k]))
  end
  return lines
end

local function files_block(entry)
  local files = entry.files_changed
  if type(files) ~= "table" or #files == 0 then
    return { "Files changed: (none)" }
  end
  local lines = { ("Files changed (%d):"):format(#files) }
  for _, path in ipairs(files) do
    lines[#lines + 1] = "  - " .. path
  end
  return lines
end

local function prompt_block(entry)
  local body = split_lines(entry.prompt)
  if #body == 0 then
    return {}
  end
  local lines = { "Prompt:" }
  for _, line in ipairs(body) do
    lines[#lines + 1] = "  " .. line
  end
  return lines
end

local function stderr_block(entry)
  if entry.status ~= "error" then
    return {}
  end
  local err = split_lines(entry.stderr)
  if #err == 0 then
    return {}
  end
  local lines = { "Stderr:" }
  for _, line in ipairs(err) do
    lines[#lines + 1] = "  " .. line
  end
  return lines
end

local function append(dst, src)
  for _, v in ipairs(src) do
    dst[#dst + 1] = v
  end
end

local function blank_line(lines)
  if #lines > 0 and lines[#lines] ~= "" then
    lines[#lines + 1] = ""
  end
end

function M.render(entry)
  assert(type(entry) == "table", "detail.render: entry must be a table")

  local lines = {}
  lines[#lines + 1] = status_line(entry)
  blank_line(lines)
  append(lines, meta_block(entry))
  blank_line(lines)
  append(lines, params_block(entry))
  blank_line(lines)
  append(lines, files_block(entry))

  local prompt = prompt_block(entry)
  if #prompt > 0 then
    blank_line(lines)
    append(lines, prompt)
  end

  local stderr = stderr_block(entry)
  if #stderr > 0 then
    blank_line(lines)
    append(lines, stderr)
  end

  local title = ("snipai · %s"):format(entry.snippet or entry.id or "history")
  return { lines = lines, title = title }
end

-- ---------------------------------------------------------------------------
-- Window wrapper (nvim-facing; not unit-tested)
-- ---------------------------------------------------------------------------

local function clamp(v, lo, hi)
  if v < lo then
    return lo
  end
  if v > hi then
    return hi
  end
  return v
end

-- Builds the summary scratch buffer used as the first tab in
-- ui.detail_tabs. Kept here so the pure renderer and the buffer-
-- construction live in one place.
--
-- opts.bufhidden overrides the default ("wipe") — ui.detail_tabs uses
-- "hide" so tabbing between Summary and Terminal doesn't blow the
-- buffer away the moment a window stops showing it.
function M.build_summary_buf(entry, api, opts)
  api = api or vim.api
  opts = opts or {}
  local rendered = M.render(entry)
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, rendered.lines)
  api.nvim_buf_set_option(buf, "modifiable", false)
  api.nvim_buf_set_option(buf, "readonly", true)
  api.nvim_buf_set_option(buf, "bufhidden", opts.bufhidden or "wipe")
  api.nvim_buf_set_option(buf, "filetype", "markdown")
  return buf, rendered
end

function M.open(entry, opts)
  opts = opts or {}
  local api = opts.api or vim.api
  local buf, rendered = M.build_summary_buf(entry, api)

  local columns = vim.o.columns or 120
  local lines_total = vim.o.lines or 40
  local width = clamp(math.max(60, math.floor(columns * 0.6)), 60, columns - 4)
  local height = clamp(#rendered.lines + 2, 6, math.max(6, lines_total - 6))
  local row = math.floor((lines_total - height) / 2)
  local col = math.floor((columns - width) / 2)

  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " " .. rendered.title .. " ",
    title_pos = "center",
  })

  local function close()
    if api.nvim_win_is_valid(win) then
      api.nvim_win_close(win, true)
    end
  end

  for _, lhs in ipairs({ "q", "<Esc>" }) do
    api.nvim_buf_set_keymap(buf, "n", lhs, "", {
      nowait = true,
      noremap = true,
      silent = true,
      callback = close,
    })
  end

  return { buf = buf, win = win, close = close }
end

-- Exposed for tests that want to verify formatting without opening a window.
M._fmt_duration = fmt_duration
M._fmt_timestamp = fmt_timestamp
M._split_lines = split_lines

return M
