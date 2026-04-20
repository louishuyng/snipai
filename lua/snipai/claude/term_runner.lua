-- Spawns `claude` under a PTY hosted in a hidden Neovim scratch buffer.
-- The rendered prompt is sent via chansend so the session stays alive
-- for follow-up turns (unlike `claude -p` which ends after one turn).

local M = {}

local DEFAULT_PROMPT_DELAY_MS = 500

local function default_primitives()
  return {
    create_buf = function()
      return vim.api.nvim_create_buf(false, true)
    end,
    run_in_buf = function(bufnr, fn)
      vim.api.nvim_buf_call(bufnr, fn)
    end,
    termopen = function(cmd, opts)
      return vim.fn.termopen(cmd, opts)
    end,
    chansend = function(job, data)
      return vim.fn.chansend(job, data)
    end,
    jobstop = function(job)
      return vim.fn.jobstop(job)
    end,
    defer_fn = function(fn, ms)
      return vim.defer_fn(fn, ms)
    end,
  }
end

local function build_cmd(opts)
  local cmd = {
    opts.claude_cmd or "claude",
    "--session-id",
    opts.session_id,
    "--name",
    opts.snippet_name,
  }
  for _, a in ipairs(opts.extra_args or {}) do
    cmd[#cmd + 1] = a
  end
  return cmd
end

local Handle = {}
Handle.__index = Handle

function Handle:bufnr()
  return self._bufnr
end
function Handle:job_id()
  return self._job_id
end
function Handle:session_id()
  return self._session_id
end
function Handle:cancel()
  if self._cancelled or self._done then
    return false
  end
  self._cancelled = true
  self._p.jobstop(self._job_id)
  return true
end
function Handle:is_cancelled()
  return self._cancelled == true
end
function Handle:is_done()
  return self._done == true
end

function M.spawn(opts)
  assert(type(opts) == "table", "term_runner.spawn requires an opts table")
  assert(type(opts.prompt) == "string" and opts.prompt ~= "", "prompt required")
  assert(type(opts.session_id) == "string" and opts.session_id ~= "", "session_id required")
  assert(type(opts.snippet_name) == "string" and opts.snippet_name ~= "", "snippet_name required")
  assert(type(opts.on_exit) == "function", "on_exit required")

  local p = opts.primitives or default_primitives()
  local handle = setmetatable({
    _cancelled = false,
    _done = false,
    _p = p,
    _session_id = opts.session_id,
  }, Handle)

  local bufnr = p.create_buf()
  handle._bufnr = bufnr

  local cmd = build_cmd(opts)
  local job_id
  p.run_in_buf(bufnr, function()
    job_id = p.termopen(cmd, {
      on_exit = function(_, code, _)
        handle._done = true
        opts.on_exit(code, { cancelled = handle._cancelled })
      end,
    })
  end)
  handle._job_id = job_id

  -- Real `claude` boots an Ink-based TUI that needs ~hundreds of ms to
  -- render before it reliably accepts input. If we chansend the prompt
  -- + CR synchronously here, the trailing CR lands during init and gets
  -- swallowed — the prompt sits in the input box until the user presses
  -- Enter manually. Split into two deferred sends so the text settles,
  -- then the submit goes in cleanly. Tests pass 0 to keep the flow
  -- synchronous.
  local delay_ms = opts.prompt_delay_ms
  if delay_ms == nil then
    delay_ms = DEFAULT_PROMPT_DELAY_MS
  end
  if delay_ms <= 0 then
    p.chansend(job_id, opts.prompt .. "\r")
  else
    p.defer_fn(function()
      if handle._done or handle._cancelled then
        return
      end
      p.chansend(job_id, opts.prompt)
      p.defer_fn(function()
        if handle._done or handle._cancelled then
          return
        end
        p.chansend(job_id, "\r")
      end, math.max(50, math.floor(delay_ms / 2)))
    end, delay_ms)
  end
  return handle
end

M._build_cmd = build_cmd

return M
