local keymaps = require("snipai.keymaps")

local function capture()
  local calls = {}
  return function(mode, lhs, rhs, opts)
    calls[#calls + 1] = { mode = mode, lhs = lhs, rhs = rhs, opts = opts }
  end,
    calls
end

describe("snipai.keymaps", function()
  it("installs all three default bindings when spec is nil", function()
    local set, calls = capture()
    local count = keymaps.apply(nil, { keymap_set = set })
    assert.equals(3, count)
    assert.equals(3, #calls)

    local by_lhs = {}
    for _, c in ipairs(calls) do
      by_lhs[c.lhs] = c
    end
    assert.truthy(by_lhs["<leader>sr"])
    assert.equals("<cmd>SnipaiRunning<cr>", by_lhs["<leader>sr"].rhs)
    assert.equals("n", by_lhs["<leader>sr"].mode)

    assert.truthy(by_lhs["<leader>sh"])
    assert.equals("<cmd>SnipaiHistory project<cr>", by_lhs["<leader>sh"].rhs)

    assert.truthy(by_lhs["<leader>sH"])
    assert.equals("<cmd>SnipaiHistory all<cr>", by_lhs["<leader>sH"].rhs)
  end)

  it("installs nothing when spec == false", function()
    local set, calls = capture()
    assert.equals(0, keymaps.apply(false, { keymap_set = set }))
    assert.equals(0, #calls)
  end)

  it("overrides an individual key via spec[key]", function()
    local set, calls = capture()
    keymaps.apply({ running = "<leader>R" }, { keymap_set = set })
    local found
    for _, c in ipairs(calls) do
      if c.rhs == "<cmd>SnipaiRunning<cr>" then
        found = c
        break
      end
    end
    assert.truthy(found)
    assert.equals("<leader>R", found.lhs)
  end)

  it("disables an individual key when spec[key] is false or empty", function()
    local set, calls = capture()
    keymaps.apply({ running = false, history = "" }, { keymap_set = set })
    for _, c in ipairs(calls) do
      assert.is_true(c.rhs ~= "<cmd>SnipaiRunning<cr>")
      assert.is_true(c.rhs ~= "<cmd>SnipaiHistory project<cr>")
    end
    -- history_all still on
    assert.equals(1, #calls)
    assert.equals("<leader>sH", calls[1].lhs)
  end)

  it("passes desc and silent to the setter", function()
    local set, calls = capture()
    keymaps.apply(nil, { keymap_set = set })
    for _, c in ipairs(calls) do
      assert.truthy(c.opts.desc)
      assert.matches("^snipai", c.opts.desc)
      assert.is_true(c.opts.silent)
    end
  end)

  it("errors when no keymap_set is available", function()
    assert.has_error(function()
      keymaps.apply(nil, { keymap_set = "not a fn" })
    end)
  end)
end)
