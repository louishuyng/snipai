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
  return {
    label = snippet.name,
    filterText = snippet.prefix,
    insertText = "",
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

-- ---------------------------------------------------------------------------
-- Source class
-- ---------------------------------------------------------------------------

local Source = {}
Source.__index = Source

function M.new(snipai_api)
  snipai_api = snipai_api or require("snipai")
  return setmetatable({
    _snipai = snipai_api,
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
  local items = {}
  for _, snippet in ipairs(state.registry:lookup_prefix(query)) do
    items[#items + 1] = to_item(snippet)
  end
  callback({ items = items, isIncomplete = false })
end

function Source:execute(completion_item, callback)
  local name = completion_item and completion_item.data and completion_item.data.snippet_name
  if name and type(self._snipai.trigger) == "function" then
    self._snipai.trigger(name)
  end
  if callback then
    callback(completion_item)
  end
end

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
