-- snipai plugin file: registers user commands at Neovim startup.
--
-- The only command here is :SnipaiTrigger <name>, which dispatches to
-- require("snipai").trigger(). Completion walks the snippet registry
-- loaded by setup(); if setup() has not run yet, completion returns
-- an empty list rather than erroring.
--
-- Default keymaps and the other :Snipai* commands (history, running
-- jobs pickers, to_quickfix, cancel, reload) land in a later step
-- along with the Telescope pickers they drive.

if vim.g.loaded_snipai == 1 then
  return
end
vim.g.loaded_snipai = 1

local function trigger_completion()
  local ok, snipai = pcall(require, "snipai")
  if not ok then
    return {}
  end
  local st = snipai._state
  if not st or not st._initialized or not st.registry then
    return {}
  end
  local names = {}
  for name in pairs(st.registry:all()) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

vim.api.nvim_create_user_command("SnipaiTrigger", function(args)
  require("snipai").trigger(args.args)
end, {
  nargs = 1,
  complete = trigger_completion,
  desc = "Run a snipai snippet by name",
})
