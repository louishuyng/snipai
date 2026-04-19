local parser = require("snipai.claude.parser")
local json = require("tests.helpers.json")

-- Locate the fixtures directory relative to this spec so `busted` and
-- plenary both find them regardless of cwd.
local function spec_dir()
  local source = debug.getinfo(1, "S").source
  return source:sub(2):match("(.*/)")
end
local FIXTURES = spec_dir() .. "../../fixtures/claude/"

local function read_fixture(name)
  local f = assert(io.open(FIXTURES .. name, "r"))
  local contents = f:read("*a")
  f:close()
  return contents
end

local function decode(s)
  local result, err = json.decode(s)
  if result == nil then
    return nil, err
  end
  return result
end

describe("snipai.claude.parser", function()
  -- ========================================================================
  -- one-shot parse()
  -- ========================================================================
  describe("parse", function()
    it("returns no events for empty input", function()
      local events, errors = parser.parse("", { json_decode = decode })
      assert.are.same({}, events)
      assert.are.same({}, errors)
    end)

    it("emits a system event for an init record", function()
      local bytes = [==[{"type":"system","subtype":"init","session_id":"s","model":"m","tools":["Edit"]}]==]
      local events = parser.parse(bytes, { json_decode = decode })
      assert.equals(1, #events)
      assert.equals("system", events[1].kind)
      assert.equals("init", events[1].subtype)
      assert.equals("s", events[1].session_id)
      assert.equals("m", events[1].model)
      assert.are.same({ "Edit" }, events[1].tools)
    end)

    it("emits assistant_text for text content blocks", function()
      local bytes = [==[{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}]==]
      local events = parser.parse(bytes, { json_decode = decode })
      assert.equals(1, #events)
      assert.equals("assistant_text", events[1].kind)
      assert.equals("hi", events[1].text)
    end)

    it("emits tool_use and preserves the full input table", function()
      local bytes = [==[
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_1","name":"Edit","input":{"file_path":"x.ts","old_string":"a","new_string":"b"}}]}}
]==]
      local events = parser.parse(bytes, { json_decode = decode })
      assert.equals(1, #events)
      assert.equals("tool_use", events[1].kind)
      assert.equals("Edit", events[1].tool)
      assert.equals("tu_1", events[1].id)
      assert.equals("x.ts", events[1].input.file_path)
      assert.equals("a", events[1].input.old_string)
      assert.equals("b", events[1].input.new_string)
    end)

    it("emits multiple events when a single assistant record has multiple blocks", function()
      local bytes = [==[
{"type":"assistant","message":{"content":[{"type":"text","text":"first"},{"type":"tool_use","id":"tu_1","name":"Bash","input":{"command":"ls"}}]}}
]==]
      local events = parser.parse(bytes, { json_decode = decode })
      assert.equals(2, #events)
      assert.equals("assistant_text", events[1].kind)
      assert.equals("tool_use", events[2].kind)
      assert.equals("ls", events[2].input.command)
    end)

    it("emits tool_result with is_error flag", function()
      local bytes = [==[
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu_1","content":"oops","is_error":true}]}}
]==]
      local events = parser.parse(bytes, { json_decode = decode })
      assert.equals(1, #events)
      assert.equals("tool_result", events[1].kind)
      assert.equals("tu_1", events[1].tool_use_id)
      assert.is_true(events[1].is_error)
      assert.equals("oops", events[1].content)
    end)

    it("flattens array-form tool_result content into a single string", function()
      local bytes = [==[
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu_1","content":[{"type":"text","text":"line1"},{"type":"text","text":"line2"}]}]}}
]==]
      local events = parser.parse(bytes, { json_decode = decode })
      assert.equals("line1\nline2", events[1].content)
    end)

    it("emits a result event with status=success when is_error is false", function()
      local bytes =
        [==[{"type":"result","subtype":"success","is_error":false,"duration_ms":100,"total_cost_usd":0.01,"usage":{"input_tokens":10}}]==]
      local events = parser.parse(bytes, { json_decode = decode })
      assert.equals(1, #events)
      assert.equals("result", events[1].kind)
      assert.equals("success", events[1].status)
      assert.equals(100, events[1].duration_ms)
      assert.equals(0.01, events[1].total_cost_usd)
    end)

    it("emits status=error when is_error is true", function()
      local bytes = [==[{"type":"result","is_error":true,"duration_ms":500}]==]
      local events = parser.parse(bytes, { json_decode = decode })
      assert.equals("error", events[1].status)
    end)

    it("returns kind=unknown for unrecognized type values", function()
      local bytes = [==[{"type":"future_thing","payload":1}]==]
      local events = parser.parse(bytes, { json_decode = decode })
      assert.equals(1, #events)
      assert.equals("unknown", events[1].kind)
      assert.equals("future_thing", events[1].type)
    end)

    it("skips blank lines and comments", function()
      local bytes = "# a comment\n\n"
        .. [==[{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]}}]==]
        .. "\n# another comment\n"
      local events = parser.parse(bytes, { json_decode = decode })
      assert.equals(1, #events)
      assert.equals("assistant_text", events[1].kind)
    end)

    it("reports invalid JSON lines as errors without halting", function()
      local bytes = "not json\n"
        .. [==[{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]}}]==]
      local events, errors = parser.parse(bytes, { json_decode = decode })
      assert.equals(1, #events)
      assert.equals("assistant_text", events[1].kind)
      assert.equals(1, #errors)
      assert.matches("not json", errors[1].line)
    end)

    -- Structural rather than exact-match: real Claude output interleaves
    -- SessionStart hook events, rate_limit_event records, and sometimes
    -- empty assistant messages. The count drifts whenever the CLI adds a
    -- new event type; the semantic shape (Write → Edit → Bash → success)
    -- is what actually matters for downstream consumers.
    it("parses the success_multi.jsonl fixture into the expected tool-use sequence", function()
      local bytes = read_fixture("success_multi.jsonl")
      local events, errors = parser.parse(bytes, { json_decode = decode })

      assert.are.same({}, errors)
      assert.is_true(#events > 0)

      local tool_uses = {}
      for _, e in ipairs(events) do
        if e.kind == "tool_use" then
          table.insert(tool_uses, e)
        end
      end

      -- Fixture's prompt: Write hello.ts → Edit 1→2 → Bash echo done.
      assert.equals(3, #tool_uses)
      assert.equals("Write", tool_uses[1].tool)
      assert.matches("hello%.ts$", tool_uses[1].input.file_path)
      assert.equals("Edit", tool_uses[2].tool)
      assert.matches("hello%.ts$", tool_uses[2].input.file_path)
      assert.equals("Bash", tool_uses[3].tool)
      assert.equals("echo done", tool_uses[3].input.command)

      -- Final event is the canonical success result with a positive
      -- duration; cost is present but specific amount depends on model.
      local last = events[#events]
      assert.equals("result", last.kind)
      assert.equals("success", last.status)
      assert.is_true(last.duration_ms > 0)
    end)
  end)

  -- ========================================================================
  -- streaming new():feed()
  -- ========================================================================
  describe("streaming", function()
    it("delivers events as whole lines accumulate across feed() calls", function()
      local p = parser.new({ json_decode = decode })

      local line = [==[{"type":"assistant","message":{"content":[{"type":"text","text":"split"}]}}]==]
        .. "\n"
      local mid = math.floor(#line / 2)

      local events1 = p:feed(line:sub(1, mid))
      assert.are.same({}, events1)

      local events2 = p:feed(line:sub(mid + 1))
      assert.equals(1, #events2)
      assert.equals("assistant_text", events2[1].kind)
      assert.equals("split", events2[1].text)
    end)

    it("handles CRLF line endings", function()
      local p = parser.new({ json_decode = decode })
      local events =
        p:feed([==[{"type":"system","subtype":"init","session_id":"s"}]==] .. "\r\n")
      assert.equals(1, #events)
      assert.equals("system", events[1].kind)
    end)

    it("flush() drains a buffer that has no trailing newline", function()
      local p = parser.new({ json_decode = decode })
      p:feed([==[{"type":"result","subtype":"success","is_error":false}]==])
      local events = p:flush()
      assert.equals(1, #events)
      assert.equals("result", events[1].kind)
    end)

    it("feed(nil) and feed('') are no-ops", function()
      local p = parser.new({ json_decode = decode })
      local e1 = p:feed(nil)
      local e2 = p:feed("")
      assert.are.same({}, e1)
      assert.are.same({}, e2)
    end)

    it("chunked feed of the fixture produces the same event list as one-shot parse", function()
      local bytes = read_fixture("success_multi.jsonl")

      -- baseline: single-shot parse
      local one_shot = parser.parse(bytes, { json_decode = decode })

      -- streamed: feed 13 bytes at a time so most lines straddle chunk
      -- boundaries, then flush any trailing bytes.
      local p = parser.new({ json_decode = decode })
      local streamed = {}
      for i = 1, #bytes, 13 do
        for _, e in ipairs(p:feed(bytes:sub(i, i + 12))) do
          streamed[#streamed + 1] = e
        end
      end
      for _, e in ipairs(p:flush()) do
        streamed[#streamed + 1] = e
      end

      assert.equals(#one_shot, #streamed)
      for i, e in ipairs(one_shot) do
        assert.equals(e.kind, streamed[i].kind)
      end
    end)
  end)
end)
