-- Configuration: defaults + deep merge with user opts.
--
-- Path resolution is pure XDG — snipai owns its own ~/.config/snipai and
-- ~/.local/share/snipai trees rather than nesting under the Neovim
-- config dir. The module has no Neovim dependency, which also lets it
-- be driven from standalone busted or a future non-nvim frontend.
--
-- Resolution order:
--   1. caller-injected env.config_dir / env.data_dir (tests)
--   2. $XDG_CONFIG_HOME / $XDG_DATA_HOME from the environment
--   3. $HOME/.config and $HOME/.local/share (last-resort fallback)
--
-- Merge rules (summary — README and vimdoc are the canonical reference):
--   * config_paths      : REPLACED when the user provides it
--   * history / claude / ui : deep-merged with defaults
--   * keymaps           : deep-merged, or user may pass `false` to disable
--                         all default bindings
--   * nested arrays     : replaced, not appended (user picks the full list)

local M = {}

-- ---------------------------------------------------------------------------
-- XDG path resolution (layered, non-mutating)
-- ---------------------------------------------------------------------------

local function home()
  return os.getenv("HOME") or "/"
end

local function resolve_config_dir(env)
  env = env or {}
  if env.config_dir then
    return env.config_dir
  end
  return os.getenv("XDG_CONFIG_HOME") or (home() .. "/.config")
end

local function resolve_data_dir(env)
  env = env or {}
  if env.data_dir then
    return env.data_dir
  end
  return os.getenv("XDG_DATA_HOME") or (home() .. "/.local/share")
end

-- ---------------------------------------------------------------------------
-- Defaults
-- ---------------------------------------------------------------------------

function M.default_config_paths(env)
  return {
    resolve_config_dir(env) .. "/snipai/snippets.json",
    ".snipai.json",
  }
end

function M.defaults(env)
  return {
    config_paths = M.default_config_paths(env),
    history = {
      path = resolve_data_dir(env) .. "/snipai/history.jsonl",
      max_entries = 500,
      per_project = true,
    },
    claude = {
      cmd = "claude",
      extra_args = {},
      timeout_ms = 5 * 60 * 1000,
    },
    ui = {
      notify = "auto",
      picker = "telescope",
    },
    keymaps = {
      running = "<leader>sr",
      history = "<leader>sh",
      history_all = "<leader>sH",
      detail = "<CR>",
      to_qf = "<C-q>",
      cancel = "<C-c>",
    },
  }
end

-- ---------------------------------------------------------------------------
-- Deep merge
-- ---------------------------------------------------------------------------

local function is_array(t)
  if type(t) ~= "table" then
    return false
  end
  if next(t) == nil then
    return false
  end
  local count = 0
  for _ in pairs(t) do
    count = count + 1
  end
  for i = 1, count do
    if t[i] == nil then
      return false
    end
  end
  return true
end

-- deep_merge mutates `target` in place with entries from `override`:
--   * both plain tables (non-array) -> recursive merge
--   * override is an array          -> replaces target wholesale
--   * otherwise                     -> override's value wins
local function deep_merge(target, override)
  for k, v in pairs(override) do
    local t = target[k]
    if type(v) == "table" and type(t) == "table" and not is_array(v) and not is_array(t) then
      target[k] = deep_merge(t, v)
    else
      target[k] = v
    end
  end
  return target
end

function M.merge(user_opts, env)
  local defaults = M.defaults(env)
  if user_opts == nil then
    return defaults
  end
  if type(user_opts) ~= "table" then
    error(("setup expected a table, got %s"):format(type(user_opts)))
  end
  return deep_merge(defaults, user_opts)
end

return M
