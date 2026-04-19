-- nvim-cmp completion source for snipai.
--
-- Thin adapter over snipai's registry and trigger API. cmp's :complete
-- hook asks for matches against the typed prefix; :execute hook runs
-- after the user confirms a selection. We do not insert anything into
-- the buffer — insertText is explicitly empty so cmp drops the typed
-- prefix, and execute() delegates to snipai.trigger() which runs the
-- snippet asynchronously (files are modified by the Claude job, not
-- by cmp).
--
-- register() is the public entry point users call from their cmp
-- setup. It's idempotent and no-ops when cmp is not installed so a
-- `require("snipai.sources.cmp").register()` line in a config file
-- is safe whether or not nvim-cmp is loaded.

local M = {}

-- LSP CompletionItemKind.Snippet. Numeric so this module loads without
-- needing cmp required up front — tests and lazy-loaded configs stay
-- happy.
local KIND_SNIPPET = 15
local MENU_LABEL = "[AI]"
local DETAIL_MAX = 60

local function snippet_detail(snippet)
  if type(snippet.description) == "string" and snippet.description ~= "" then
    return snippet.description
  end
  local body = snippet.body or ""
  if #body <= DETAIL_MAX then
    return body
  end
  return body:sub(1, DETAIL_MAX - 3) .. "..."
end

local function to_item(snippet)
  -- insertText is the prefix itself (not "") so the typed characters
  -- stay on screen while the user fills the param form. trigger()
  -- swaps this range for the rendered `insert` template on submit,
  -- so there is no visible flicker between "pick from cmp" and
  -- "template appears".
  return {
    label = snippet.name,
    filterText = snippet.prefix,
    insertText = snippet.prefix,
    kind = KIND_SNIPPET,
    detail = snippet_detail(snippet),
    menu = MENU_LABEL,
    data = { snippet_name = snippet.name },
  }
end

-- The query is the text cmp is matching against. Prefer params.offset
-- (1-based column where cmp started matching), fall back to the last
-- run of word characters on the line when offset isn't provided.
local function extract_query(params)
  local before = params and params.context and params.context.cursor_before_line or ""
  local offset = params and params.offset
  if type(offset) == "number" and offset >= 1 then
    return before:sub(offset)
  end
  return before:match("[%w_]+$") or ""
end

-- Resolve the current buffer's filetype for filter decisions. Split out
-- so tests can inject a deterministic value without touching vim.bo.
local function default_current_filetype()
  if vim and vim.bo and vim.bo.filetype then
    return vim.bo.filetype
  end
  return ""
end

-- ---------------------------------------------------------------------------
-- Source class
-- ---------------------------------------------------------------------------

local Source = {}
Source.__index = Source

-- new(snipai_api?, opts?)
--   opts.filetype -- function returning the buffer filetype (test seam;
--                    defaults to a vim.bo.filetype probe).
function M.new(snipai_api, opts)
  snipai_api = snipai_api or require("snipai")
  opts = opts or {}
  return setmetatable({
    _snipai = snipai_api,
    _current_filetype = opts.filetype or default_current_filetype,
  }, Source)
end

function Source:get_debug_name()
  return "snipai"
end

function Source:get_trigger_characters()
  return {}
end

function Source:is_available()
  local state = self._snipai and self._snipai._state
  if not state or not state._initialized then
    return false
  end
  return state.registry ~= nil
end

function Source:complete(params, callback)
  local state = self._snipai and self._snipai._state
  if not state or not state.registry then
    callback({ items = {}, isIncomplete = false })
    return
  end
  local query = extract_query(params)
  local ft = self._current_filetype() or ""
  local items = {}
  for _, snippet in ipairs(state.registry:lookup_prefix(query)) do
    local matches = true
    if type(snippet.matches_filetype) == "function" then
      matches = snippet:matches_filetype(ft)
    end
    if matches then
      items[#items + 1] = to_item(snippet)
    end
  end
  callback({ items = items, isIncomplete = false })
end

-- Build the ctx handed to snipai.trigger(): captures the buffer and the
-- range cmp just wrote, so trigger() can atomically swap `ailua` (the
-- typed prefix, just re-inserted by cmp) for the rendered `insert`
-- template once the param form submits.
local function build_trigger_ctx(snippet_name, registry)
  if not (vim and vim.api) then
    return {}
  end
  local buffer = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local snippet
  if registry and type(registry.get) == "function" then
    snippet = registry:get(snippet_name)
  end
  if not snippet then
    return { buffer = buffer }
  end
  local prefix_len = #snippet.prefix
  local end_col = cursor[2]
  local start_col = math.max(end_col - prefix_len, 0)
  return {
    buffer = buffer,
    replace_range = {
      start = { row = cursor[1] - 1, col = start_col },
      ["end"] = { row = cursor[1] - 1, col = end_col },
    },
  }
end

function Source:execute(completion_item, callback)
  local name = completion_item and completion_item.data and completion_item.data.snippet_name
  if name and type(self._snipai.trigger) == "function" then
    local registry = self._snipai._state and self._snipai._state.registry
    local ctx = build_trigger_ctx(name, registry)
    self._snipai.trigger(name, ctx)
  end
  if callback then
    callback(completion_item)
  end
end

-- Exposed for tests that want to verify ctx-building without a real
-- cmp/nvim buffer. See tests/unit/sources/cmp_spec.lua.
M._build_trigger_ctx = build_trigger_ctx

-- ---------------------------------------------------------------------------
-- Registration
-- ---------------------------------------------------------------------------

local _registered = false

-- register(snipai_api?, cmp_mod?)
--   Installs the source under "snipai" with the cmp runtime. Returns
--   true when cmp is available (even if registration was already done
--   earlier), false when cmp isn't installed. cmp_mod is an injection
--   seam for tests; in production the module is resolved via
--   pcall(require, "cmp").
function M.register(snipai_api, cmp_mod)
  local cmp = cmp_mod
  if cmp == nil then
    local ok, loaded = pcall(require, "cmp")
    if not ok then
      return false
    end
    cmp = loaded
  end
  if _registered then
    return true
  end
  cmp.register_source("snipai", M.new(snipai_api))
  _registered = true
  return true
end

-- Test helper: reset the registered flag between specs.
function M._reset()
  _registered = false
end

-- Exposed for tests.
M._to_item = to_item
M._extract_query = extract_query
M._snippet_detail = snippet_detail

return M
