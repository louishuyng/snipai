-- snipai plugin file: registers user commands at Neovim startup.
--
-- Command catalog:
--   :SnipaiTrigger <name>           — run a snippet by name
--   :SnipaiRunning                  — Telescope picker of active jobs
--   :SnipaiHistory [project|all]    — Telescope picker of history
--   :SnipaiDetail <id>              — open detail popup for a history entry
--   :SnipaiToQuickfix <id>          — push the entry's files_changed to qf
--   :SnipaiCancel <id>              — cancel a running job (SIGTERM)
--   :SnipaiReload                   — re-read JSON snippet configs
--
-- Every command is a thin dispatcher: it pulls the active plugin state
-- from require("snipai")._state and delegates to the picker / UI / core
-- module that does the work. Commands invoked before setup() has run
-- emit a single warning instead of crashing.
--
-- Global keymaps (<leader>sr / <leader>sh / <leader>sH) are installed
-- inside snipai.setup() via snipai.keymaps, not here — they need the
-- merged config to decide which bindings are enabled.

if vim.g.loaded_snipai == 1 then
  return
end
vim.g.loaded_snipai = 1

local function get_state()
  local ok, snipai = pcall(require, "snipai")
  if not ok then
    return nil, nil
  end
  local st = snipai._state
  if not st or not st._initialized then
    return nil, snipai
  end
  return st, snipai
end

local function warn_not_setup()
  local levels = vim.log and vim.log.levels or { WARN = 3 }
  vim.notify("snipai: setup() has not been called", levels.WARN)
end

local function info(msg)
  local levels = vim.log and vim.log.levels or { INFO = 2 }
  vim.notify("snipai: " .. msg, levels.INFO)
end

local function warn(msg)
  local levels = vim.log and vim.log.levels or { WARN = 3 }
  vim.notify("snipai: " .. msg, levels.WARN)
end

-- ---------------------------------------------------------------------------
-- :SnipaiTrigger <name>
-- ---------------------------------------------------------------------------

local function trigger_completion()
  local st = get_state()
  if not st or not st.registry then
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
  local st, snipai = get_state()
  if not st then
    warn_not_setup()
    return
  end
  snipai.trigger(args.args)
end, {
  nargs = 1,
  complete = trigger_completion,
  desc = "Run a snipai snippet by name",
})

-- ---------------------------------------------------------------------------
-- Shared: history id completion (used by :SnipaiDetail, :SnipaiToQuickfix)
-- ---------------------------------------------------------------------------

local function history_id_completion(arg_lead)
  local st = get_state()
  if not st or not st.history then
    return {}
  end
  local entries = st.history:list({ scope = "all" }) or {}
  local ids = {}
  for _, e in ipairs(entries) do
    if e.id and (arg_lead == "" or e.id:sub(1, #arg_lead) == arg_lead) then
      ids[#ids + 1] = e.id
    end
  end
  return ids
end

-- ---------------------------------------------------------------------------
-- :SnipaiRunning
-- ---------------------------------------------------------------------------

vim.api.nvim_create_user_command("SnipaiRunning", function()
  local st = get_state()
  if not st then
    warn_not_setup()
    return
  end
  require("snipai.pickers.running").open({
    jobs = st.jobs,
    history = st.history,
    notify = st.notify,
  })
end, { desc = "snipai: Telescope picker of active jobs" })

-- ---------------------------------------------------------------------------
-- :SnipaiHistory [project|all]
-- ---------------------------------------------------------------------------

vim.api.nvim_create_user_command("SnipaiHistory", function(args)
  local st = get_state()
  if not st then
    warn_not_setup()
    return
  end
  local scope = args.args ~= "" and args.args or "project"
  require("snipai.pickers.history").open({
    history = st.history,
    scope = scope,
    notify = st.notify,
  })
end, {
  nargs = "?",
  complete = function()
    return { "project", "all" }
  end,
  desc = "snipai: Telescope picker of history (project|all)",
})

-- ---------------------------------------------------------------------------
-- :SnipaiDetail <id>
-- ---------------------------------------------------------------------------

vim.api.nvim_create_user_command("SnipaiDetail", function(args)
  local st = get_state()
  if not st then
    warn_not_setup()
    return
  end
  local id = args.args
  if id == "" then
    warn("usage: :SnipaiDetail <id>")
    return
  end
  local entry = st.history:get(id)
  if not entry then
    warn("history entry not found: " .. id)
    return
  end
  require("snipai.ui.detail").open(entry)
end, {
  nargs = 1,
  complete = function(arg_lead)
    return history_id_completion(arg_lead or "")
  end,
  desc = "snipai: open detail popup for a history entry",
})

-- ---------------------------------------------------------------------------
-- :SnipaiToQuickfix <id>
-- ---------------------------------------------------------------------------

vim.api.nvim_create_user_command("SnipaiToQuickfix", function(args)
  local st = get_state()
  if not st then
    warn_not_setup()
    return
  end
  local id = args.args
  if id == "" then
    warn("usage: :SnipaiToQuickfix <id>")
    return
  end
  local items, err = st.history:to_quickfix(id)
  if not items then
    warn(err or "to_quickfix failed")
    return
  end
  info(("quickfix: %d file%s"):format(#items, #items == 1 and "" or "s"))
end, {
  nargs = 1,
  complete = function(arg_lead)
    return history_id_completion(arg_lead or "")
  end,
  desc = "snipai: push a history entry's files_changed into quickfix",
})

-- ---------------------------------------------------------------------------
-- :SnipaiCancel <id>
-- ---------------------------------------------------------------------------

local function cancel_id_completion(arg_lead)
  local st = get_state()
  if not st or not st.jobs then
    return {}
  end
  local ids = {}
  for _, job in ipairs(st.jobs:list()) do
    local id = job:id()
    if arg_lead == "" or id:sub(1, #arg_lead) == arg_lead then
      ids[#ids + 1] = id
    end
  end
  return ids
end

vim.api.nvim_create_user_command("SnipaiCancel", function(args)
  local st = get_state()
  if not st then
    warn_not_setup()
    return
  end
  local id = args.args
  if id == "" then
    warn("usage: :SnipaiCancel <id>")
    return
  end
  local ok, err = st.jobs:cancel(id)
  if not ok then
    warn(err or "cancel failed")
    return
  end
  info("cancelled " .. id)
end, {
  nargs = 1,
  complete = function(arg_lead)
    return cancel_id_completion(arg_lead or "")
  end,
  desc = "snipai: cancel a running job by id",
})

-- ---------------------------------------------------------------------------
-- :SnipaiReload
-- ---------------------------------------------------------------------------

vim.api.nvim_create_user_command("SnipaiReload", function()
  local st, snipai = get_state()
  if not st then
    warn_not_setup()
    return
  end
  snipai.reload()
  info("snippet configs reloaded")
end, { desc = "snipai: re-read snippet JSON configs" })
