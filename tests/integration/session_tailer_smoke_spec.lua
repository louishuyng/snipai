-- Real vim.uv.fs_poll + real filesystem. Unit tests for session_tailer
-- stub the poller; this tier proves the live defaults actually detect
-- file growth and drain parsed events into the on_event callback.

local tailer_mod = require("snipai.claude.session_tailer")

local function write_line(path, line)
  local f = assert(io.open(path, "a"))
  f:write(line .. "\n")
  f:close()
end

local function write_create(path, content)
  local f = assert(io.open(path, "w"))
  f:write(content)
  f:close()
end

local function wait_for(predicate, timeout_ms)
  return vim.wait(timeout_ms or 3000, predicate, 50)
end

describe("session_tailer against a real file", function()
  local tmp_path
  local tailer
  local got
  local errors

  before_each(function()
    tmp_path = vim.fn.tempname() .. ".jsonl"
    got = {}
    errors = {}
    tailer = tailer_mod.new({
      on_event = function(evt)
        got[#got + 1] = evt
      end,
      on_error = function(err)
        errors[#errors + 1] = err
      end,
    })
  end)

  after_each(function()
    if tailer then
      pcall(function()
        tailer:stop()
      end)
      tailer = nil
    end
    if tmp_path and vim.uv.fs_stat(tmp_path) then
      vim.fn.delete(tmp_path)
    end
  end)

  it("emits events as the file grows", function()
    -- Prime the file so fs_poll's first callback has something to read.
    write_create(tmp_path, '{"type":"assistant","content":"first"}\n')
    tailer:start(tmp_path)

    local got_first = wait_for(function()
      return #got >= 1
    end)
    assert.is_true(got_first, "expected first event within 3s; got " .. #got)
    assert.equals("first", got[1].text)

    write_line(tmp_path, '{"type":"tool_use","id":"tu_1","name":"Edit","input":{"file_path":"/tmp/a"}}')

    local got_second = wait_for(function()
      return #got >= 2
    end)
    assert.is_true(got_second, "expected second event within 3s; got " .. #got)
    assert.equals("tool_use", got[2].kind)
    assert.equals("/tmp/a", got[2].input.file_path)
  end)

  it("does not re-emit events across multiple writes", function()
    write_create(tmp_path, '{"type":"assistant","content":"one"}\n')
    tailer:start(tmp_path)
    wait_for(function()
      return #got >= 1
    end)

    write_line(tmp_path, '{"type":"assistant","content":"two"}')
    wait_for(function()
      return #got >= 2
    end)

    write_line(tmp_path, '{"type":"assistant","content":"three"}')
    wait_for(function()
      return #got >= 3
    end)

    assert.equals(3, #got, "each write should produce exactly one new event")
    assert.equals("one", got[1].text)
    assert.equals("two", got[2].text)
    assert.equals("three", got[3].text)
  end)

  it("tolerates a file that does not yet exist at start", function()
    tailer:start(tmp_path) -- file absent
    vim.wait(300) -- give the poller time to fire once

    write_create(tmp_path, '{"type":"assistant","content":"late"}\n')
    local got_late = wait_for(function()
      return #got >= 1
    end)
    assert.is_true(got_late, "expected event after the file appeared")
    assert.equals("late", got[1].text)
  end)

  it("flushes a trailing partial line on stop", function()
    write_create(tmp_path, '{"type":"assistant","content":"complete"}\n')
    tailer:start(tmp_path)
    wait_for(function()
      return #got >= 1
    end)

    -- Append without a trailing newline.
    local f = assert(io.open(tmp_path, "a"))
    f:write('{"type":"assistant","content":"partial"}')
    f:close()

    tailer:stop()
    tailer = nil
    -- stop() calls tick+flush synchronously; the partial line must
    -- surface as an event by now.
    assert.equals(2, #got, "stop must flush the trailing partial line")
    assert.equals("partial", got[2].text)
  end)
end)
