local param_form = require("snipai.ui.param_form")
local snippet_mod = require("snipai.snippet")

local function make_snippet(raw)
  local s = snippet_mod.new(raw.name or "test", raw)
  local ok, err = s:validate()
  assert(ok, err)
  return s
end

-- Returns a stub popup module plus a closure that reads back whatever
-- fields `collect` was called with. `behavior` scripts one call:
--   { values = {...} }  -> submit with these values
--   { cancel = true }   -> invoke on_cancel
local function stub_popup(behavior)
  local captured
  local popup = {
    collect = function(fields, opts)
      captured = fields
      if behavior.cancel then
        opts.on_cancel()
        return
      end
      opts.on_submit(behavior.values or {})
    end,
  }
  return popup, function()
    return captured
  end
end

describe("snipai.ui.param_form.open", function()
  it("short-circuits to on_submit when the snippet has no parameters", function()
    local s = make_snippet({ prefix = "np", body = "hello" })
    local submitted
    param_form.open(s, {
      popup = {
        collect = function()
          error("popup should not be called")
        end,
      },
      on_submit = function(v)
        submitted = v
      end,
    })
    assert.are.same({}, submitted)
  end)

  it("orders fields by placeholder appearance in body", function()
    local s = make_snippet({
      prefix = "o",
      body = "do {{second}} then {{first}}",
      parameter = {
        first = { type = "string" },
        second = { type = "string" },
      },
    })
    local popup, get_fields = stub_popup({ values = { first = "F", second = "S" } })
    local submitted
    param_form.open(s, {
      popup = popup,
      on_submit = function(v)
        submitted = v
      end,
    })
    local fields = get_fields()
    assert.equals(2, #fields)
    assert.equals("second", fields[1].name)
    assert.equals("first", fields[2].name)
    assert.are.same({ first = "F", second = "S" }, submitted)
  end)

  it("appends declared-but-unreferenced params alphabetically after body-order", function()
    local s = make_snippet({
      prefix = "ex",
      body = "use {{z}}",
      parameter = {
        z = { type = "string" },
        a = { type = "string", default = "A" },
        b = { type = "string", default = "B" },
      },
    })
    local popup, get_fields = stub_popup({ values = { z = "Z", a = "A", b = "B" } })
    param_form.open(s, {
      popup = popup,
      on_submit = function() end,
    })
    local names = {}
    for _, f in ipairs(get_fields()) do
      names[#names + 1] = f.name
    end
    assert.are.same({ "z", "a", "b" }, names)
  end)

  it("resolves defaults for fields the user left empty", function()
    local s = make_snippet({
      prefix = "d",
      body = "{{g}}",
      parameter = { g = { type = "string", default = "fallback" } },
    })
    local popup = stub_popup({ values = { g = "" } })
    local submitted
    param_form.open(s, {
      popup = popup,
      on_submit = function(v)
        submitted = v
      end,
    })
    assert.are.same({ g = "fallback" }, submitted)
  end)

  it("validation failure routes to notify + on_cancel; never on_submit", function()
    local s = make_snippet({
      prefix = "req",
      body = "{{g}}",
      parameter = { g = { type = "string" } }, -- required, no default
    })
    local popup = stub_popup({ values = { g = "" } })
    local recorded
    local notifier = {
      notify = function(_, msg, level)
        recorded = { msg = msg, level = level }
      end,
    }
    local cancelled = false
    param_form.open(s, {
      popup = popup,
      notify = notifier,
      on_submit = function()
        error("should not submit on validation failure")
      end,
      on_cancel = function()
        cancelled = true
      end,
    })
    assert.is_true(cancelled)
    assert.truthy(recorded)
    assert.truthy(recorded.msg:find("g:", 1, true))
    assert.equals("error", recorded.level)
  end)

  it("user cancel propagates to on_cancel", function()
    local s = make_snippet({
      prefix = "c",
      body = "{{g}}",
      parameter = { g = { type = "string" } },
    })
    local popup = stub_popup({ cancel = true })
    local cancelled = false
    param_form.open(s, {
      popup = popup,
      on_submit = function()
        error("should not submit on user cancel")
      end,
      on_cancel = function()
        cancelled = true
      end,
    })
    assert.is_true(cancelled)
  end)

  it("forwards type, default, and options to popup fields", function()
    local s = make_snippet({
      prefix = "se",
      body = "{{flag}} {{style}}",
      parameter = {
        flag = { type = "boolean", default = false },
        style = { type = "select", options = { "a", "b" }, default = "a" },
      },
    })
    local popup, get_fields = stub_popup({ values = { flag = true, style = "b" } })
    param_form.open(s, {
      popup = popup,
      on_submit = function() end,
    })
    local fields = get_fields()
    local by_name = {}
    for _, f in ipairs(fields) do
      by_name[f.name] = f
    end
    assert.equals("boolean", by_name.flag.type)
    assert.equals(false, by_name.flag.default)
    assert.equals("select", by_name.style.type)
    assert.equals("a", by_name.style.default)
    assert.are.same({ "a", "b" }, by_name.style.options)
  end)
end)
