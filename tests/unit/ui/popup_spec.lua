local popup = require("snipai.ui.popup")

-- Build a stub vim.ui.input that replays a queued sequence of responses.
-- Each call pops the next response and records the call args.
local function stub_input(responses)
  local idx = 0
  local seen = {}
  local fn = function(o, cb)
    idx = idx + 1
    seen[#seen + 1] = o
    cb(responses[idx])
  end
  return fn, seen
end

local function stub_select(responses)
  local idx = 0
  local seen = {}
  local fn = function(items, o, cb)
    idx = idx + 1
    seen[#seen + 1] = { items = items, prompt = o and o.prompt }
    cb(responses[idx])
  end
  return fn, seen
end

-- Sentinel that fails the test if a disallowed UI fn is hit.
local forbidden = function()
  error("UI path should not have been taken", 2)
end

describe("snipai.ui.popup.collect", function()
  it("submits immediately on empty fields", function()
    local got
    popup.collect({}, {
      ui_input = forbidden,
      ui_select = forbidden,
      on_submit = function(values)
        got = values
      end,
    })
    assert.are.same({}, got)
  end)

  it("collects a single string field", function()
    local input, _ = stub_input({ "add tests" })
    local got
    popup.collect({
      { name = "goal", type = "string" },
    }, {
      ui_input = input,
      ui_select = forbidden,
      on_submit = function(values)
        got = values
      end,
    })
    assert.are.same({ goal = "add tests" }, got)
  end)

  it("runs fields sequentially in declared order", function()
    local input, seen = stub_input({ "v1", "v2" })
    local got
    popup.collect({
      { name = "a", type = "string" },
      { name = "b", type = "string" },
    }, {
      ui_input = input,
      ui_select = forbidden,
      on_submit = function(v)
        got = v
      end,
    })
    assert.are.same({ a = "v1", b = "v2" }, got)
    assert.equals("a: ", seen[1].prompt)
    assert.equals("b: ", seen[2].prompt)
  end)

  it("passes select options straight through and returns the chosen string", function()
    local sel, seen = stub_select({ "detailed" })
    local got
    popup.collect({
      { name = "style", type = "select", options = { "concise", "detailed" } },
    }, {
      ui_input = forbidden,
      ui_select = sel,
      on_submit = function(v)
        got = v
      end,
    })
    assert.are.same({ style = "detailed" }, got)
    assert.are.same({ "concise", "detailed" }, seen[1].items)
  end)

  it("maps boolean select responses back to true/false", function()
    for _, c in ipairs({ { "true", true }, { "false", false } }) do
      local sel, _ = stub_select({ c[1] })
      local got
      popup.collect({
        { name = "enable", type = "boolean" },
      }, {
        ui_input = forbidden,
        ui_select = sel,
        on_submit = function(v)
          got = v
        end,
      })
      assert.are.same({ enable = c[2] }, got)
    end
  end)

  it("treats 'text' the same way as 'string' at the popup layer", function()
    local input, _ = stub_input({ "line1" })
    local got
    popup.collect({
      { name = "body", type = "text" },
    }, {
      ui_input = input,
      ui_select = forbidden,
      on_submit = function(v)
        got = v
      end,
    })
    assert.are.same({ body = "line1" }, got)
  end)

  it("nil response invokes on_cancel and halts further prompts", function()
    local calls = 0
    local fn = function(_, cb)
      calls = calls + 1
      cb(nil)
    end
    local cancelled = false
    popup.collect({
      { name = "a", type = "string" },
      { name = "b", type = "string" },
    }, {
      ui_input = fn,
      ui_select = forbidden,
      on_submit = function()
        error("should not submit")
      end,
      on_cancel = function()
        cancelled = true
      end,
    })
    assert.equals(1, calls)
    assert.is_true(cancelled)
  end)

  it("nil from a select cancel also halts", function()
    local sel, _ = stub_select({}) -- no responses → cb(nil)
    local cancelled = false
    popup.collect({
      { name = "x", type = "select", options = { "a" } },
    }, {
      ui_input = forbidden,
      ui_select = sel,
      on_submit = function()
        error("should not submit")
      end,
      on_cancel = function()
        cancelled = true
      end,
    })
    assert.is_true(cancelled)
  end)

  it("exposes default to vim.ui.input and hints it in the prompt", function()
    local captured
    local fn = function(o, cb)
      captured = o
      cb("hi")
    end
    popup.collect({
      { name = "g", type = "string", default = "hi" },
    }, {
      ui_input = fn,
      ui_select = forbidden,
      on_submit = function() end,
    })
    assert.equals("hi", captured.default)
    assert.truthy(captured.prompt:find("default: hi", 1, true))
  end)

  it("empty string is a valid confirm — not a cancel", function()
    local input, _ = stub_input({ "" })
    local got, cancelled
    popup.collect({
      { name = "g", type = "string" },
    }, {
      ui_input = input,
      ui_select = forbidden,
      on_submit = function(v)
        got = v
      end,
      on_cancel = function()
        cancelled = true
      end,
    })
    assert.are.same({ g = "" }, got)
    assert.is_nil(cancelled)
  end)
end)
