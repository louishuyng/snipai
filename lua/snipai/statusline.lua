-- Statusline integration with an animated spinner.
--
-- status(bufnr?) returns a frame of a braille spinner plus " snipai" when
-- one of the currently-running jobs has the buffer's file as either its
-- trigger cursor_file or a path it has already touched via Edit / Write /
-- MultiEdit; empty string otherwise.
--
-- The spinner animates via a module-local uv timer that only ticks while
-- active_count > 0, so there is zero cost when no jobs are running. The
-- timer calls :redrawstatus every 100ms and stops as soon as the last
-- job's job_done fires.
--
-- attach(events) wires the job_started / job_done subscriptions that
-- manage the active-count + timer lifecycle. init.lua calls it once at
-- setup() time against the per-setup events bus.
--
-- The module reads job state through the public snipai.jobs.list() +
-- Job:cursor_file() + Job:files_changed() API, so it has no privileged
-- access to internals and is cheap to call on every redraw.

local M = {}

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local LABEL = " snipai"
local TICK_MS = 100

local tick_idx = 1
local timer = nil
local active_count = 0

-- ---------------------------------------------------------------------------
-- Environment helpers (guarded for headless / pure-Lua callers)
-- ---------------------------------------------------------------------------

local function uv()
  return vim and (vim.uv or vim.loop)
end

local function redrawstatus()
  if vim and vim.cmd then
    pcall(vim.cmd, "redrawstatus")
  end
end

local function current_buf()
  if vim and vim.api and vim.api.nvim_get_current_buf then
    return vim.api.nvim_get_current_buf()
  end
end

local function buffer_is_valid(buf)
  if vim and vim.api and vim.api.nvim_buf_is_valid then
    return vim.api.nvim_buf_is_valid(buf)
  end
  return true
end

local function buffer_filename(buf)
  if vim and vim.api and vim.api.nvim_buf_get_name then
    return vim.api.nvim_buf_get_name(buf)
  end
  return ""
end

local function iter_active_jobs()
  local ok, snipai = pcall(require, "snipai")
  if not ok then
    return {}
  end
  local state = snipai._state
  if state == nil or not state._initialized or state.jobs == nil then
    return {}
  end
  local list_ok, list = pcall(function()
    return snipai.jobs.list()
  end)
  if not list_ok or type(list) ~= "table" then
    return {}
  end
  return list
end

-- ---------------------------------------------------------------------------
-- Timer lifecycle
-- ---------------------------------------------------------------------------

local function stop_timer()
  if timer == nil then
    return
  end
  timer:stop()
  if timer.is_closing and not timer:is_closing() then
    timer:close()
  end
  timer = nil
end

local function start_timer()
  if timer ~= nil then
    return
  end
  local loop = uv()
  if loop == nil or type(loop.new_timer) ~= "function" then
    return
  end
  timer = loop.new_timer()
  timer:start(
    0,
    TICK_MS,
    vim.schedule_wrap(function()
      tick_idx = (tick_idx % #SPINNER) + 1
      redrawstatus()
    end)
  )
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- attach(events)
--   Wires job_started / job_done to the active-count + timer. Called once
--   per setup() against the fresh events bus. Resets state so a repeat
--   setup() during the same process does not leak old subscriptions'
--   counters.
function M.attach(events)
  active_count = 0
  stop_timer()
  tick_idx = 1
  if events == nil or type(events.subscribe) ~= "function" then
    return
  end
  events:subscribe("job_started", function()
    active_count = active_count + 1
    start_timer()
  end)
  events:subscribe("job_done", function()
    active_count = math.max(active_count - 1, 0)
    if active_count == 0 then
      stop_timer()
      tick_idx = 1
      -- one final redraw so the indicator clears immediately
      if vim and vim.schedule then
        vim.schedule(redrawstatus)
      else
        redrawstatus()
      end
    end
  end)
end

function M.status(bufnr)
  if active_count == 0 then
    return ""
  end
  local buf = bufnr or current_buf()
  if type(buf) ~= "number" or not buffer_is_valid(buf) then
    return ""
  end
  local file = buffer_filename(buf)
  if file == nil or file == "" then
    return ""
  end
  for _, job in ipairs(iter_active_jobs()) do
    if type(job.cursor_file) == "function" and job:cursor_file() == file then
      return SPINNER[tick_idx] .. LABEL
    end
    if type(job.files_changed) == "function" then
      for _, touched in ipairs(job:files_changed()) do
        if touched == file then
          return SPINNER[tick_idx] .. LABEL
        end
      end
    end
  end
  return ""
end

-- Test-only: reset internal counters + stop the timer between specs.
function M._reset()
  stop_timer()
  active_count = 0
  tick_idx = 1
end

return M
