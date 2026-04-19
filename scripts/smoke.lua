-- Release smoke test: drive snipai.claude.runner against a real `claude`
-- process to verify the stream-json pipe and parser still line up with
-- whatever version of the CLI is on $PATH. Run this before tagging a
-- release or after a Claude Code update.
--
-- Usage (from repo root):
--   nvim --headless --noplugin -u tests/minimal_init.lua -l scripts/smoke.lua
--   # or: make smoke
--
-- Exit codes:
--   0  success: runner emitted a `result` event with status=success, exit=0
--   1  runner surfaced an error / non-success result / timed out
--   2  `claude` CLI not on PATH, or other environment issue
--
-- Notes:
--   * Uses a trivial prompt ("Reply with exactly the word OK and nothing
--     else.") so the run stays fast (~seconds) and does not touch files.
--   * Not wired into CI. CI stays fixture-only; this exists to catch wire-
--     format drift between the plugin and a freshly upgraded `claude`.

local TIMEOUT_MS = 30 * 1000
local PROMPT = "Reply with exactly the word OK and nothing else."

local function die(code, fmt, ...)
  io.stderr:write(("smoke: " .. fmt .. "\n"):format(...))
  os.exit(code)
end

local function ok(fmt, ...)
  io.stdout:write(("smoke: " .. fmt .. "\n"):format(...))
end

-- 0. Precheck: `claude` on PATH.
do
  local which = vim.fn.executable("claude")
  if which ~= 1 then
    die(2, "`claude` CLI not found on $PATH")
  end
end

local runner = require("snipai.claude.runner")

local events = {}
local exit_seen = false
local exit_code, exit_info

ok("spawning: claude -p %q --output-format stream-json --verbose", PROMPT)
local handle = runner.spawn(PROMPT, {
  timeout_ms = TIMEOUT_MS,
}, function(evt)
  events[#events + 1] = evt
  if evt.kind == "tool_use" then
    ok("  tool_use: %s", tostring(evt.tool))
  elseif evt.kind == "result" then
    ok("  result:   status=%s duration_ms=%s", tostring(evt.status), tostring(evt.duration_ms))
  elseif evt.kind == "system" and evt.subtype == "init" then
    ok("  system:   model=%s session=%s", tostring(evt.model), tostring(evt.session_id))
  end
end, function(code, info)
  exit_seen, exit_code, exit_info = true, code, info
end)

-- vim.wait pumps the event loop so libuv can deliver stdout chunks.
local waited = vim.wait(TIMEOUT_MS + 2000, function()
  return exit_seen
end, 50)

if not waited then
  handle:cancel()
  die(1, "timed out waiting for on_exit after %dms", TIMEOUT_MS)
end

-- Summary.
local kinds = {}
for _, e in ipairs(events) do
  kinds[e.kind] = (kinds[e.kind] or 0) + 1
end
ok("events: %s", vim.inspect(kinds))
ok("exit:   code=%s signal=%s cancelled=%s", tostring(exit_code), tostring(exit_info.signal), tostring(exit_info.cancelled))
if exit_info.stderr and exit_info.stderr ~= "" then
  io.stderr:write("smoke: stderr:\n" .. exit_info.stderr .. "\n")
end
if #exit_info.parser_errors > 0 then
  die(1, "parser reported %d malformed line(s)", #exit_info.parser_errors)
end

-- Assertions.
if exit_code ~= 0 then
  die(1, "expected exit code 0, got %s", tostring(exit_code))
end

local result_evt
for _, e in ipairs(events) do
  if e.kind == "result" then
    result_evt = e
    break
  end
end
if not result_evt then
  die(1, "no `result` event observed in stream")
end
if result_evt.status ~= "success" then
  die(1, "result.status = %q (expected 'success')", tostring(result_evt.status))
end

ok("PASS")
os.exit(0)
