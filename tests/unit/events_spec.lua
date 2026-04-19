local events = require("snipai.events")

describe("snipai.events", function()
  local bus

  before_each(function()
    bus = events.new()
  end)

  it("delivers emitted events to subscribers", function()
    local received = {}
    bus:subscribe("hello", function(payload)
      table.insert(received, payload)
    end)
    bus:emit("hello", "world")
    assert.are.same({ "world" }, received)
  end)

  it("passes multiple arguments to the handler", function()
    local a, b, c
    bus:subscribe("multi", function(x, y, z)
      a, b, c = x, y, z
    end)
    bus:emit("multi", 1, "two", { k = 3 })
    assert.equals(1, a)
    assert.equals("two", b)
    assert.are.same({ k = 3 }, c)
  end)

  it("does not deliver to other event names", function()
    local called = false
    bus:subscribe("foo", function()
      called = true
    end)
    bus:emit("bar")
    assert.is_false(called)
  end)

  it("fans out to multiple subscribers of the same event", function()
    local total = 0
    bus:subscribe("inc", function()
      total = total + 1
    end)
    bus:subscribe("inc", function()
      total = total + 10
    end)
    bus:emit("inc")
    assert.equals(11, total)
  end)

  it("returns an unsubscribe function that stops delivery", function()
    local hits = 0
    local unsub = bus:subscribe("tap", function()
      hits = hits + 1
    end)
    bus:emit("tap")
    unsub()
    bus:emit("tap")
    assert.equals(1, hits)
  end)

  it("unsubscribe is idempotent", function()
    local unsub = bus:subscribe("e", function() end)
    unsub()
    assert.has_no.errors(function()
      unsub()
    end)
  end)

  it("once() fires exactly one time", function()
    local hits = 0
    bus:once("tap", function()
      hits = hits + 1
    end)
    bus:emit("tap")
    bus:emit("tap")
    bus:emit("tap")
    assert.equals(1, hits)
  end)

  it("isolates handler errors so later handlers still run", function()
    local ran_after = false
    bus:subscribe("fail", function()
      error("boom")
    end)
    bus:subscribe("fail", function()
      ran_after = true
    end)
    bus:emit("fail")
    assert.is_true(ran_after)
  end)

  it("reports handler errors to the on_error hook when set", function()
    local captured
    bus.on_error = function(err, event)
      captured = { err = err, event = event }
    end
    bus:subscribe("fail", function()
      error("boom")
    end)
    bus:emit("fail")
    assert.truthy(captured)
    assert.equals("fail", captured.event)
    assert.matches("boom", captured.err)
  end)

  it("emit during emit does not include handlers added this round", function()
    local order = {}
    bus:subscribe("e", function()
      table.insert(order, "first")
      bus:subscribe("e", function()
        table.insert(order, "added")
      end)
    end)
    bus:emit("e")
    assert.are.same({ "first" }, order)
    bus:emit("e")
    assert.are.same({ "first", "first", "added" }, order)
  end)

  it("clear() with no args removes every subscriber", function()
    local hit = false
    bus:subscribe("a", function()
      hit = true
    end)
    bus:subscribe("b", function()
      hit = true
    end)
    bus:clear()
    bus:emit("a")
    bus:emit("b")
    assert.is_false(hit)
    assert.is_false(bus:has_listeners("a"))
    assert.is_false(bus:has_listeners("b"))
  end)

  it("clear(event) only removes that event's handlers", function()
    local a_hit, b_hit = false, false
    bus:subscribe("a", function()
      a_hit = true
    end)
    bus:subscribe("b", function()
      b_hit = true
    end)
    bus:clear("a")
    bus:emit("a")
    bus:emit("b")
    assert.is_false(a_hit)
    assert.is_true(b_hit)
  end)

  it("has_listeners reflects current state", function()
    assert.is_false(bus:has_listeners("x"))
    local unsub = bus:subscribe("x", function() end)
    assert.is_true(bus:has_listeners("x"))
    unsub()
    assert.is_false(bus:has_listeners("x"))
  end)

  it("validates subscribe arguments", function()
    assert.has_error(function()
      bus:subscribe(nil, function() end)
    end)
    assert.has_error(function()
      bus:subscribe("", function() end)
    end)
    assert.has_error(function()
      bus:subscribe("e", nil)
    end)
    assert.has_error(function()
      bus:subscribe("e", "not a fn")
    end)
  end)
end)
