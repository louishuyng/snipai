-- History: the public API on top of history/store.
--
-- Two write points per entry — add_pending() on job start, finalize() on
-- job end. This split is load-bearing:
--   * pickers that show running jobs read the pending row
--   * cancellation routes through finalize just like normal completion
--   * crash recovery can see rows still in "running" state
--
-- Entry shape (the caller of add_pending only has to provide the snippet-
-- level fields; history.init stamps the rest):
--   id           string   assigned here (see opts.id injection below)
--   cwd          string   captured here from opts.cwd
--   started_at   number   ms since epoch, stamped here
--   status       string   "running" on add_pending, "success"|"error"
--                         |"cancelled" on finalize
--   -- provided by the caller on add_pending:
--   snippet      string   snippet name
--   prefix       string   the prefix that triggered it (if any)
--   params       table    resolved param values
--   prompt       string   the rendered prompt body
--   -- provided by the caller on finalize:
--   finished_at  number   ms since epoch (defaulted here to now())
--   duration_ms  number   defaults to finished_at - started_at
--   files_changed table   file paths extracted from tool_use events
--   stdout       string   optional tail for debugging
--   stderr       string   optional
--   exit_code    number   from the claude CLI
--   usage        table    token/cost summary from the result event
--
-- Listing is workspace-scoped: list{scope="project"} filters by cwd,
-- list{scope="all"} returns everything in the file.

local store = require("snipai.history.store")

local M = {}

-- ---------------------------------------------------------------------------
-- Defaults (injectable for tests)
-- ---------------------------------------------------------------------------

local function default_now()
  -- Millisecond-precision wall-clock is plenty for a human-facing log.
  -- duration_ms stays honest whether caller supplies a precise value or
  -- we derive it from finished_at - started_at.
  return os.time() * 1000
end

local function default_id()
  -- Sufficient to be unique within one history file; not an RFC-4122 UUID.
  -- Format: <hex-ms>-<hex-rand24>
  local t = default_now()
  local r = math.random(0, 0xffffff)
  return string.format("%x-%06x", t, r)
end

local function default_cwd()
  if vim and vim.uv and vim.uv.cwd then
    return vim.uv.cwd()
  end
  if vim and vim.loop and vim.loop.cwd then
    return vim.loop.cwd()
  end
  return "."
end

local function default_setqflist(items, action, what)
  return vim.fn.setqflist(items, action, what)
end

local TERMINAL_STATUSES = { success = true, error = true, cancelled = true }

-- ---------------------------------------------------------------------------
-- History class
-- ---------------------------------------------------------------------------

local History = {}
History.__index = History

function M.new(opts)
  opts = opts or {}
  assert(type(opts.path) == "string" and opts.path ~= "", "history requires opts.path")

  local s = opts.store
    or store.new({
      path = opts.path,
      max_entries = opts.max_entries or 500,
      fs = opts.fs,
      json_encode = opts.json_encode,
      json_decode = opts.json_decode,
      on_warning = opts.on_warning,
    })

  return setmetatable({
    _store = s,
    _id = opts.id or default_id,
    _now = opts.now or default_now,
    _cwd = opts.cwd or default_cwd(),
    _per_project = opts.per_project ~= false, -- default true
    _setqflist = opts.setqflist or default_setqflist,
  }, History)
end

-- ---------------------------------------------------------------------------
-- Writes
-- ---------------------------------------------------------------------------

local function shallow_copy(t)
  local out = {}
  if type(t) == "table" then
    for k, v in pairs(t) do
      out[k] = v
    end
  end
  return out
end

function History:add_pending(entry)
  if entry ~= nil and type(entry) ~= "table" then
    return nil, "entry must be a table"
  end

  local pending = shallow_copy(entry)
  pending.id = pending.id or self._id()
  pending.cwd = pending.cwd or self._cwd
  pending.started_at = pending.started_at or self._now()
  pending.status = "running"
  pending.files_changed = pending.files_changed or {}

  local ok, err = self._store:append(pending)
  if not ok then
    return nil, err
  end
  return pending
