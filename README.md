# snipai

> AI-powered snippets for Neovim, backed by Claude Code.

`snipai` turns your snippet library into an AI agent. Type a prefix, pick from `nvim-cmp`, fill the parameters, and Claude Code does the rest — edit files, run tests, anything the CLI can do — while you keep editing. Every run is logged per-project; any past run's file changes drop into the quickfix list with one keystroke.






https://github.com/user-attachments/assets/3870ebd4-c056-4ab8-a38e-c8a3d1d7220c





![status](https://img.shields.io/badge/status-alpha-orange) ![neovim](https://img.shields.io/badge/Neovim-0.10%2B-57A143?logo=neovim) ![license](https://img.shields.io/badge/license-MIT-blue)

---

## Table of contents

1. [Features](#features)
2. [Requirements](#requirements)
3. [Installation](#installation)
4. [Quickstart](#quickstart)
5. [Snippet JSON schema](#snippet-json-schema)
6. [Commands](#commands)
7. [Default keybindings](#default-keybindings)
8. [Configuration](#configuration)
9. [Statusline integration](#statusline-integration)
10. [Events](#events)
11. [Troubleshooting](#troubleshooting)
12. [FAQ](#faq)
13. [Roadmap](#roadmap)
14. [Contributing](#contributing)
15. [License](#license)

---

## Features

- **Snippet-as-prompt.** JSON snippets with a `body` template + typed parameters; the body becomes the Claude prompt.
- **Typed parameters.** `string`, `text`, `select`, `boolean` — validated before the run.
- **Global + per-project libraries.** Project `.snipai.json` overrides global snippets by name.
- **Filetype scoping.** Optional `filetype` field keeps language-specific snippets out of other buffers.
- **Concurrent runs** with per-job notifications and spinner.
- **Persistent history.** JSONL log per project, survives restarts.
- **Structured progress.** File changes and tool uses are parsed from Claude's `stream-json` output — no stdout scraping. A live tool-use counter inside the notification is scheduled for v0.2.0; today the run emits a single completion toast.
- **Quickfix integration** for any past run's file changes.
- **Completion via nvim-cmp**; blink.cmp adapter on the roadmap.
- **Telescope pickers** for active jobs and history.
- **Notification auto-detect** (`nvim-notify` / `fidget.nvim` / `vim.notify`).
- **Zero-config.** `require("snipai").setup()` and go.

---

## Requirements

| Requirement | Version | Why |
|---|---|---|
| Neovim | **0.10+** | `vim.system`, `vim.uv`, `vim.islist` |
| Claude Code CLI | latest | the plugin shells out to `claude -p` |
| `hrsh7th/nvim-cmp` | recent | completion source |
| `nvim-telescope/telescope.nvim` | recent | pickers for running jobs + history |
| `rcarriga/nvim-notify` *or* `j-hui/fidget.nvim` | optional | richer progress toasts; falls back to `vim.notify` |
| `stevearc/dressing.nvim` / `folke/snacks.nvim` / `nvim-telescope/telescope-ui-select.nvim` | optional | popup-style prompts on top of `vim.ui.input` / `select` |

Verify the CLI: `claude --version`.

---

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "louishuyng/snipai",
  dependencies = {
    "hrsh7th/nvim-cmp",
    "rcarriga/nvim-notify", -- optional
  },
  event = "InsertEnter",
  config = function()
    require("snipai").setup()
    require("snipai.sources.cmp").register()
  end,
}
```

### [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use({
  "louishuyng/snipai",
  requires = {
    "hrsh7th/nvim-cmp",
    { "rcarriga/nvim-notify", opt = true },
  },
  config = function()
    require("snipai").setup()
    require("snipai.sources.cmp").register()
  end,
})
```

### [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug 'hrsh7th/nvim-cmp'
Plug 'rcarriga/nvim-notify'
Plug 'louishuyng/snipai'

lua << EOF
require('snipai').setup()
require('snipai.sources.cmp').register()
EOF
```

Then add the source to your cmp config:

```lua
require("cmp").setup({
  sources = require("cmp").config.sources({
    { name = "snipai" },
    { name = "nvim_lsp" },
    { name = "buffer" },
  }),
})
```

`register()` is a no-op when cmp isn't installed, so leaving the call in place on a cmp-less machine is harmless.

---

## Quickstart

**1. Install the plugin** (see above).

**2. Create your first snippet** at `~/.config/snipai/snippets.json`:

```json
{
  "typescript_file": {
    "description": "Generate a TypeScript file and run its tests",
    "prefix": "aits",
    "body": "Generate a typescript file named {{file_name}} that does the following: {{content}}. Then run `npm test` and fix any failures.",
    "parameter": {
      "file_name": {
        "type": "string",
        "description": "The name of the file to be created"
      },
      "content": {
        "type": "text",
        "description": "What the file should do"
      }
    }
  }
}
```

**3. Confirm the cmp source is wired** — the install recipes already call `require("snipai.sources.cmp").register()` and add `{ name = "snipai" }` to cmp's sources.

**4. Trigger it.** Type `aits` in any buffer, pick it from cmp (look for the `[AI]` tag), answer the parameter prompts, and Claude runs in the background while you keep editing.

**5. Check history.** `<leader>sh` opens the project's history picker. `<C-q>` on any entry sends its file changes to the quickfix list.

---

## Snippet JSON schema

```jsonc
{
  "<snippet_name>": {
    "description": "Shown in cmp as the item's detail",
    "prefix":      "what the user types to summon it",
    "body":        "Prompt template with {{placeholders}} for parameters",
    "insert":      "Optional — text dropped at the cursor before the run",
    "filetype":    "lua",                       // optional; see below
    "parameter": {
      "<name>": {
        "type":        "string" | "text" | "select" | "boolean",
        "description": "Shown as the field label in the popup",
        "options":     ["ts", "js", "lua"],     // required for type=select
        "default":     "ts",                     // optional, typed to match
        "optional":    false                     // default false; if false, empty value is rejected
      }
    }
  }
}
```

**`insert` templates.** With `insert` set, the rendered template drops at the cursor (replacing the typed prefix), the buffer auto-saves, and Claude enriches the file in place. When the run finishes, touched buffers reload via `:checktime`. Snippets without `insert` skip the buffer entirely — Claude just runs with the rendered `body` as its prompt. Unnamed scratch buffers are refused up front (no file on disk to enrich).

**Built-in parameters.** Reference these in `{{placeholders}}`; do **not** declare them in `parameter` (validation rejects the snippet if you do).

| Name | Value |
|---|---|
| `cursor_file` | absolute path of the buffer, empty on unnamed scratch |
| `cursor_line` / `cursor_col` | 1-based position at trigger time |
| `cwd` | `vim.fn.getcwd()` |

**`filetype` scoping.**

| Shape | Meaning |
|---|---|
| *(omitted)* | available in every buffer |
| `"lua"` | only when `vim.bo.filetype == "lua"` |
| `["lua", "luau"]` | any-of |

Non-matching snippets are dropped from cmp — Markdown-scoped prompts don't pollute TypeScript buffers.

**Parameter type reference:**

| `type` | Widget | Validation |
|---|---|---|
| `string` | single-line input | non-empty if required; newlines stripped |
| `text` | multi-line textarea | non-empty if required |
| `select` | cycling enum picker | value must be in `options` |
| `boolean` | toggle | always valid |

**Loading order:** snippets are read from *every* path in `config_paths` and merged left-to-right — later paths override earlier ones by snippet name. By default:

1. `~/.config/snipai/snippets.json` (global; respects `$XDG_CONFIG_HOME`)
2. `<cwd>/.snipai.json` (per-project, overrides global)

Invalid snippets are **skipped** (not aborted), with one notification pointing at the offender.

---

## Commands

| Command | Description |
|---|---|
| `:SnipaiRunning` | Telescope picker of currently running snippet jobs |
| `:SnipaiHistory` | History picker scoped to current project (alias for `project`) |
| `:SnipaiHistory project` | Same as above |
| `:SnipaiHistory all` | History picker across every project |
| `:SnipaiDetail <id>` | Open a detail popup for a history entry |
| `:SnipaiToQuickfix <id>` | Push a history entry's `files_changed` into the quickfix list |
| `:SnipaiCancel <id>` | Cancel a running job (SIGTERM the Claude subprocess) |
| `:SnipaiReload` | Re-read all JSON snippet configs |
| `:SnipaiTrigger <name>` | Run a snippet by name without going through `nvim-cmp` (useful for keymaps) |

---

## Default keybindings

**Global** (set unless `keymaps = false`):

| Key | Command |
|---|---|
| `<leader>sr` | `:SnipaiRunning` |
| `<leader>sh` | `:SnipaiHistory project` |
| `<leader>sH` | `:SnipaiHistory all` |

**Inside the running picker (buffer-local):**

| Key | Action |
|---|---|
| `<CR>` | Open detail popup |
| `<C-c>` | Cancel the selected job |

**Inside the history picker (buffer-local):**

| Key | Action | Status |
|---|---|---|
| `<CR>` | Open detail popup | — |
| `<C-q>` | Push the entry's file changes into the quickfix list and close | — |
| `<C-r>` | Replay the snippet with its original parameters | **v0.2.0** — not yet wired |
| `<C-d>` | Delete the history entry | **v0.2.0** — not yet wired |

Remap any of these via `setup({ keymaps = { … } })`, or pass `keymaps = false` to disable every default and bind everything manually.

---

## Configuration

All keys are optional. The defaults shown below are applied when you call `setup()` with no argument.

```lua
local xdg_config = os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config")
local xdg_data   = os.getenv("XDG_DATA_HOME")   or (os.getenv("HOME") .. "/.local/share")

require("snipai").setup({
  config_paths = {
    xdg_config .. "/snipai/snippets.json",  -- ~/.config/snipai/snippets.json
    ".snipai.json",                          -- cwd-relative; re-resolved each run
  },

  history = {
    path        = xdg_data .. "/snipai/history.jsonl", -- ~/.local/share/snipai/history.jsonl
    max_entries = 500,
    per_project = true,
  },

  claude = {
    cmd        = "claude",
    -- acceptEdits: auto-accept Edit/Write/MultiEdit (required for -p).
    -- --setting-sources "": skip plugin bootstrap (~2–3× faster; keeps
    -- keychain auth, memory, CLAUDE.md, and MCP servers working).
    -- extra_args is a nested array — your value REPLACES this default.
    extra_args = { "--permission-mode", "acceptEdits", "--setting-sources", "" },
    timeout_ms = 5 * 60 * 1000,
  },

  ui = {
    notify = "auto",     -- "auto" | "vim" | "notify" | "fidget"
    picker = "telescope",-- "telescope" (phase 1); "fzf-lua" planned
  },

  keymaps = {
    running     = "<leader>sr",
    history     = "<leader>sh",
    history_all = "<leader>sH",
    detail      = "<CR>",
    to_qf       = "<C-q>",
    cancel      = "<C-c>",
  },
})
```

**Merge semantics:**

| Key | Merge style |
|---|---|
| `config_paths` | **replaced** (not appended); use `require("snipai.config").default_config_paths()` to extend |
| `history`, `claude`, `ui` | deep merge |
| `keymaps` | deep merge, or `false` to disable every default |

Example — add a team snippet file on top of the defaults:

```lua
require("snipai").setup({
  config_paths = vim.list_extend(
    require("snipai.config").default_config_paths(),
    { "~/work/team-snippets.json" }
  ),
})
```

---

## Statusline integration

`require("snipai.statusline").status(bufnr?)` returns an animated indicator for dropping into a statusline. Empty when idle; a braille spinner frame + `" snipai"` (e.g. `⠋ snipai`) when a running job was triggered from the buffer's file or has already edited it.

A 100ms uv timer animates the spinner only while at least one job is active — zero cost when idle. Safe to call on every redraw (guards for before-setup, invalid bufnrs, scratch buffers).

```lua
-- native statusline
vim.o.statusline = "%f %{%v:lua.require'snipai.statusline'.status()%} %m"

-- lualine
require("lualine").setup({
  sections = {
    lualine_c = {
      "filename",
      function() return require("snipai.statusline").status() end,
    },
  },
})

-- custom (function-driven) statusline
local function snipai()
  local ok, sl = pcall(require, "snipai.statusline")
  return ok and sl.status() or ""
end
```

For richer state (active job count, per-job progress, last exit status), subscribe to the event bus below — `snipai.statusline` stays deliberately minimal.

---

## Events

Internal event bus for statusline widgets, custom logging, or cross-plugin integration.

```lua
local bus = require("snipai.events")
local unsubscribe = bus.global:subscribe("job_done", function(job, exit_code)
  -- ...
end)
```

| Event | Payload |
|---|---|
| `job_started` | `job` |
| `job_progress` | `job`, normalized event `{ kind, ... }` |
| `job_done` | `job`, `exit_code` |
| `job_cancelled` | `job` |
| `history_added` | history entry |
| `history_finalized` | history entry (with status, duration_ms, files_changed) |

---

## Troubleshooting

**Snippet doesn't appear in cmp**
Run `:SnipaiReload` and check `:messages` for validation errors. Common causes: `body` references an undeclared `{{param}}`, missing `prefix`, JSON parse error.

**"command not found: claude"**
Set `claude.cmd` to the absolute path, or ensure `claude` is on Neovim's `$PATH`. Test with `:echo exepath('claude')`.

**Snippet hangs forever**
Default `claude.timeout_ms` is 5 minutes. Raise it per-project, or `:SnipaiCancel <id>` the stuck job.

**No notification appears on completion**
`snipai` auto-detects the notification backend. Force one explicitly with `ui.notify = "notify"` (or `"fidget"` / `"vim"`).

**History file grew huge**
`history.max_entries` (default 500) caps the JSONL and prunes oldest entries on every finalize. Lower it, or clear with `:lua require("snipai.history").clear()`.

See `:help snipai-troubleshooting` for more.

---

## FAQ

**Why not use the Anthropic API directly?**
Most useful snippets need to *edit files* — not just return text. The Claude Code CLI gives us that tool loop plus your existing auth. A direct-API backend for text-only snippets is on the roadmap.

**Does this replace LuaSnip?**
No. `snipai` is for AI-backed snippets; regular text-expansion stays in LuaSnip. Both coexist in cmp.

**Is the JSON format VSCode-compatible?**
Inspired by it (dict of named snippets with `prefix` + `body`), extended with typed `parameter` definitions. Existing VSCode snippets won't drop in verbatim.

**What gets sent to Anthropic?**
The rendered `body`, plus whatever Claude Code itself decides to read. The plugin never exfiltrates your buffer or project — but the `claude` subprocess can, same as running it from the terminal. Use `:SnipaiDetail <id>` to inspect the exact prompt.

---

## Roadmap

See [`CHANGELOG.md`](./CHANGELOG.md) for per-version plans. Future themes:

- **Authoring:** Lua-config entry point, snippet groups.
- **UX:** diff view before accept, dry-run, token/cost meter, ghost-text preview.
- **Backends:** direct Anthropic API, per-snippet backend selection.
- **Integrations:** fzf-lua / snacks.nvim pickers, Trouble.nvim, which-key.
- **Collaboration:** shared team snippet repos, import/export.
- **Safety:** per-snippet tool allowlist, destructive-op confirmation.

---

## Contributing

Bug reports, snippet-library PRs, and backend adapters welcome. See [`CONTRIBUTING.md`](./CONTRIBUTING.md) for workflow and test conventions.

```bash
git clone https://github.com/louishuyng/snipai
cd snipai
make deps       # clones plenary into .deps/
make test       # runs the full suite
```

---

## License

[MIT](./LICENSE) © 2026 Louis Huy Nguyen
