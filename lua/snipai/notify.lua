-- Notification facade with pluggable backends.
--
-- Resolution (ui.notify):
--   "auto"         try nvim-notify, then fidget.nvim, then vim.notify
--   "nvim-notify"  require("notify")  (errors if missing)
--   "fidget"       require("fidget")  (errors if missing)
--   "vim.notify"   always available inside Neovim
--   function       caller-supplied emitter fn(msg, level, opts)
--
-- Every backend exposes one Notifier API:
--   notifier:notify(msg, level?, opts?)
--   notifier:progress(title, initial?) -> Progress
--
-- Progress handle (phase-2 scope: re-emits on each update; phase 5 will
-- upgrade nvim-notify / fidget to replace-in-place streaming):
--   progress:update(msg, level?)
--   progress:finish(msg, level?)
--
-- `require`, `vim.notify`, and `vim.log.levels` are injectable for tests
-- so this module runs under standalone busted without Neovim.

local M = {}

-- ---------------------------------------------------------------------------
-- Injectable environment
-- ---------------------------------------------------------------------------

local function default_require(name)
  return require(name)
end

local function default_vim_notify(msg, level, opts)
  vim.notify(msg, level, opts)
end

local DEFAULT_LEVELS = { TRACE = 0, DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4, OFF = 5 }

local function resolve_env(opts)
  return {
    require = opts.require or default_require,
    vim_notify = opts.vim_notify or default_vim_notify,
    levels = opts.levels or (vim and vim.log and vim.log.levels) or DEFAULT_LEVELS,
  }
end

local function resolve_level(level, levels)
  if type(level) == "number" then
    return level
  end
  if type(level) == "string" then
    local up = level:upper()
    return levels[up] or levels.INFO
  end
  return levels.INFO
end

-- ---------------------------------------------------------------------------
-- Progress handle (shared across all phase-2 backends)
-- ---------------------------------------------------------------------------

local Progress = {}
Progress.__index = Progress

local function format_with_title(title, msg)
  if title == nil or title == "" then
    return msg
  end
  return title .. ": " .. msg
end

function Progress:update(msg, level)
  self._notifier:notify(format_with_title(self._title, msg), level)
end

function Progress:finish(msg, level)
  self._notifier:notify(format_with_title(self._title, msg), level or "info")
end

-- ---------------------------------------------------------------------------
-- Notifier
-- ---------------------------------------------------------------------------

local Notifier = {}
Notifier.__index = Notifier

function Notifier:notify(msg, level, opts)
  self._emit(msg, resolve_level(level, self._levels), opts)
end

function Notifier:progress(title, initial)
  local p = setmetatable({ _notifier = self, _title = title }, Progress)
  if initial ~= nil then
    p:update(initial, "info")
  end
  return p
end

function Notifier:name()
  return self._name
end

-- ---------------------------------------------------------------------------
-- Backend probes
-- ---------------------------------------------------------------------------

local function probe_nvim_notify(env)
  local ok, nn = pcall(env.require, "notify")
  if not ok then
    return nil
  end
  -- nvim-notify exports a callable module; some versions also expose
  -- a `notify` function on that module. Accept either shape.
  local call
  if type(nn) == "function" then
    call = nn
  elseif type(nn) == "table" and type(nn.notify) == "function" then
    call = nn.notify
  else
    return nil
  end
  return {
    name = "nvim-notify",
    emit = function(msg, level, opts)
      call(msg, level, opts)
    end,
  }
end

local function probe_fidget(env)
  local ok, fi = pcall(env.require, "fidget")
  if not ok then
    return nil
  end
  if type(fi) ~= "table" or type(fi.notify) ~= "function" then
    return nil
  end
  return {
    name = "fidget",
    emit = function(msg, level, opts)
      fi.notify(msg, level, opts)
    end,
  }
end

local function probe_vim_notify(env)
  return {
    name = "vim.notify",
    emit = function(msg, level, opts)
      env.vim_notify(msg, level, opts)
    end,
  }
end

local AUTO_ORDER = { probe_nvim_notify, probe_fidget, probe_vim_notify }

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

local function wrap_function_backend(fn)
  return {
    name = "custom",
    emit = function(msg, level, opts)
      fn(msg, level, opts)
    end,
  }
end

function M.new(opts)
  opts = opts or {}
  local env = resolve_env(opts)

  local spec = opts.backend
  if spec == nil then
    spec = "auto"
  end

  local backend
  if type(spec) == "function" then
    backend = wrap_function_backend(spec)
  elseif type(spec) == "table" then
    assert(type(spec.emit) == "function", "custom backend table needs an emit function")
    backend = {
      name = spec.name or "custom",
      emit = spec.emit,
    }
  elseif spec == "auto" then
    for _, probe in ipairs(AUTO_ORDER) do
      local b = probe(env)
      if b then
        backend = b
        break
      end
    end
    -- AUTO_ORDER ends in probe_vim_notify, which never returns nil, so
    -- `backend` is guaranteed set here. Kept explicit for clarity.
    assert(backend, "notify: no backend resolved in auto mode")
  elseif spec == "nvim-notify" then
    backend = probe_nvim_notify(env)
    if not backend then
      error("snipai.notify: nvim-notify requested but not installed")
    end
  elseif spec == "fidget" then
    backend = probe_fidget(env)
    if not backend then
      error("snipai.notify: fidget requested but not installed")
    end
  elseif spec == "vim.notify" then
    backend = probe_vim_notify(env)
  else
    error(("snipai.notify: unknown backend %q"):format(tostring(spec)))
  end

  return setmetatable({
    _name = backend.name,
    _emit = backend.emit,
    _levels = env.levels,
  }, Notifier)
end

-- Exposed for tests that want to poke at resolution without building a
-- Notifier (e.g. verifying auto-detection fallthrough).
M._resolve_level = resolve_level
M._AUTO_ORDER_NAMES = { "nvim-notify", "fidget", "vim.notify" }

return M
