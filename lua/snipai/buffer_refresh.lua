-- Open-buffer refresh on job completion.
--
-- Why this exists: Claude's Edit / Write tools land on disk, but
-- Neovim does not auto-reload open buffers pointing at those files —
-- they keep showing the pre-Claude content until the user hits `:e!`.
-- Subscribing to `job_done` and running `:checktime` per touched file
-- makes the enrichment visible immediately. Buffers whose file Claude
-- never touched, and files the user never opened, are skipped —
-- nothing to reload in either case.
--
-- M.attach(events, refresh_fn?) subscribes to the given bus. The
-- actual refresh is pluggable via opts / argument for tests.

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
--   refresh_fn optional; fn(files_changed) — defaults to a :checktime
--              loop over loaded buffers whose name is in the list
--
-- Returns the unsubscribe handle returned by events:subscribe, for
-- callers that want to detach later. Each setup() call binds to a
-- fresh events bus, so in production the handle is usually ignored.
function M.attach(events, refresh_fn)
  assert(type(events) == "table", "buffer_refresh.attach: events required")
  local refresh = refresh_fn or default_refresh
  return events:subscribe("job_done", function(job)
    local files = job and type(job.files_changed) == "function" and job:files_changed() or {}
    refresh(files)
  end)
end

-- Exposed for tests.
M._default_refresh = default_refresh

return M
