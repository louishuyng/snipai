-- Reloads open Neovim buffers whose file was touched by a Claude run.
--
-- Long sessions edit files across many turns, so we refresh as each
-- new file appears (job_progress) instead of only on job_done. A
-- per-job dedup set stops a single path from being refreshed twice
-- inside one run.

local M = {}

local function default_refresh(files_changed)
  if files_changed == nil or #files_changed == 0 then
    return
  end
  local touched = {}
  for _, path in ipairs(files_changed) do
    touched[path] = true
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" and touched[name] then
        vim.api.nvim_buf_call(buf, function()
          vim.cmd("silent! checktime")
        end)
      end
    end
  end
end

-- attach(events, refresh_fn?)
--   events     event bus with :subscribe
--   refresh_fn optional; fn(files_changed). Production default refreshes
--              loaded buffers; tests pass a recorder.
--
-- Returns an unsubscribe fn that detaches both subscriptions at once.
function M.attach(events, refresh_fn)
  assert(type(events) == "table", "buffer_refresh.attach: events required")
  local refresh = refresh_fn or default_refresh
  -- per-job dedup: weak-keyed so completed jobs get garbage-collected.
  local seen_by_job = setmetatable({}, { __mode = "k" })

  local function refresh_new(job)
    if not job or type(job.files_changed) ~= "function" then
      return
    end
    local all = job:files_changed()
    local already = seen_by_job[job] or {}
    local fresh = {}
    for _, path in ipairs(all) do
      if not already[path] then
        already[path] = true
        fresh[#fresh + 1] = path
      end
    end
    seen_by_job[job] = already
    if #fresh > 0 then
      refresh(fresh)
    end
  end

  local unsub_progress = events:subscribe("job_progress", function(job, _evt)
    refresh_new(job)
  end)
  local unsub_done = events:subscribe("job_done", function(job)
    refresh_new(job)
  end)

  return function()
    if unsub_progress then
      unsub_progress()
    end
    if unsub_done then
      unsub_done()
    end
  end
end

M._default_refresh = default_refresh

return M
