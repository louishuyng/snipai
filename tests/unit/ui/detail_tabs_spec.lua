local detail_tabs = require("snipai.ui.detail_tabs")

describe("snipai.ui.detail_tabs.tab_bar_line", function()
  it("highlights the summary tab by default", function()
    assert.equals("[ Summary ]   Terminal ", detail_tabs.tab_bar_line("summary"))
  end)

  it("highlights the terminal tab when active", function()
    assert.equals("  Summary  [ Terminal ]", detail_tabs.tab_bar_line("terminal"))
  end)

  it("falls back to summary for any unknown active token", function()
    assert.equals("[ Summary ]   Terminal ", detail_tabs.tab_bar_line("???"))
    assert.equals("[ Summary ]   Terminal ", detail_tabs.tab_bar_line(nil))
  end)
end)
