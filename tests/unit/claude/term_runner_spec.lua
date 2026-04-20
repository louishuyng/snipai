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
  rec.chansend_calls = {}
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
      rec.chansend_args = { job = job, data = data } -- most-recent wins (back-compat)
      rec.chansend_calls[#rec.chansend_calls + 1] = { job = job, data = data }
    end,
    jobstop = function(job)
      rec.jobstop_calls = rec.jobstop_calls + 1
      rec.jobstop_arg = job
    end,
    defer_fn = function(fn, _ms)
      -- Synchronous defer for tests; we assert chansend effects inline.
      fn()
    end,
  }
  return rec
end

-- Tests default to prompt_delay_ms = 0 so the fake chansend is called
-- synchronously; the real TUI delay is exercised via integration tests.
local function spawn_sync(p, overrides)
  local o = {
    prompt = "hello",
    session_id = "11111111-1111-1111-1111-111111111111",
    snippet_name = "greet",
    prompt_delay_ms = 0,
    on_exit = function() end,
    primitives = p.fns,
  }
  for k, v in pairs(overrides or {}) do
    o[k] = v
  end
  return term_runner.spawn(o)
end

describe("snipai.claude.term_runner", function()
  it("creates a scratch buffer, termopens claude, and sends a bracketed-paste prompt + CR", function()
    local p = fake_primitives()
    local handle = spawn_sync(p, { extra_args = { "--permission-mode", "acceptEdits" } })
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
    assert.equals(2, #p.chansend_calls, "expected one paste chansend + one CR chansend")
    assert.equals("\27[200~hello\27[201~", p.chansend_calls[1].data)
    assert.equals(7, p.chansend_calls[1].job)
    assert.equals("\r", p.chansend_calls[2].data)
    assert.equals(42, handle:bufnr())
    assert.equals(7, handle:job_id())
    assert.equals("11111111-1111-1111-1111-111111111111", handle:session_id())
  end)

  it("wraps multi-line prompts in bracketed-paste markers so embedded newlines do not split the submit", function()
    local p = fake_primitives()
    local prompt = "line one\nline two\n\nafter blank"
    spawn_sync(p, { prompt = prompt })
    assert.equals("\27[200~" .. prompt .. "\27[201~", p.chansend_calls[1].data)
    assert.equals("\r", p.chansend_calls[2].data)
  end)

  it("honors opts.claude_cmd", function()
    local p = fake_primitives()
    spawn_sync(p, { prompt = "x", session_id = "sid", snippet_name = "s", claude_cmd = "/opt/claude" })
    assert.equals("/opt/claude", p.termopen_args[1])
  end)

  it("cancel() calls jobstop once and flips is_cancelled", function()
    local p = fake_primitives()
    local h = spawn_sync(p, { prompt = "x", session_id = "sid", snippet_name = "s" })
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
    local handle_ref
    local captured_cancelled
    p.fns.termopen = function(_, opts)
      handle_ref = { opts = opts }
      return 7
    end
    local h = spawn_sync(p, {
      prompt = "x",
      session_id = "sid",
      snippet_name = "s",
      on_exit = function(_, info)
        captured_cancelled = info.cancelled
      end,
    })
    h:cancel()
    handle_ref.opts.on_exit(7, 15, "exit")
    assert.is_true(captured_cancelled)
    assert.is_true(h:is_cancelled())
  end)

  it("defers the paste + CR when prompt_delay_ms > 0", function()
    local p = fake_primitives()
    local sends = {}
    p.fns.chansend = function(_job, data)
      sends[#sends + 1] = data
    end
    local deferred_fns = {}
    p.fns.defer_fn = function(fn, ms)
      deferred_fns[#deferred_fns + 1] = { fn = fn, ms = ms }
    end

    term_runner.spawn({
      prompt = "hello",
      session_id = "sid",
      snippet_name = "s",
      prompt_delay_ms = 500,
      on_exit = function() end,
      primitives = p.fns,
    })

    -- Nothing sent yet; first defer queued at 500ms.
    assert.equals(0, #sends)
    assert.equals(1, #deferred_fns)
    assert.equals(500, deferred_fns[1].ms)

    -- Fire the outer defer: paste chansend fires, CR defer queued.
    deferred_fns[1].fn()
    assert.equals(1, #sends)
    assert.equals("\27[200~hello\27[201~", sends[1])
    assert.equals(2, #deferred_fns)

    -- Fire the CR defer: the submit lands separately.
    deferred_fns[2].fn()
    assert.equals(2, #sends)
    assert.equals("\r", sends[2])
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
