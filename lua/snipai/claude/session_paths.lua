-- Claude Code on-disk session transcript paths.
--
-- Every interactive `claude` session writes an NDJSON transcript to
--   ~/.claude/projects/<slug>/<session-id>.jsonl
-- where <slug> is the absolute cwd with every '/' replaced by '-'.
-- "/Users/x/repo" → "-Users-x-repo", so the leading slash becomes a
-- leading dash. This module is the single source of truth for that
-- mapping; everything else in the plugin consumes it through
-- project_dir() / session_file().
--
-- Pure (no Neovim dependencies beyond an optional `vim.fn.expand("~")`
-- fallback) so it runs in unit tests without any runtime state.

local M = {}

local function slug_of(cwd)
  assert(type(cwd) == "string" and cwd ~= "", "cwd must be a non-empty string")
  assert(cwd:sub(1, 1) == "/", "cwd must be absolute (start with '/')")
  return (cwd:gsub("/", "-"))
end

local function resolve_home(home)
  if type(home) == "string" and home ~= "" then
    return home
  end
  if os.getenv and os.getenv("HOME") then
    return os.getenv("HOME")
  end
  if vim and vim.fn and vim.fn.expand then
    return vim.fn.expand("~")
  end
  error("cannot resolve home directory: pass opts.home explicitly")
end

function M.project_dir(opts)
  assert(type(opts) == "table", "project_dir requires an opts table")
  return resolve_home(opts.home) .. "/.claude/projects/" .. slug_of(opts.cwd)
end

function M.session_file(opts)
  assert(type(opts) == "table", "session_file requires an opts table")
  assert(
    type(opts.session_id) == "string" and opts.session_id ~= "",
    "session_id must be a non-empty string"
  )
  return M.project_dir(opts) .. "/" .. opts.session_id .. ".jsonl"
end

M._slug_of = slug_of

return M
