# snipai

> AI-powered snippets for Neovim, backed by Claude Code.

`snipai` turns your snippet library into an AI agent. Type a prefix, pick a snippet from `nvim-cmp`, fill in any declared parameters, and let Claude Code do the work — edit files, run tests, anything Claude Code can do from the CLI — while you keep editing. History is kept per-project; file changes from any past run can be dropped into the quickfix list in one keystroke.

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
9. [Events](#events)
10. [Troubleshooting](#troubleshooting)
11. [FAQ](#faq)
12. [Roadmap](#roadmap)
13. [Contributing](#contributing)
14. [License](#license)

---

## Features

- **Snippet-as-prompt.** Declare snippets in JSON with a `body` template and typed parameters. The body becomes the prompt sent to Claude Code.
- **Parameters with real types.** `string`, `text` (multiline), `select` (with options), `boolean`. Validation is enforced before a snippet runs.
- **Global + per-project snippet libraries.** Project `.snipai.json` overrides global snippets by name.
- **Concurrent runs.** Multiple snippets can execute at the same time; each has its own state and its own notification.
- **Per-project history, persisted.** Every run is written to a JSONL log, segmented by workspace. Survives Neovim restarts.
- **Streaming progress.** Progress is parsed from Claude Code's `stream-json` output, so the notification updates as real tool uses happen — no scraping.
- **Quickfix integration.** Send any past run's file changes to the quickfix list with one keystroke.
- **Two completion engines.** Ships as a `nvim-cmp` source (phase 1); `blink.cmp` adapter planned for `v0.2.0`.
- **Telescope pickers** for both active jobs and full history.
- **Notification backend auto-detect** — `nvim-notify`, `fidget.nvim`, or stock `vim.notify`.
- **Zero-config.** `require("snipai").setup()` and start typing.

---

## Requirements

| Requirement | Version | Why |
|---|---|---|
| Neovim | **0.10+** | needs `vim.system`, `vim.uv`, `vim.islist` |
| Claude Code CLI | latest | plugin shells out to `claude -p ... --output-format stream-json` |
| `hrsh7th/nvim-cmp` | recent | completion source (required until `v0.2.0` adds blink.cmp) |
| `nvim-telescope/telescope.nvim` | recent | pickers for running + history (from `v0.1.0`) |
| `rcarriga/nvim-notify` *or* `j-hui/fidget.nvim` | optional | nicer progress notifications; falls back to `vim.notify` |
| `stevearc/dressing.nvim`, `folke/snacks.nvim`, or `nvim-telescope/telescope-ui-select.nvim` | optional | upgrades the `vim.ui.input` / `vim.ui.select` parameter prompts to popup-style widgets; stock `vim.ui.*` works without them |

Verify Claude Code is available:

```bash
claude --version
```

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

After registering the source, add it to your `nvim-cmp` source list:

```lua
local cmp = require("cmp")
cmp.setup({
  sources = cmp.config.sources({
    { name = "snipai" },
    { name = "nvim_lsp" },
    { name = "buffer" },
  }),
})
```

`register()` is a no-op when nvim-cmp is not installed, so the call is safe to leave in place even on machines where cmp is absent.

After install, run `:checkhealth snipai` (planned for `v0.1.0`) to verify everything is wired up.

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

**3. Register the cmp source** — the install snippets above already do this; confirm the call is there:

```lua
require("snipai").setup()
require("snipai.sources.cmp").register()
```

and that your `nvim-cmp` config includes `{ name = "snipai" }` in its `sources` list.

**4. Trigger it.** Open any buffer, type `aits` — the snippet shows up in `nvim-cmp` with an `[AI]` menu tag. Hit `<CR>`, answer each parameter prompt (via `vim.ui.input` / `vim.ui.select`, or your popup backend of choice), and Claude Code runs in the background while you keep editing.

**5. Check history.** `<leader>sh` opens the project's history picker (from `v0.1.0`). Press `<C-q>` on any entry to put its file changes in the quickfix list.

---

## Snippet JSON schema

```jsonc
{
  "<snippet_name>": {
    "description": "Shown in cmp as the item's detail",
    "prefix":      "what the user types to summon it",
    "body":        "Prompt template with {{placeholders}} for parameters",
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

**`filetype` scoping:**

| Shape | Meaning |
|---|---|
| *(omitted)* | available in every buffer (default) |
| `"lua"` | offered only when `vim.bo.filetype == "lua"` |
| `["lua", "luau"]` | offered when the buffer filetype matches any entry |

The filter is applied at the cmp source: non-matching snippets are silently dropped from the completion list, so a Markdown-scoped prompt never pollutes a TypeScript buffer.

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

| Key | Action |
|---|---|
| `<CR>` | Open detail popup |
| `<C-q>` | Push the entry's file changes into the quickfix list and close |
| `<C-r>` | Replay the snippet with its original parameters |
| `<C-d>` | Delete the history entry |

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
    extra_args = {},
    timeout_ms = 5 * 60 * 1000, -- 5 min per run
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

## Events

`snipai` exposes an internal event bus you can subscribe to. Useful for statusline widgets, custom logging, or integrating with other plugins.

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

**Why not just use the Anthropic API directly?**
Because most useful snippets need to *edit files* (and run tests, and read context) — not just return a blob of text. The Claude Code CLI gives us that tool loop for free, plus the user's existing auth and model selection. A direct API backend is planned for text-only snippets (see the roadmap).

**Does this replace LuaSnip / similar?**
No. `snipai` is for AI-backed snippets — ones that spawn a Claude Code run. Regular text-expansion snippets should stay in LuaSnip. Both can coexist happily in `nvim-cmp`.

**Is the JSON format a Microsoft-style snippet file?**
It's inspired by the shape (a dict of named snippets with `prefix` and `body`), but extended with typed `parameter` definitions and an AI-specific body template. Existing VSCode snippets won't drop in verbatim.

**What does `snipai` send to Anthropic?**
Only the rendered `body` of the snippet you triggered, plus whatever Claude Code itself decides to read. The plugin never exfiltrates your full buffer or project — but the `claude` subprocess can, exactly like running it from the terminal. Inspect `:SnipaiDetail <id>` to see the exact prompt.

---

## Roadmap

See [`CHANGELOG.md`](./CHANGELOG.md) for per-version plans. High-level themes beyond `v0.2.0`:

- Snippet authoring: Lua-config entry point, filetype scoping, snippet groups.
- UX: diff view before accepting, dry-run, token/cost meter, inline ghost-text preview.
- Backends: Anthropic API direct backend, per-snippet backend selection.
- Integrations: fzf-lua / snacks.nvim pickers, Trouble.nvim, which-key registration.
- Collaboration: shared team snippet repos, snippet import/export.
- Safety: per-snippet tool allowlist, destructive-op confirmation gate.

---

## Contributing

Bug reports, snippet-library PRs, and backend adapters all welcome. See [`CONTRIBUTING.md`](./CONTRIBUTING.md) for the dev workflow and test conventions.

```bash
git clone https://github.com/louishuyng/snipai
cd snipai
make deps       # clones plenary into .deps/
make test       # runs the full suite
```

---

## License

[MIT](./LICENSE) © 2026 Louis Huy Nguyen
