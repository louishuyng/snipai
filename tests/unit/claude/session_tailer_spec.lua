local tailer_mod = require("snipai.claude.session_tailer")

local function fake_fs()
  local files = {}
  local fs = {
    files = files,
    read_from = function(_, path, offset)
      local content = files[path] or ""
      if offset >= #content then
        return "", offset
      end
      return content:sub(offset + 1), #content
    end,
    exists = function(_, path)
      return files[path] ~= nil
    end,
  }
  function fs:append(path, chunk)
    files[path] = (files[path] or "") .. chunk
  end
  return fs
end

local function noop_poll()
  return function() end
end

describe("snipai.claude.session_tailer", function()
  it("emits parser events as the file grows", function()
    local fs = fake_fs()
    local got = {}
    local t = tailer_mod.new({
      fs = fs,
      poll_start = noop_poll,
      on_event = function(e)
        got[#got + 1] = e
      end,
    })
    t:start("/fake.jsonl")
    fs:append("/fake.jsonl", '{"type":"assistant","message":{"content":"hi"}}\n')
    t:tick()
    assert.equals(1, #got)
    assert.equals("assistant_text", got[1].kind)
    assert.equals("hi", got[1].text)
  end)

  it("does not re-emit bytes across repeated ticks", function()
    local fs = fake_fs()
    local got = {}
    local t = tailer_mod.new({
      fs = fs,
      poll_start = noop_poll,
      on_event = function(e)
        got[#got + 1] = e
      end,
    })
    t:start("/s.jsonl")
    fs:append("/s.jsonl", '{"type":"assistant","message":{"content":"a"}}\n')
    t:tick()
    t:tick()
    assert.equals(1, #got)
    fs:append("/s.jsonl", '{"type":"assistant","message":{"content":"b"}}\n')
    t:tick()
    assert.equals(2, #got)
  end)

  it("flushes a trailing partial line on stop", function()
    local fs = fake_fs()
    local got = {}
    local t = tailer_mod.new({
      fs = fs,
      poll_start = noop_poll,
      on_event = function(e)
        got[#got + 1] = e
      end,
    })
    t:start("/s.jsonl")
    fs:append("/s.jsonl", '{"type":"assistant","message":{"content":"tail"}}')
    t:stop()
    assert.equals(1, #got)
    assert.equals("tail", got[1].text)
  end)

  it("is a no-op when the file has not yet appeared", function()
    local fs = fake_fs()
    local got = {}
    local t = tailer_mod.new({
      fs = fs,
      poll_start = noop_poll,
      on_event = function(e)
        got[#got + 1] = e
      end,
    })
    t:start("/not-yet.jsonl")
    t:tick()
    assert.equals(0, #got)
    fs:append("/not-yet.jsonl", '{"type":"assistant","message":{"content":"late"}}\n')
    t:tick()
    assert.equals(1, #got)
  end)

  it("invokes the poll_start stop-fn on stop()", function()
    local stop_called = false
    local fs = fake_fs()
    local t = tailer_mod.new({
      fs = fs,
      poll_start = function()
        return function()
          stop_called = true
        end
      end,
      on_event = function() end,
    })
    t:start("/s.jsonl")
    t:stop()
    assert.is_true(stop_called)
  end)
end)
