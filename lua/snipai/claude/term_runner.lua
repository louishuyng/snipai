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

  -- Two TUI quirks we have to work around:
  --
  -- 1. Claude's Ink-based TUI needs ~hundreds of ms to render before
  --    it accepts input reliably. Fire the first chansend from a
  --    defer_fn so the initial bytes don't land during init.
  --
  -- 2. Any embedded newline in the prompt flips the TUI's input into
  --    multi-line mode. In that mode, a plain Enter adds another
  --    newline instead of submitting — the prompt sits in the input
  --    box forever. Bracketed-paste markers (CSI 200 ~ / CSI 201 ~)
  --    tell the TUI "this is pasted content, treat the newlines as
  --    literal input," so the trailing Enter we send a moment later
  --    submits the whole thing at once.
  --
  -- Tests pass prompt_delay_ms = 0 to keep the flow synchronous.
  local BRACKETED_PASTE_START = "\27[200~"
  local BRACKETED_PASTE_END = "\27[201~"

  local delay_ms = opts.prompt_delay_ms
  if delay_ms == nil then
    delay_ms = DEFAULT_PROMPT_DELAY_MS
  end

  local function send_paste_and_submit()
    if handle._done or handle._cancelled then
      return
    end
    p.chansend(job_id, BRACKETED_PASTE_START .. opts.prompt .. BRACKETED_PASTE_END)
    local submit_delay = math.max(50, math.floor(delay_ms > 0 and delay_ms / 2 or 100))
    p.defer_fn(function()
      if handle._done or handle._cancelled then
        return
      end
      p.chansend(job_id, "\r")
    end, submit_delay)
  end

  if delay_ms <= 0 then
    send_paste_and_submit()
  else
    p.defer_fn(send_paste_and_submit, delay_ms)
  end
  return handle
end

M._build_cmd = build_cmd

return M
