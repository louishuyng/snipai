-- Follows a Claude Code session transcript on disk and forwards each
-- parsed event to on_event. Tracks a byte offset so repeated polls
-- only see new data; flushes any partial trailing line on stop().

local parser_mod = require("snipai.claude.parser")

local M = {}

local DEFAULT_POLL_MS = 250

local function default_fs()
  return {
    read_from = function(_, path, offset)
      local fd = vim.uv.fs_open(path, "r", 438)
      if not fd then
        return "", offset
      end
      local stat = vim.uv.fs_fstat(fd)
      if not stat or stat.size <= offset then
        vim.uv.fs_close(fd)
        return "", offset
      end
      local chunk = vim.uv.fs_read(fd, stat.size - offset, offset) or ""
      vim.uv.fs_close(fd)
      return chunk, stat.size
    end,
    exists = function(_, path)
      return vim.uv.fs_stat(path) ~= nil
    end,
  }
end

local function default_poll_start(path, on_change)
  local handle = vim.uv.new_fs_poll()
  handle:start(path, DEFAULT_POLL_MS, function()
    vim.schedule(on_change)
  end)
  return function()
    if handle and not handle:is_closing() then
      handle:stop()
      handle:close()
    end
  end
end

local Tailer = {}
Tailer.__index = Tailer

function M.new(opts)
  opts = opts or {}
  assert(type(opts.on_event) == "function", "tailer requires opts.on_event")
  return setmetatable({
    _fs = opts.fs or default_fs(),
    _parser_new = opts.parser_new or parser_mod.new,
    _poll_start = opts.poll_start or default_poll_start,
    _on_event = opts.on_event,
    _on_error = opts.on_error or function() end,
    _parser = nil,
    _offset = 0,
    _path = nil,
    _stop_poll = nil,
  }, Tailer)
end

function Tailer:start(path)
  assert(type(path) == "string" and path ~= "", "path must be a non-empty string")
  self._path = path
  self._offset = 0
  self._parser = self._parser_new()
  self._stop_poll = self._poll_start(path, function()
    self:tick()
  end)
  if self._fs:exists(path) then
    self:tick()
  end
end

function Tailer:tick()
  if not self._path or not self._parser then
    return
  end
  if not self._fs:exists(self._path) then
    return
  end
  local chunk, new_offset = self._fs:read_from(self._path, self._offset)
  if chunk == "" then
    return
  end
  self._offset = new_offset
  local events, errors = self._parser:feed(chunk)
  for _, evt in ipairs(events) do
    self._on_event(evt)
  end
  for _, err in ipairs(errors) do
    self._on_error(err)
  end
end

function Tailer:stop()
  if self._stop_poll then
    self._stop_poll()
    self._stop_poll = nil
  end
  -- Drain any bytes that were written after the last poll fired; then
  -- flush the parser so a trailing partial line becomes a final event.
  self:tick()
  if self._parser then
    local events, errors = self._parser:flush()
    for _, evt in ipairs(events) do
      self._on_event(evt)
    end
    for _, err in ipairs(errors) do
      self._on_error(err)
    end
  end
  self._parser = nil
  self._path = nil
end

return M
