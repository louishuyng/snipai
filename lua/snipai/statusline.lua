-- Statusline integration.
--
-- Exposes a single `status(bufnr?)` function returning a short indicator
-- string suitable for dropping straight into lualine / heirline / native
-- statusline. Non-empty when one of the currently-running snipai jobs
-- has already emitted an Edit / Write / MultiEdit for the buffer's file;
-- empty otherwise — so statuslines can cheaply call it on every redraw
-- without guarding against before-setup / invalid-buf / scratch cases.
--
-- The module reads state through the public snipai top-level API only
-- (snipai.jobs.list() + Job:files_changed()), so it has no privileged
-- access to internals and stays cheap to swap out or replace with a
-- user-defined variant.

local M = {}

-- Glyph + label. Kept here (not configurable yet) so users can wrap the
-- return value in their own statusline config if they want different
-- styling.
local INDICATOR = "⟳ snipai"

local function current_buf()
  if vim and vim.api and vim.api.nvim_get_current_buf then
    return vim.api.nvim_get_current_buf()
  end
end

local function buffer_is_valid(buf)
  if vim and vim.api and vim.api.nvim_buf_is_valid then
    return vim.api.nvim_buf_is_valid(buf)
  end
  return true
end

local function buffer_filename(buf)
  if vim and vim.api and vim.api.nvim_buf_get_name then
    return vim.api.nvim_buf_get_name(buf)
  end
  return ""
end

local function iter_active_jobs()
  local ok, snipai = pcall(require, "snipai")
  if not ok then
    return {}
  end
  local state = snipai._state
  if state == nil or not state._initialized or state.jobs == nil then
    return {}
  end
  local list_ok, list = pcall(function()
    return snipai.jobs.list()
  end)
  if not list_ok or type(list) ~= "table" then
    return {}
  end
  return list
end

function M.status(bufnr)
  local buf = bufnr or current_buf()
  if type(buf) ~= "number" or not buffer_is_valid(buf) then
    return ""
  end
  local file = buffer_filename(buf)
  if file == nil or file == "" then
    return ""
  end
  for _, job in ipairs(iter_active_jobs()) do
    if type(job.files_changed) == "function" then
      for _, touched in ipairs(job:files_changed()) do
        if touched == file then
          return INDICATOR
        end
      end
    end
  end
  return ""
end

return M
