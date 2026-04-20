-- Telescope picker for the history log.
--
-- Scope selector: "project" filters by cwd (default when history was
-- configured per_project=true), "all" returns everything.
--
-- Key actions (buffer-local, while the picker is focused):
--   <CR>    open detail popup for the selected entry
--   <C-q>   push the selected entry's files_changed into quickfix,
--           then close the picker
--
-- Replay (<C-r>) and delete (<C-d>) are scoped to v0.2 per CHANGELOG;
-- left out here to keep the v0.1 surface tight.
--
-- Soft-fails (notify + return) when Telescope isn't on the rtp or the
-- history list is empty. M.format_row is pure and unit-tested; M.open
-- is the Telescope wrapper and deliberately smoke-only.

local M = {}

-- ---------------------------------------------------------------------------
-- Formatting helpers (pure)
-- ---------------------------------------------------------------------------

local function format_duration(ms)
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

local function short_id(id, n)
  if type(id) ~= "string" then
    return ""
  end
  return id:sub(1, n or 8)
end

local function format_timestamp(ms)
  if type(ms) ~= "number" then
    return ""
  end
  local ok, s = pcall(os.date, "%H:%M:%S", math.floor(ms / 1000))
  if not ok or type(s) ~= "string" then
    return ""
  end
  return s
end

-- 5-state glyphs aligned with pickers/running. 'success' is accepted
-- as an alias for 'complete' to keep legacy history rows rendering
-- with current terminology.
local STATUS_GLYPH = {
  running = "…",
  idle = "◦",
  complete = "✓",
  success = "✓",
  cancelled = "✗",
  error = "!",
}

-- Example row:
--   + 23:14:02  scaffold  2.3s  2 files  ab12cd34
function M.format_row(entry)
  assert(type(entry) == "table", "format_row: entry must be a table")
  local status = entry.status or "?"
  local glyph = STATUS_GLYPH[status] or "?"
  local time = format_timestamp(entry.started_at)
  local name = entry.snippet or "(unnamed)"
  local dur = format_duration(entry.duration_ms)
  local files = entry.files_changed or {}
  local n_files = #files
  local files_segment
  if n_files == 0 then
    files_segment = "0 files"
  elseif n_files == 1 then
    files_segment = "1 file"
  else
    files_segment = ("%d files"):format(n_files)
  end

  local bits = { glyph }
  if time ~= "" then
    bits[#bits + 1] = time
  end
  bits[#bits + 1] = name
  bits[#bits + 1] = dur
  bits[#bits + 1] = files_segment
  if entry.id then
    bits[#bits + 1] = short_id(entry.id)
  end
  return table.concat(bits, "  ")
end

-- ---------------------------------------------------------------------------
-- Telescope resolver
-- ---------------------------------------------------------------------------

local function default_telescope()
  local ok = pcall(require, "telescope")
  if not ok then
    return nil
  end
  local ok_p, pickers = pcall(require, "telescope.pickers")
  local ok_f, finders = pcall(require, "telescope.finders")
  local ok_c, conf = pcall(require, "telescope.config")
  local ok_a, actions = pcall(require, "telescope.actions")
  local ok_s, action_state = pcall(require, "telescope.actions.state")
  if not (ok_p and ok_f and ok_c and ok_a and ok_s) then
    return nil
  end
  return {
    pickers = pickers,
    finders = finders,
    conf = conf.values,
    actions = actions,
    action_state = action_state,
  }
end

local function notify(notifier, msg, level)
  if notifier and type(notifier.notify) == "function" then
    notifier:notify("snipai: " .. msg, level or "info")
    return
  end
  if vim and vim.notify then
    local lvl = vim.log and vim.log.levels and vim.log.levels[(level or "INFO"):upper()]
    vim.notify("snipai: " .. msg, lvl)
  end
end

-- ---------------------------------------------------------------------------
-- Sorting
-- ---------------------------------------------------------------------------

-- Newest-first by started_at (missing timestamps sort to the end).
local function sort_newest_first(entries)
  table.sort(entries, function(a, b)
    local ta = a.started_at or -math.huge
    local tb = b.started_at or -math.huge
    return ta > tb
  end)
  return entries
end

-- ---------------------------------------------------------------------------
-- Open
-- ---------------------------------------------------------------------------

-- opts.history   required; snipai.history instance (list + to_quickfix)
-- opts.scope     "project" (default) | "all"
-- opts.notify    optional; snipai.notify instance
-- opts.detail    optional; defaults to snipai.ui.detail
-- opts.telescope optional; nil auto-resolve, false force-absent, table = bundle
function M.open(opts)
  opts = opts or {}
  assert(type(opts.history) == "table", "pickers.history.open: opts.history required")

  local scope = opts.scope or "project"
  if scope ~= "project" and scope ~= "all" then
    notify(opts.notify, ("unknown scope: %s"):format(tostring(scope)), "warn")
    return
  end

  local entries, err = opts.history:list({ scope = scope })
  if not entries then
    notify(opts.notify, "history list failed: " .. tostring(err), "error")
    return
  end
  if #entries == 0 then
    notify(opts.notify, ("no history entries (%s scope)"):format(scope), "info")
    return
  end

  sort_newest_first(entries)

  local ts = opts.telescope
  if ts == nil then
    ts = default_telescope()
  end
  if not ts then
    notify(opts.notify, "Telescope not installed; cannot open history picker", "warn")
    return
  end

  local detail_tabs = opts.detail or require("snipai.ui.detail_tabs")
  local jobs_mgr = opts.jobs -- optional; enables terminal tab for still-active entries

  ts.pickers
    .new({}, {
      prompt_title = ("snipai · history (%s)"):format(scope),
      finder = ts.finders.new_table({
        results = entries,
        entry_maker = function(entry)
          return {
            value = entry,
            display = M.format_row(entry),
            ordinal = (entry.snippet or "") .. " " .. (entry.id or ""),
          }
        end,
      }),
      sorter = ts.conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr, map)
        ts.actions.select_default:replace(function()
          local selected = ts.action_state.get_selected_entry()
          ts.actions.close(prompt_bufnr)
          if selected and selected.value then
            local term_buf = jobs_mgr and jobs_mgr:get_terminal_buf(selected.value.id) or nil
            detail_tabs.open(selected.value, { terminal_buf = term_buf })
          end
        end)

        local function to_quickfix()
          local selected = ts.action_state.get_selected_entry()
          ts.actions.close(prompt_bufnr)
          if not (selected and selected.value) then
            return
          end
          local entry = selected.value
          local items, qerr = opts.history:to_quickfix(entry.id)
          if not items then
            notify(opts.notify, qerr, "warn")
            return
          end
          notify(
            opts.notify,
            ("quickfix: %d file%s from %s"):format(#items, #items == 1 and "" or "s", entry.snippet or entry.id),
            "info"
          )
        end
        map("i", "<C-q>", to_quickfix)
        map("n", "<C-q>", to_quickfix)
        return true
      end,
    })
    :find()
end

-- Exposed for tests.
M._format_duration = format_duration
M._format_timestamp = format_timestamp
M._short_id = short_id
M._sort_newest_first = sort_newest_first

return M
