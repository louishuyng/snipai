-- Snippet registry: loads JSON configs, merges them in order, and serves
-- snippets by name or by prefix. Invalid snippets are skipped (not fatal)
-- with a warning, so one bad entry cannot starve the registry of the rest.
--
-- File I/O and JSON decoding are injectable so this module stays testable
-- under standalone busted without a Neovim bootstrap:
--
--   local r = require("snipai.registry").new({
--     reader      = function(path) return fixtures[path], nil end,
--     json_decode = function(str)  return vim.json.decode(str) end,
--     on_warning  = function(msg)  table.insert(captured, msg) end,
--   })
--
-- In production, defaults read the filesystem with io.open and decode with
-- vim.json.decode.

local snippet = require("snipai.snippet")

local M = {}

-- ---------------------------------------------------------------------------
-- Default injectables
-- ---------------------------------------------------------------------------

local function default_reader(path)
  local f, err = io.open(path, "r")
  if not f then
    return nil, err
  end
  local content = f:read("*a")
  f:close()
  return content
end

local function default_json_decode(str)
  -- Prefer Neovim's built-in. In non-nvim contexts (standalone busted),
  -- tests must inject their own; we intentionally don't pull in a JSON
  -- library as a runtime dependency.
  if vim and vim.json and vim.json.decode then
    local ok, result = pcall(vim.json.decode, str)
    if not ok then
      return nil, result
    end
    return result
  end
  return nil, "no JSON decoder available; inject opts.json_decode"
end

-- An optional-file error (missing global snippets.json, missing per-project
-- .snipai.json) shouldn't nag the user. Warn only on genuinely unexpected
-- read failures (permission denied, device errors, ...).
local function is_missing_file_error(err)
  if type(err) ~= "string" then
    return false
  end
  return err:find("No such file") ~= nil or err:find("cannot open") ~= nil
end

-- JSON arrays decode to integer-keyed Lua tables, which our type(data) check
-- alone wouldn't catch. Treat only string-keyed tables (and the empty table,
-- equivalent to `{}`) as objects.
local function is_json_object(t)
  if type(t) ~= "table" then
    return false
  end
  if next(t) == nil then
    return true
  end
  for k in pairs(t) do
    if type(k) == "string" then
      return true
    end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Registry class
-- ---------------------------------------------------------------------------

local Registry = {}
Registry.__index = Registry

function M.new(opts)
  opts = opts or {}
  return setmetatable({
    _reader = opts.reader or default_reader,
    _json_decode = opts.json_decode or default_json_decode,
    _on_warning = opts.on_warning or function() end,
    _snippets = {},
    _paths = {},
  }, Registry)
end

function Registry:load(paths)
  paths = paths or {}
  self._paths = paths
  self._snippets = {}

  for _, path in ipairs(paths) do
    self:_load_file(path)
  end

  return self
end

function Registry:_load_file(path)
  local content, read_err = self._reader(path)
  if content == nil then
    if not is_missing_file_error(read_err) then
      self:_warn(("failed to read %s: %s"):format(path, tostring(read_err)))
    end
    return
  end

  local data, decode_err = self._json_decode(content)
  if data == nil then
    self:_warn(("invalid JSON in %s: %s"):format(path, tostring(decode_err)))
    return
  end
  if not is_json_object(data) then
    self:_warn(("expected JSON object at top level of %s"):format(path))
    return
  end

  for name, raw in pairs(data) do
    self:_register(name, raw, path)
  end
end

function Registry:_register(name, raw, path)
  if type(name) ~= "string" or name == "" then
    self:_warn(("invalid snippet name in %s: %s"):format(path, tostring(name)))
    return
  end
  if type(raw) ~= "table" then
    self:_warn(("snippet %q in %s must be a JSON object"):format(name, path))
    return
  end

  local ok_create, s_or_err = pcall(snippet.new, name, raw)
  if not ok_create then
    self:_warn(("failed to create snippet %q in %s: %s"):format(name, path, s_or_err))
    return
  end

  local ok_validate, err = s_or_err:validate()
  if not ok_validate then
    self:_warn(("skipping snippet %q in %s: %s"):format(name, path, err))
    return
  end

  -- Later paths silently override earlier ones by design: per-project
  -- .snipai.json is meant to shadow global snippets of the same name.
  self._snippets[name] = s_or_err
end

function Registry:_warn(message)
  self._on_warning(message)
end

-- ---------------------------------------------------------------------------
-- Read-only accessors
-- ---------------------------------------------------------------------------

function Registry:get(name)
  return self._snippets[name]
end

function Registry:all()
  return self._snippets
end

-- Return snippets whose prefix STARTS WITH `query` (case-sensitive).
-- An empty/nil query returns every registered snippet. The order is
-- unspecified (pairs-iteration) so callers that need stability should
-- sort by name or prefix themselves.
function Registry:lookup_prefix(query)
  query = query or ""
  local result = {}
  for _, s in pairs(self._snippets) do
    if query == "" or s.prefix:sub(1, #query) == query then
      table.insert(result, s)
    end
  end
  return result
end

function Registry:reload()
  return self:load(self._paths)
end

function Registry:paths()
  local copy = {}
  for i, p in ipairs(self._paths) do
    copy[i] = p
  end
  return copy
end

return M
