local term_runner = require("snipai.claude.term_runner")

local function fake_primitives()
  local rec = {
    create_buf_calls = 0,
    termopen_args = nil,
    termopen_opts = nil,
    chansend_args = nil,
    jobstop_calls = 0,
    jobstop_arg = nil,
  }
  rec.fns = {
    create_buf = function()
      rec.create_buf_calls = rec.create_buf_calls + 1
      return 42
    end,
    run_in_buf = function(_, fn)
      fn()
    end,
    termopen = function(cmd, opts)
      rec.termopen_args = cmd
      rec.termopen_opts = opts
      return 7
    end,
    chansend = function(job, data)
      rec.chansend_args = { job = job, data = data }
    end,
    jobstop = function(job)
      rec.jobstop_calls = rec.jobstop_calls + 1
      rec.jobstop_arg = job
    end,
  }
  return rec
end

describe("snipai.claude.term_runner", function()
  it("creates a scratch buffer, termopens claude, and sends the prompt", function()
    local p = fake_primitives()
    local handle = term_runner.spawn({
      prompt = "hello",
      session_id = "11111111-1111-1111-1111-111111111111",
      snippet_name = "greet",
      extra_args = { "--permission-mode", "acceptEdits" },
      on_exit = function() end,
      primitives = p.fns,
    })
    assert.equals(1, p.create_buf_calls)
    assert.are.same({
      "claude",
      "--session-id",
      "11111111-1111-1111-1111-111111111111",
      "--name",
      "greet",
      "--permission-mode",
      "acceptEdits",
    }, p.termopen_args)
    assert.equals(7, p.chansend_args.job)
    assert.equals("hello\r", p.chansend_args.data)
    assert.equals(42, handle:bufnr())
    assert.equals(7, handle:job_id())
    assert.equals("11111111-1111-1111-1111-111111111111", handle:session_id())
  end)

  it("honors opts.claude_cmd", function()
    local p = fake_primitives()
    term_runner.spawn({
      prompt = "x",
      session_id = "sid",
      snippet_name = "s",
      claude_cmd = "/opt/claude",
      on_exit = function() end,
      primitives = p.fns,
    })
    assert.equals("/opt/claude", p.termopen_args[1])
  end)

  it("cancel() calls jobstop once and flips is_cancelled", function()
    local p = fake_primitives()
    local h = term_runner.spawn({
      prompt = "x",
      session_id = "sid",
      snippet_name = "s",
      on_exit = function() end,
      primitives = p.fns,
    })
    assert.is_false(h:is_cancelled())
    assert.is_true(h:cancel())
    assert.equals(1, p.jobstop_calls)
    assert.equals(7, p.jobstop_arg)
    assert.is_true(h:is_cancelled())

    assert.is_false(h:cancel())
    assert.equals(1, p.jobstop_calls)
  end)

  it("fires on_exit with cancelled=true when termopen's on_exit runs after cancel", function()
    local p = fake_primitives()
    local captured
    term_runner.spawn({
      prompt = "x",
      session_id = "sid",
      snippet_name = "s",
      on_exit = function(code, info)
        captured = { code = code, info = info }
      end,
      primitives = p.fns,
    })
    local handle_ref
    -- Re-invoke spawn with a spy on the termopen's on_exit so we can
    -- assert the cancelled flag is propagated.
    p = fake_primitives()
    local captured_cancelled
    p.fns.termopen = function(_, opts)
      -- Simulate the PTY exiting after the caller cancels.
      handle_ref = { opts = opts }
      return 7
    end
    local h = term_runner.spawn({
      prompt = "x",
      session_id = "sid",
      snippet_name = "s",
      on_exit = function(_, info)
        captured_cancelled = info.cancelled
      end,
      primitives = p.fns,
    })
    h:cancel()
    handle_ref.opts.on_exit(7, 15, "exit")
    assert.is_true(captured_cancelled)
    -- first handle captured from earlier spawn is unused; silence unused-var
    assert.is_nil(captured)
  end)

  it("rejects missing required opts", function()
    assert.has_error(function()
      term_runner.spawn({ prompt = "x", session_id = "s", on_exit = function() end })
    end)
    assert.has_error(function()
      term_runner.spawn({ session_id = "s", snippet_name = "n", on_exit = function() end })
    end)
  end)
end)
