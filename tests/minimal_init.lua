-- Headless bootstrap for `make test*` runs.
-- Keep this tiny: loaders + plenary only. Real test isolation (tmpdirs, fake
-- runners) lives in tests/helpers/ and is pulled in per-spec.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local deps = root .. "/.deps"

vim.opt.rtp:prepend(deps .. "/plenary.nvim")
vim.opt.rtp:prepend(root)

vim.cmd("runtime plugin/plenary.vim")

require("plenary.busted")
