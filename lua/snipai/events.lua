-- Tiny synchronous pub/sub bus.
--
-- Used as the seam between async work (jobs, claude runner) and the rest of
-- the plugin (pickers, notifications, UI). Each bus instance is independent,
-- so jobs can own a bus and tests can create throwaway buses.
--
-- Not thread-safe; Neovim is single-threaded Lua.

local M = {}

local Bus = {}
Bus.__index = Bus

function M.new()
  return setmetatable({
    _handlers = {},
    _next_id = 1,
    -- Optional hook: function(err, event, handler). If set, receives errors
    -- from individual handlers so callers can surface them without aborting
    -- the emit loop.
    on_error = nil,
  }, Bus)
end

function Bus:subscribe(event, handler)
  assert(type(event) == "string" and event ~= "", "event name must be a non-empty string")
  assert(type(handler) == "function", "handler must be a function")

  local bucket = self._handlers[event]
  if not bucket then
    bucket = {}
    self._handlers[event] = bucket
  end

  local id = self._next_id
  self._next_id = id + 1
  bucket[id] = handler

  return function()
    self:_unsubscribe(event, id)
  end
end

function Bus:once(event, handler)
  local unsub
  unsub = self:subscribe(event, function(...)
    unsub()
    return handler(...)
  end)
  return unsub
end

function Bus:_unsubscribe(event, id)
  local bucket = self._handlers[event]
  if not bucket then
    return
  end
  bucket[id] = nil
  if next(bucket) == nil then
    self._handlers[event] = nil
  end
end

function Bus:emit(event, ...)
  local bucket = self._handlers[event]
  if not bucket then
    return
  end

  -- Snapshot so unsubscribe-during-emit cannot skip later handlers in this
  -- round; newly-subscribed handlers correctly do not fire this round.
  local snapshot = {}
  for _, h in pairs(bucket) do
    snapshot[#snapshot + 1] = h
  end

  for _, handler in ipairs(snapshot) do
    local ok, err = pcall(handler, ...)
    if not ok and self.on_error then
      pcall(self.on_error, err, event, handler)
    end
  end
end

function Bus:has_listeners(event)
  return self._handlers[event] ~= nil
end

function Bus:clear(event)
  if event == nil then
    self._handlers = {}
  else
    self._handlers[event] = nil
  end
end

return M
