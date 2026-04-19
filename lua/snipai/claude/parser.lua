-- Claude Code stream-json parser.
--
-- Converts NDJSON output from `claude -p ... --output-format stream-json
-- --verbose` into a sequence of normalized events that the rest of the
-- plugin can consume without knowing Claude's wire format.
--
-- Normalized event shape:
--   { kind = "system",         subtype, session_id, model, tools }
--   { kind = "assistant_text", text }
--   { kind = "tool_use",       id, tool, input }
--   { kind = "tool_result",    tool_use_id, is_error, content }
--   { kind = "result",         status, duration_ms, total_cost_usd,
--                              usage, result }
--   { kind = "unknown",        type, raw }      -- forward-compat fallthrough
--
-- Tool-specific extraction (file paths for Edit/Write/MultiEdit, commands
-- for Bash, etc.) is left to consumers — the parser emits the full `input`
-- table, so adding a new derived field like files_changed is a one-line
-- change in jobs/job.lua, not a parser rewrite.
--
-- Two APIs:
--   parser.parse(bytes, opts)    -- one-shot on a complete buffer
--   parser.new(opts):feed(chunk) -- streaming; buffers partial lines
--
-- Both accept opts.json_decode for DI. Default uses vim.json.decode.

local M = {}

-- ---------------------------------------------------------------------------
-- Default JSON decode
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- Content-block handlers
--
-- Dispatched by block.type. Anything not in this table is silently dropped
-- (forward-compat for future block kinds we haven't taught the plugin about).
-- ---------------------------------------------------------------------------

local BLOCK_HANDLERS = {}

function BLOCK_HANDLERS.text(block)
  return { kind = "assistant_text", text = block.text or "" }
end

function BLOCK_HANDLERS.tool_use(block)
  return {
    kind = "tool_use",
    id = block.id,
    tool = block.name,
    input = block.input or {},
  }
end

-- tool_result content can be either a string or an array of {type="text"}
-- blocks; normalize both into a single content string so consumers have
-- one shape to handle.
local function flatten_tool_result_content(content)
  if type(content) == "string" then
    return content
  end
  if type(content) ~= "table" then
    return nil
  end
  local parts = {}
  for _, c in ipairs(content) do
    if type(c) == "table" and c.type == "text" then
      parts[#parts + 1] = c.text or ""
    end
  end
  return table.concat(parts, "\n")
end

function BLOCK_HANDLERS.tool_result(block)
  return {
    kind = "tool_result",
    tool_use_id = block.tool_use_id,
    is_error = block.is_error == true,
    content = flatten_tool_result_content(block.content),
  }
end

local function expand_blocks(blocks)
  local events = {}
  if type(blocks) ~= "table" then
    return events
  end
  for _, block in ipairs(blocks) do
    if type(block) == "table" then
      local handler = BLOCK_HANDLERS[block.type]
      if handler then
        events[#events + 1] = handler(block)
      end
    end
  end
  return events
end

-- ---------------------------------------------------------------------------
-- Record handlers
--
-- Dispatched by record.type. Each handler receives the full decoded record
-- and returns an array of normalized events (0..N).
-- ---------------------------------------------------------------------------

local RECORD_HANDLERS = {}

function RECORD_HANDLERS.system(record)
  return {
    {
      kind = "system",
      subtype = record.subtype,
      session_id = record.session_id,
      model = record.model,
      tools = record.tools,
    },
  }
end

function RECORD_HANDLERS.assistant(record)
  local content = record.message and record.message.content
  if type(content) == "string" then
    return { { kind = "assistant_text", text = content } }
  end
  return expand_blocks(content)
end

function RECORD_HANDLERS.user(record)
  local content = record.message and record.message.content
  return expand_blocks(content)
end

function RECORD_HANDLERS.result(record)
  local status
  if record.is_error then
    status = "error"
  else
    status = record.subtype or "success"
  end
  return {
    {
      kind = "result",
      status = status,
      duration_ms = record.duration_ms,
      total_cost_usd = record.total_cost_usd,
      usage = record.usage,
      result = record.result,
    },
  }
end

local function events_from(record)
  if type(record) ~= "table" or type(record.type) ~= "string" then
    return { { kind = "unknown", raw = record } }
  end
  local handler = RECORD_HANDLERS[record.type]
  if handler then
    return handler(record)
  end
  return { { kind = "unknown", type = record.type, raw = record } }
end

-- ---------------------------------------------------------------------------
-- Line processing
-- ---------------------------------------------------------------------------

local function process_line(line, json_decode, events, errors)
  local trimmed = line:match("^%s*(.-)%s*$")
  if trimmed == "" then
    return
  end
  if trimmed:sub(1, 1) == "#" then
    -- fixture comment (see CONTRIBUTING.md)
    return
  end
  local record, err = json_decode(trimmed)
  if record == nil then
    errors[#errors + 1] = { line = line, error = err }
    return
  end
  for _, evt in ipairs(events_from(record)) do
    events[#events + 1] = evt
  end
end

-- ---------------------------------------------------------------------------
-- One-shot API
-- ---------------------------------------------------------------------------

function M.parse(bytes, opts)
  opts = opts or {}
  local json_decode = opts.json_decode or default_json_decode
  local events, errors = {}, {}
  for line in (bytes or ""):gmatch("[^\r\n]*") do
    process_line(line, json_decode, events, errors)
  end
  return events, errors
end

-- ---------------------------------------------------------------------------
-- Streaming API
-- ---------------------------------------------------------------------------

local Parser = {}
Parser.__index = Parser

function M.new(opts)
  opts = opts or {}
  return setmetatable({
    _json_decode = opts.json_decode or default_json_decode,
    _buffer = "",
  }, Parser)
end

function Parser:feed(chunk)
  if chunk == nil or chunk == "" then
    return {}, {}
  end
  self._buffer = self._buffer .. chunk
  local events, errors = {}, {}
  while true do
    local nl = self._buffer:find("\n", 1, true)
    if not nl then
      break
    end
    local line = self._buffer:sub(1, nl - 1)
    if line:sub(-1) == "\r" then
      line = line:sub(1, -2)
    end
    self._buffer = self._buffer:sub(nl + 1)
    process_line(line, self._json_decode, events, errors)
  end
  return events, errors
end

function Parser:flush()
  if self._buffer == "" then
    return {}, {}
  end
  local remaining = self._buffer
  self._buffer = ""
  local events, errors = {}, {}
  process_line(remaining, self._json_decode, events, errors)
  return events, errors
end

-- Exposed for tests that want to extend handlers (e.g. future tool types).
M._RECORD_HANDLERS = RECORD_HANDLERS
M._BLOCK_HANDLERS = BLOCK_HANDLERS

return M
