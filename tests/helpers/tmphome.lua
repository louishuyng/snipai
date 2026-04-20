-- Per-spec $HOME override so integration tests don't pollute the real
-- ~/.claude/projects directory. Call `use(ctx)` in a before_each and
-- `restore(ctx)` in an after_each; the ctx table holds the handle to
-- undo the change.

local M = {}

local function mkdtemp()
  return vim.fn.tempname()
end

function M.use()
  local dir = mkdtemp()
  vim.fn.mkdir(dir, "p")
  local prev = vim.env.HOME
  vim.env.HOME = dir
  return { home = dir, _prev = prev }
end

function M.restore(ctx)
  vim.env.HOME = ctx._prev
  -- Best-effort cleanup; rm -rf on a path we created under tempname().
  if ctx.home and ctx.home ~= "" and ctx.home:find("/tmp") then
    vim.fn.delete(ctx.home, "rf")
  end
end

return M
