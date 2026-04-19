-- Persistent JSONL store for history entries.
--
-- Append-only log on disk. Each line is one history entry serialized as
-- JSON. Pruning keeps the file bounded by rewriting the tail when append
-- pushes it past `max_entries`.
--
-- Filesystem and codec are injectable so this module is testable under
-- standalone busted without any Neovim or real disk.
--
-- The store is schema-agnostic — it persists any Lua table the caller
-- hands it. Entry shape is enforced one layer up in history/init.lua.

local M = {}

-- ---------------------------------------------------------------------------
-- Default codecs / filesystem
-- ---------------------------------------------------------------------------

local function default_json_encode(t)
  if vim and vim.json and vim.json.encode then
    local ok, result = pcall(vim.json.encode, t)
    if not ok then
      return nil, result
    end
    return result
  end
  return nil, "no JSON encoder available; inject opts.json_encode"
end

local function default_json_decode(s)
  if vim and vim.json and vim.json.decode then
    local ok, result = pcall(vim.json.decode, s)
    if not ok then
      return nil, result
    end
    return result
  end
  return nil, "no JSON decoder available; inject opts.json_decode"
end

local function default_read_all(path)
  local f, err = io.open(path, "r")
  if not f then
    return nil, err
  end
  local content = f:read("*a")
  f:close()
  return content
end

local function default_append(path, text)
  local f, err = io.open(path, "a")
  if not f then
    return nil, err
  end
  f:write(text)
  f:close()
  return true
end

local function default_write_all(path, text)
  local f, err = io.open(path, "w")
  if not f then
    return nil, err
  end
  f:write(text)
  f:close()
  return true
end

local function default_remove(path)
  -- Missing-file removal is a no-op, not an error.
  os.remove(path)
  return true
end

local function default_mkdir_p(dirpath)
  if vim and vim.fn and vim.fn.mkdir then
    pcall(vim.fn.mkdir, dirpath, "p")
    return true
  end
  os.execute(("mkdir -p %q"):format(dirpath))
  return true
end

local function dirname(path)
  return path:match("^(.*)/[^/]+$")
end

-- ---------------------------------------------------------------------------
-- Store
-- ---------------------------------------------------------------------------

local Store = {}
Store.__index = Store

function M.new(opts)
  opts = opts or {}
  assert(type(opts.path) == "string" and opts.path ~= "", "store requires opts.path")
  local fs = opts.fs or {}
  return setmetatable({
    _path = opts.path,
    _max_entries = opts.max_entries or 500,
    _json_encode = opts.json_encode or default_json_encode,
    _json_decode = opts.json_decode or default_json_decode,
    _on_warning = opts.on_warning or function() end,
    _fs = {
      read_all = fs.read_all or default_read_all,
      append = fs.append or default_append,
      write_all = fs.write_all or default_write_all,
      remove = fs.remove or default_remove,
      mkdir_p = fs.mkdir_p or default_mkdir_p,
    },
  }, Store)
end

function Store:path()
  return self._path
end

function Store:_ensure_parent_dir()
  local d = dirname(self._path)
  if d and d ~= "" and d ~= "." then
    self._fs.mkdir_p(d)
  end
end

function Store:append(entry)
  if type(entry) ~= "table" then
    return nil, "entry must be a table"
  end
  local encoded, enc_err = self._json_encode(entry)
  if encoded == nil then
    return nil, enc_err
  end

  self:_ensure_parent_dir()
  local ok, write_err = self._fs.append(self._path, encoded .. "\n")
  if not ok then
    return nil, write_err
  end

  -- Opportunistic prune; cheap enough at 500-entry scale.
  self:prune(self._max_entries)
  return true
end

function Store:read_all()
  local content, _ = self._fs.read_all(self._path)
  if content == nil then
    -- Missing file = empty history; not an error condition.
    return {}
  end
  local entries = {}
  for line in content:gmatch("[^\n]+") do
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed ~= "" then
      local entry, decode_err = self._json_decode(trimmed)
      if entry == nil then
        self._on_warning(("invalid history entry: %s"):format(tostring(decode_err)))
      else
        entries[#entries + 1] = entry
      end
    end
  end
  return entries
end

function Store:count()
  local content = self._fs.read_all(self._path)
  if content == nil then
    return 0
  end
  local n = 0
  for _ in content:gmatch("[^\n]+") do
    n = n + 1
  end
  return n
end

-- Rewrite the file with exactly `entries` (one JSON object per line).
-- Pairs with read_all for any "load → mutate → save" workflow. Empty
-- `entries` truncates the file to zero bytes (use clear() to unlink).
function Store:write_all(entries)
  if type(entries) ~= "table" then
    return nil, "entries must be a table"
  end
  local lines = {}
  for i, e in ipairs(entries) do
    local encoded, err = self._json_encode(e)
    if encoded == nil then
      return nil, ("entry %d: %s"):format(i, tostring(err))
    end
    lines[#lines + 1] = encoded
  end
  self:_ensure_parent_dir()
  if #lines == 0 then
    return self._fs.write_all(self._path, "")
  end
  return self._fs.write_all(self._path, table.concat(lines, "\n") .. "\n")
end

-- Keep at most `max` most-recent entries by rewriting the file.
-- Returns (true) on success or (nil, err) on an encode/write failure.
function Store:prune(max)
  local entries = self:read_all()
  if #entries <= max then
    return true
  end
  local keep_from = #entries - max + 1
  local kept = {}
  for i = keep_from, #entries do
    kept[#kept + 1] = entries[i]
  end
  return self:write_all(kept)
end

function Store:clear()
  return self._fs.remove(self._path)
end

return M
