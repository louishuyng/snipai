-- Full session-terminal path: runner.spawn wires fake-claude under a
-- real PTY, the real session_tailer reads the JSONL fake-claude
-- writes, and Job transitions through running → idle. detail_tabs
-- attaches to the live PTY buffer and survives after the session
-- exits so the user can scroll / resume.

local runner = require("snipai.claude.runner")
local jobs_mod = require("snipai.jobs")
local history_mod = require("snipai.history")
local events_mod = require("snipai.events")
local notify_mod = require("snipai.notify")
local snippet_mod = require("snipai.snippet")
local detail_tabs = require("snipai.ui.detail_tabs")
local tmphome = require("tests.helpers.tmphome")

local FAKE_CLAUDE = (function()
  local src = debug.getinfo(1, "S").source:sub(2)
  local dir = src:match("(.*)tests/integration/")
  return dir .. "tests/bin/fake-claude"
end)()

local function wait_for(predicate, timeout_ms)
  return vim.wait(timeout_ms or 3000, predicate, 50)
end

local function silent_notify()
  return notify_mod.new({
    backend = function() end,
    levels = { TRACE = 0, DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4, OFF = 5 },
  })
end

local function make_snippet()
  local s = snippet_mod.new("e2e_snippet", {
    prefix = "e2e",
    body = "run the thing",
    parameter = {},
  })
  assert(s:validate())
  return s
end

describe("session-terminal end-to-end", function()
  local home_ctx
  local events
  local history
  local jobs
  local job

  before_each(function()
    home_ctx = tmphome.use()
    events = events_mod.new()
    history = history_mod.new({
      path = home_ctx.home .. "/history.jsonl",
      per_project = false,
    })
    jobs = jobs_mod.new({
      runner = runner,
      history = history,
      events = events,
      notify = silent_notify(),
      claude_opts = {
        cmd = FAKE_CLAUDE,
        extra_args = { "--permission-mode", "acceptEdits" },
      },
    })
  end)

  after_each(function()
    if job and not job:is_done() then
      pcall(function()
        job:cancel()
      end)
      vim.wait(1500, function()
        return job:is_done()
      end, 25)
    end
    job = nil
    if home_ctx then
      tmphome.restore(home_ctx)
      home_ctx = nil
    end
  end)

  it("drives running → idle → cancelled and keeps the transcript reachable", function()
    job = jobs:spawn(make_snippet(), {})
    assert.is_truthy(job, "jobs:spawn must return a job")

    -- Transcript writes from fake-claude should flow through the
    -- tailer into Job's event handler. After one turn we expect
    -- files_changed to include the fake's Edit target.
    local saw_files = wait_for(function()
      for _, f in ipairs(job:files_changed()) do
        if f == "/tmp/fake-claude-touched.txt" then
          return true
        end
      end
      return false
    end)
    assert.is_true(saw_files, "expected files_changed to include fake-claude's Edit target")

    -- A "result" event flips the job to idle.
    local went_idle = wait_for(function()
      return job:status() == "idle"
    end)
    assert.is_true(went_idle, "expected status=idle after result; got " .. job:status())

    -- Pull the live terminal buffer via the jobs manager.
    local term_buf = jobs:get_terminal_buf(job:id())
    assert.is_number(term_buf)
    assert.is_true(vim.api.nvim_buf_is_valid(term_buf))

    -- Detail-tabs opens onto the real PTY buffer.
    local entry = history:get(job:id())
    assert.is_truthy(entry, "history entry must exist for the running session")
    local popup = detail_tabs.open(entry, { terminal_buf = term_buf })
    popup.set_tab("terminal")
    assert.equals(term_buf, vim.api.nvim_win_get_buf(popup.win))
    popup.close()

    -- Cancel the live session; Job should finalize as cancelled.
    jobs:cancel(job:id())
    local cancelled = wait_for(function()
      return job:status() == "cancelled"
    end, 2000)
    assert.is_true(cancelled, "expected status=cancelled; got " .. job:status())
    assert.equals("cancelled", history:get(job:id()).status)

    -- The terminal buffer must survive the session ending so the user
    -- can scroll the transcript / resume from the picker.
    local kept_buf = jobs:get_terminal_buf(job:id())
    assert.equals(term_buf, kept_buf, "jobs:get_terminal_buf must still return the buffer after cancel")
    assert.is_true(vim.api.nvim_buf_is_valid(kept_buf))
  end)

  it("threads session_id from claude-runner into the history entry", function()
    job = jobs:spawn(make_snippet(), {})
    wait_for(function()
      return job:session_id() ~= nil
    end)
    local sid = job:session_id()
    assert.is_string(sid)
    assert.matches("^%x+-%x+-%x+-%x+-%x+$", sid, "session_id should look like a uuid, got " .. tostring(sid))
    assert.equals(sid, history:get(job:id()).session_id)

    -- Transcript file matches the expected Claude Code layout under
    -- the stubbed HOME.
    local cwd_slug = vim.loop.cwd():gsub("/", "-")
    local expected =
      ("%s/.claude/projects/%s/%s.jsonl"):format(home_ctx.home, cwd_slug, sid)
    local has_file = wait_for(function()
      return vim.uv.fs_stat(expected) ~= nil
    end)
    assert.is_true(has_file, "expected transcript at " .. expected)
  end)
end)
