-- Spawns the fake-claude shell script under a real PTY to prove
-- term_runner actually runs termopen, sends the initial prompt, and
-- can cancel the job. Isolated from runner.lua so this tier catches
-- termopen / chansend / jobstop regressions on their own.

local term_runner = require("snipai.claude.term_runner")
local tmphome = require("tests.helpers.tmphome")

local FAKE_CLAUDE = (function()
  local src = debug.getinfo(1, "S").source:sub(2)
  local dir = src:match("(.*)tests/integration/")
  return dir .. "tests/bin/fake-claude"
end)()

describe("term_runner with a real PTY", function()
  local home_ctx
  local handle

  before_each(function()
    home_ctx = tmphome.use()
  end)

  after_each(function()
    if handle and not handle:is_done() then
      pcall(function()
        handle:cancel()
      end)
      vim.wait(1000, function()
        return handle:is_done()
      end, 25)
    end
    handle = nil
    if home_ctx then
      tmphome.restore(home_ctx)
      home_ctx = nil
    end
  end)

  it("spawns fake-claude, sends the prompt, and fires on_exit on cancel", function()
    local exit_code, exit_info
    handle = term_runner.spawn({
      prompt = "hello from test",
      session_id = "00000000-0000-0000-0000-000000000042",
      snippet_name = "smoke",
      claude_cmd = FAKE_CLAUDE,
      extra_args = { "--permission-mode", "acceptEdits" },
      on_exit = function(code, info)
        exit_code = code
        exit_info = info
      end,
    })

    assert.is_number(handle:bufnr())
    assert.is_number(handle:job_id())
    assert.is_true(vim.api.nvim_buf_is_valid(handle:bufnr()))

    -- Wait for fake-claude's "turn done" line to land in the terminal.
    local got_output = vim.wait(3000, function()
      local lines = vim.api.nvim_buf_get_lines(handle:bufnr(), 0, -1, false)
      for _, line in ipairs(lines) do
        if line:find("turn done", 1, true) then
          return true
        end
      end
      return false
    end, 50)
    assert.is_true(got_output, "expected 'turn done' in terminal buffer within 3s")

    assert.is_true(handle:cancel())
    assert.is_true(handle:is_cancelled())

    local did_exit = vim.wait(2000, function()
      return exit_code ~= nil
    end, 25)
    assert.is_true(did_exit, "expected on_exit to fire within 2s of cancel")
    assert.is_true(exit_info.cancelled, "on_exit info must carry cancelled=true")
  end)

  it("writes the session transcript to ~/.claude/projects/<slug>/<sid>.jsonl", function()
    handle = term_runner.spawn({
      prompt = "transcript check",
      session_id = "00000000-0000-0000-0000-000000000099",
      snippet_name = "smoke-transcript",
      claude_cmd = FAKE_CLAUDE,
      on_exit = function() end,
    })

    local cwd_slug = vim.loop.cwd():gsub("/", "-")
    local expected = home_ctx.home
      .. "/.claude/projects/"
      .. cwd_slug
      .. "/00000000-0000-0000-0000-000000000099.jsonl"

    local transcript_ready = vim.wait(3000, function()
      return vim.uv.fs_stat(expected) ~= nil
    end, 50)
    assert.is_true(transcript_ready, "expected transcript at " .. expected)

    -- Tailer-free direct read: confirm the fake-claude's three canned
    -- records made it into the file.
    local f = assert(io.open(expected, "r"))
    local content = f:read("*a")
    f:close()
    assert.matches('"type":"assistant"', content)
    assert.matches('"type":"tool_use"', content)
    assert.matches('"type":"result"', content)
  end)
end)