end

-- Patches the existing pending row in place — never inserts a new one.
-- A missing id returns (nil, "entry not found"), not a fresh insert, so
-- add_pending stays the sole write point.
--
-- Trade-off: read_all + write_all rewrites the whole file on every
-- finalize (O(N) in entry count). At max_entries=500 the file sits
-- around 150-300 KB, which is unmeasurable on modern disks and keeps
-- the store a plain tail-readable JSONL log. If this ever shows up in
-- a profile, the alternative is an append-only "finalization record"
-- that overlays the pending row at read time.
function History:finalize(id, patch)
  if type(id) ~= "string" or id == "" then
    return nil, "finalize requires a non-empty id"
  end
  if patch == nil then
    return nil, "finalize requires a patch with a terminal status"
  end
  if type(patch) ~= "table" then
    return nil, "finalize patch must be a table"
  end

  local entries = self._store:read_all()
  local idx, target
  for i, e in ipairs(entries) do
    if e.id == id then
      idx, target = i, e
      break
    end
  end
  if not target then
    return nil, ("entry not found: %s"):format(id)
  end

  -- Merge patch fields on top of the existing entry, then backfill
  -- finished_at / duration_ms if the caller did not provide them.
  for k, v in pairs(patch) do
    target[k] = v
  end
  target.finished_at = target.finished_at or self._now()
  if target.started_at and target.finished_at and target.duration_ms == nil then
    target.duration_ms = target.finished_at - target.started_at
  end

  if not TERMINAL_STATUSES[target.status] then
    return nil,
      ("finalize patch must set status to one of success|error|cancelled (got %s)"):format(
        tostring(target.status)
      )
  end

  entries[idx] = target
  local ok, err = self._store:write_all(entries)
  if not ok then
    return nil, err
  end
  return target
end

-- ---------------------------------------------------------------------------
-- Reads
-- ---------------------------------------------------------------------------

function History:list(opts)
  opts = opts or {}
  local scope = opts.scope
  if scope == nil then
    scope = self._per_project and "project" or "all"
  end

  local entries = self._store:read_all()
  if scope == "all" then
    return entries
  end
  if scope ~= "project" then
    return nil, ("unknown scope: %s"):format(tostring(scope))
  end

  local cwd = opts.cwd or self._cwd
  local filtered = {}
  for _, e in ipairs(entries) do
    if e.cwd == cwd then
      filtered[#filtered + 1] = e
    end
  end
  return filtered
end

function History:get(id)
  if type(id) ~= "string" then
    return nil
  end
  for _, e in ipairs(self._store:read_all()) do
    if e.id == id then
      return e
    end
  end
  return nil
end

function History:clear()
  return self._store:clear()
end

function History:path()
  return self._store:path()
end

function History:cwd()
  return self._cwd
end

-- Push an entry's files_changed into the quickfix list. Each touched file
-- becomes one qf item pointing at line 1 (Claude's Edit events don't
-- carry line numbers; row 1 is the least-surprising landing point). The
-- qf title names the snippet so multiple runs can coexist visually.
--
-- Returns the items list that was pushed, or nil + error if the entry is
-- missing or had no file writes. opts.action overrides the setqflist
-- action character (defaults to " ", meaning create a fresh list).
function History:to_quickfix(id, opts)
  opts = opts or {}
  if type(id) ~= "string" or id == "" then
    return nil, "to_quickfix requires a non-empty id"
  end
  local entry = self:get(id)
  if not entry then
    return nil, ("entry not found: %s"):format(id)
  end
  local files = entry.files_changed or {}
  if #files == 0 then
    return nil, ("no file changes recorded for entry %s"):format(id)
  end

  local items = {}
  for _, path in ipairs(files) do
    items[#items + 1] = {
      filename = path,
      lnum = 1,
      col = 1,
      text = entry.snippet or "snipai",
    }
  end
  local title = ("snipai: %s"):format(entry.snippet or id)
  self._setqflist({}, opts.action or " ", { title = title, items = items })
  return items
end

return M
