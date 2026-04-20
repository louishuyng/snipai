-- Default keymap installer.
--
-- Called from setup() to bind the three global entry-point mappings:
--   <leader>sr   :SnipaiRunning
--   <leader>sh   :SnipaiHistory project
--   <leader>sH   :SnipaiHistory all
--
-- setup({ keymaps = false }) skips the whole thing. Individual keys may
-- be turned off by passing a falsy value (false / nil / "") for that
-- slot:
--   setup({ keymaps = { running = false } })
-- Buffer-local picker mappings (<CR> / <C-q> / <C-c>) live inside the
-- picker modules themselves; nothing to wire here.
--
-- keymap_set is injectable so specs can assert bindings without touching
-- real Neovim state.

local M = {}

local BINDINGS = {
  {
    key = "running",
    lhs_default = "<leader>sr",
    rhs = "<cmd>SnipaiRunning<cr>",
    desc = "snipai: running jobs",
  },
  {
    key = "history",
    lhs_default = "<leader>sh",
    rhs = "<cmd>SnipaiHistory project<cr>",
    desc = "snipai: history (project)",
  },
  {
    key = "history_all",
    lhs_default = "<leader>sH",
    rhs = "<cmd>SnipaiHistory all<cr>",
    desc = "snipai: history (all)",
  },
}

-- apply(spec, opts) -> count of bindings installed
--
-- spec:
--   false                      -> install nothing, return 0
--   nil                        -> use all defaults
--   { running = "<C-s>", ... } -> override per-key; falsy value disables that key
--
-- opts.keymap_set(mode, lhs, rhs, opts)   test seam; defaults to vim.keymap.set
function M.apply(spec, opts)
  if spec == false then
    return 0
  end
  spec = spec or {}
  opts = opts or {}
  local keymap_set = opts.keymap_set or (vim and vim.keymap and vim.keymap.set)
  assert(type(keymap_set) == "function", "keymaps.apply: no keymap setter available")

  local count = 0
  for _, b in ipairs(BINDINGS) do
    local lhs = spec[b.key]
    if lhs == nil then
      lhs = b.lhs_default
    end
    if lhs and lhs ~= "" then
      keymap_set("n", lhs, b.rhs, { desc = b.desc, silent = true })
      count = count + 1
    end
  end
  return count
end

-- Exposed for tests.
M._BINDINGS = BINDINGS

return M
