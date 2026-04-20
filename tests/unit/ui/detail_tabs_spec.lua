local detail_tabs = require("snipai.ui.detail_tabs")

describe("snipai.ui.detail_tabs.tab_bar_line", function()
  it("bracketed label indicates the active tab", function()
    local line = detail_tabs.tab_bar_line("summary")
    assert.matches("%[ Summary %]", line)
    assert.not_matches("%[ Terminal %]", line)

    line = detail_tabs.tab_bar_line("terminal")
    assert.matches("%[ Terminal %]", line)
    assert.not_matches("%[ Summary %]", line)
  end)

  it("includes a <Tab> hint so the swap is discoverable", function()
    assert.matches("<Tab>", detail_tabs.tab_bar_line("summary"))
    assert.matches("<Tab>", detail_tabs.tab_bar_line("terminal"))
  end)

  it("includes a close hint", function()
    assert.matches("q close", detail_tabs.tab_bar_line("summary"))
  end)

  it("falls back to summary for any unknown active token", function()
    local s = detail_tabs.tab_bar_line("summary")
    assert.equals(s, detail_tabs.tab_bar_line("???"))
    assert.equals(s, detail_tabs.tab_bar_line(nil))
  end)
end)
