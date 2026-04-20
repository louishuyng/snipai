-- Telescope picker for currently-running snippet jobs.
--
-- Soft-fails (notify + return) when Telescope isn't on the rtp or when
-- there are no active jobs, rather than opening an empty popup or
-- raising. This keeps :SnipaiRunning viable on Telescope-less setups;
-- an fzf-lua / snacks backend can land later behind the same
-- M.open(opts) signature.
--
-- The picker is a point-in-time snapshot: `now_ms` is captured at
-- :open() and used to render elapsed duration. A subscribe-and-refresh
-- picker ships in v0.2 alongside streaming progress.
--
-- M.format_row(job, now_ms) is pure and unit-tested; M.open() is the
-- Telescope wrapper and deliberately smoke-only.

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

local function basename(path)
  if type(path) ~= "string" or path == "" then
    return ""
  end
  return path:match("([^/]+)$") or path
end

-- Row shape, example:
--   scaffold  [running]  3.1s  abc-12de  (init.lua)
function M.format_row(job, now_ms)
  local name = (type(job.snippet_name) == "function" and job:snippet_name()) or "(unknown)"
  local status = (type(job.status) == "function" and job:status()) or "?"
  local id = (type(job.id) == "function" and job:id()) or ""
  local started = type(job.started_at) == "function" and job:started_at() or nil
  local cursor_file = type(job.cursor_file) == "function" and job:cursor_file() or nil

  local duration = ""
  if type(started) == "number" and type(now_ms) == "number" then
    duration = format_duration(now_ms - started)
  end

  local bits = {
    name,
    ("[%s]"):format(status),
  }
  if duration ~= "" then
    bits[#bits + 1] = duration
  end
  if id ~= "" then
    bits[#bits + 1] = short_id(id)
  end
  local base = basename(cursor_file)
  if base ~= "" then
    bits[#bits + 1] = ("(%s)"):format(base)
  end
  return table.concat(bits, "  ")
end

-- ---------------------------------------------------------------------------
-- Telescope resolver (module-wide pcall so the picker soft-fails)
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
-- Open
-- ---------------------------------------------------------------------------

-- opts.jobs      required; snipai.jobs manager (list/cancel/get)
-- opts.history   required; snipai.history instance (for detail lookup)
-- opts.notify    optional; snipai.notify instance
-- opts.detail    optional; defaults to snipai.ui.detail
-- opts.telescope optional; defaults to pcall-resolved telescope bundle
-- opts.now       optional; () -> ms; defaults to os.time()*1000
function M.open(opts)
  opts = opts or {}
  assert(type(opts.jobs) == "table", "pickers.running.open: opts.jobs required")
  assert(type(opts.history) == "table", "pickers.running.open: opts.history required")

  local active = opts.jobs:list() or {}
  if #active == 0 then
    notify(opts.notify, "no active jobs", "info")
    return
  end

  -- opts.telescope semantics: nil => auto-resolve via pcall (production);
  -- false => force "absent" for tests on machines that happen to have
  -- Telescope installed; table => pre-built bundle.
  local ts = opts.telescope
  if ts == nil then
    ts = default_telescope()
  end
  if not ts then
    notify(opts.notify, "Telescope not installed; cannot open running picker", "warn")
    return
  end

  local now_fn = opts.now or function()
    return os.time() * 1000
  end
  local now_ms = now_fn()

  local detail = opts.detail or require("snipai.ui.detail")

  ts.pickers
    .new({}, {
      prompt_title = "snipai · running",
      finder = ts.finders.new_table({
        results = active,
        entry_maker = function(job)
          local display = M.format_row(job, now_ms)
          return {
            value = job,
            display = display,
            ordinal = (type(job.snippet_name) == "function" and job:snippet_name()) or tostring(job),
          }
        end,
      }),
      sorter = ts.conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr, map)
        ts.actions.select_default:replace(function()
          local entry = ts.action_state.get_selected_entry()
          ts.actions.close(prompt_bufnr)
          if entry and entry.value then
            local job = entry.value
            local history_entry = opts.history:get(job:id())
            if history_entry then
              detail.open(history_entry)
            else
              notify(opts.notify, "no history entry for job " .. job:id(), "warn")
            end
          end
        end)

        local function cancel_selected()
          local entry = ts.action_state.get_selected_entry()
          if entry and entry.value then
            opts.jobs:cancel(entry.value:id())
          end
          ts.actions.close(prompt_bufnr)
        end
        map("i", "<C-c>", cancel_selected)
        map("n", "<C-c>", cancel_selected)
        return true
      end,
    })
    :find()
end

-- Exposed for tests.
M._format_duration = format_duration
M._short_id = short_id
M._basename = basename

return M
