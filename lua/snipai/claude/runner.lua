-- Coordinates the PTY-hosted `claude` session and the on-disk session
-- transcript tailer. Callers still see the v0.1.0 contract:
--
--   spawn(prompt, opts, on_event, on_exit) -> handle
--     on_event(evt)      fires per parsed event (from the session JSONL)
--     on_exit(code,info) fires exactly once; info = { cancelled, signal? }
--     handle:cancel()    SIGTERMs the PTY
--     handle:bufnr()     PTY's scratch terminal buffer
--     handle:session_id() claude --session-id <uuid>
--     handle:is_cancelled() / handle:is_done()
--
-- Injection seams (all in opts; fall back to module defaults):
--   opts.term_runner     replaces snipai.claude.term_runner
--   opts.session_paths   replaces snipai.claude.session_paths
--   opts.tailer          replaces snipai.claude.session_tailer
--   opts.tailer_fs       forwarded to tailer.new{ fs = ... }
--   opts.tailer_poll     forwarded to tailer.new{ poll_start = ... }
--   opts.session_id_gen  () -> uuid; defaults to an RFC4122-v4-ish string
--   opts.cwd             defaults to vim.loop.cwd()
--   opts.home            defaults to $HOME
--   opts.cmd             claude binary (defaults to "claude")
--   opts.snippet_name    --name <label>; defaults to "snipai"
--   opts.extra_args      appended after --session-id / --name

local tailer_mod_default = require("snipai.claude.session_tailer")
local term_runner_default = require("snipai.claude.term_runner")
local session_paths_default = require("snipai.claude.session_paths")

local M = {}

-- RFC 4122 v4-ish UUID; not cryptographic, but distinct enough for a
-- Claude Code session id over the lifetime of a single Neovim process.
function M.generate_session_id()
  math.randomseed(os.time())
  local tpl = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  return (
    tpl:gsub("[xy]", function(c)
      local v = (c == "x") and math.random(0, 0xf) or math.random(8, 0xb)
      return string.format("%x", v)
    end)
  )
end

local function default_cwd()
  if vim and vim.loop and vim.loop.cwd then
    return vim.loop.cwd()
  end
  return "."
end

function M.spawn(prompt, opts, on_event, on_exit)
  opts = opts or {}
  assert(type(prompt) == "string" and prompt ~= "", "prompt must be a non-empty string")
  assert(type(on_event) == "function", "on_event must be a function")
  assert(type(on_exit) == "function", "on_exit must be a function")

  local tr = opts.term_runner or term_runner_default
  local sp = opts.session_paths or session_paths_default
  local tailer_mod = opts.tailer or tailer_mod_default
  local uuid = opts.session_id
    or (opts.session_id_gen and opts.session_id_gen())
    or M.generate_session_id()
  local path = sp.session_file({
    session_id = uuid,
    cwd = opts.cwd or default_cwd(),
    home = opts.home,
  })

  local tailer = tailer_mod.new({
    fs = opts.tailer_fs,
    poll_start = opts.tailer_poll,
    on_event = on_event,
  })
  tailer:start(path)

  local finished = false
  local term_handle = tr.spawn({
    prompt = prompt,
    session_id = uuid,
    snippet_name = opts.snippet_name or "snipai",
    claude_cmd = opts.cmd,
    extra_args = opts.extra_args or {},
    primitives = opts.term_primitives,
    prompt_delay_ms = opts.prompt_delay_ms,
    on_exit = function(code, info)
      if finished then
        return
      end
      finished = true
      tailer:stop()
      on_exit(code, info or {})
    end,
  })

  -- Wrap the term handle with session-id + tailer-stop semantics without
  -- rewriting the Handle prototype from term_runner. Delegate everything
  -- else straight through.
  local handle = {}
  function handle:cancel()
    return term_handle:cancel()
  end
  function handle:bufnr()
    return term_handle:bufnr()
  end
  function handle:job_id()
    return term_handle:job_id()
  end
  function handle:session_id()
    return uuid
  end
  function handle:is_cancelled()
    return term_handle:is_cancelled()
  end
  function handle:is_done()
    return term_handle:is_done()
  end
  return handle
end

return M
