-- Session-JSONL shapes the top-level parser must accept beyond the
-- stream-json records already covered by parser_spec.lua.

local parser = require("snipai.claude.parser")
local json = require("tests.helpers.json")

local function decode(s)
  local result, err = json.decode(s)
  if result == nil then
    return nil, err
  end
  return result
end

describe("snipai.claude.parser session-JSONL shape", function()
  it("emits tool_use from a top-level record", function()
    local bytes = [==[{"type":"tool_use","id":"tu_42","name":"Edit","input":{"file_path":"src/x.ts"}}]==]
    local events = parser.parse(bytes, { json_decode = decode })
    assert.equals(1, #events)
    assert.equals("tool_use", events[1].kind)
    assert.equals("Edit", events[1].tool)
    assert.equals("tu_42", events[1].id)
    assert.equals("src/x.ts", events[1].input.file_path)
  end)

  it("accepts the 'tool' alias for top-level tool_use records", function()
    local bytes = [==[{"type":"tool_use","id":"tu_1","tool":"Write","input":{"file_path":"a.txt"}}]==]
    local events = parser.parse(bytes, { json_decode = decode })
    assert.equals("Write", events[1].tool)
  end)

  it("emits tool_result from a top-level record", function()
    local bytes = [==[{"type":"tool_result","tool_use_id":"tu_42","content":"done","is_error":false}]==]
    local events = parser.parse(bytes, { json_decode = decode })
    assert.equals(1, #events)
    assert.equals("tool_result", events[1].kind)
    assert.equals("tu_42", events[1].tool_use_id)
    assert.equals("done", events[1].content)
    assert.is_false(events[1].is_error)
  end)

  it("accepts assistant records with content at record.content", function()
    local bytes = [==[{"type":"assistant","content":"quick reply"}]==]
    local events = parser.parse(bytes, { json_decode = decode })
    assert.equals(1, #events)
    assert.equals("assistant_text", events[1].kind)
    assert.equals("quick reply", events[1].text)
  end)

  it("accepts assistant blocks at record.content (array form)", function()
    local bytes = [==[
{"type":"assistant","content":[{"type":"text","text":"hi"},{"type":"tool_use","id":"tu","name":"Edit","input":{"file_path":"a"}}]}
]==]
    local events = parser.parse(bytes, { json_decode = decode })
    assert.equals(2, #events)
    assert.equals("assistant_text", events[1].kind)
    assert.equals("tool_use", events[2].kind)
    assert.equals("a", events[2].input.file_path)
  end)

  it("still emits tool_use nested in assistant.message.content", function()
    local bytes = [==[
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t","name":"Write","input":{"file_path":"b.ts"}}]}}
]==]
    local events = parser.parse(bytes, { json_decode = decode })
    assert.equals(1, #events)
    assert.equals("Write", events[1].tool)
    assert.equals("b.ts", events[1].input.file_path)
  end)
end)
