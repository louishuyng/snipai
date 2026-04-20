# Architecture

> Audience: contributors. If you're a user, read `README.md`.

This document is the map of the codebase. It covers the folder layout, what each module is responsible for, the one-way dependency rules that keep the code testable, and the extension points for adding new backends, completion engines, pickers, or snippet parameter types.

## Table of contents

1. [Layers](#layers)
2. [Folder tree](#folder-tree)
3. [Module responsibilities](#module-responsibilities)
4. [Dependency rules](#dependency-rules)
5. [Data flow for one snippet run](#data-flow-for-one-snippet-run)
6. [Event catalog](#event-catalog)
7. [Extension points](#extension-points)
8. [Test layout](#test-layout)
9. [Coding conventions](#coding-conventions)

---

## Layers

```
                        ┌──────────────────────────────┐
 nvim-cmp ──► cmp source│     ADAPTERS                 │◄── blink.cmp (planned)
 :Snipai* cmds │         │  cmp / blink / commands      │
 keymaps        ─────────►                              │
                        └───────────────┬──────────────┘
                                        ▼
                        ┌──────────────────────────────┐
                        │          CORE (pure Lua)     │
                        │  config · registry · snippet │
                        │  params · jobs · history     │
                        │  events (pub/sub)            │
                        └──────┬──────────────┬────────┘
                               ▼              ▼
                ┌─────────────────────────┐  ┌────────────────────────┐
                │  CLAUDE BACKEND         │  │       UI / PICKERS     │
                │   term_runner (PTY)     │  │  vim.ui popups (param, │
                │   session_tailer (JSONL)│  │   tabbed detail)       │
                │   shared parser         │  │  Telescope pickers     │
                │   event normalizer      │  │  notify abstraction    │
                └─────────────────────────┘  └────────────────────────┘
```

**The non-negotiable rules:**

1. Core has **zero knowledge** of UI, cmp, or Telescope. It exposes functions and emits events; consumers decide what to do.
2. The Claude backend sits behind one interface (`run(prompt, opts) -> job_handle`) so a future Anthropic-API or self-hosted backend drops in without touching core.
3. Adapters are **thin** (~50 LoC each): the cmp source, blink source, and `:Snipai*` commands are all small translators.
4. UI is **pluggable**: `vim.ui.input` / `vim.ui.select` for prompts (upgraded by any `dressing.nvim` / `snacks.nvim` / `telescope-ui-select` override the user has installed), Telescope for pickers, `notify` auto-detects its backend. Each has a sensible fallback.
5. The event bus is the seam between async work and UI. Running-jobs picker **subscribes** to `job_*` events for live updates — it never polls.

---

## Folder tree

```
snipai/
├── lua/
│   └── snipai/
│       ├── init.lua                 -- setup(opts), reload, facades — pure composition
│       ├── trigger.lua              -- state-pure run(state, name, ctx) + neovim-side defaults
│       ├── statusline.lua           -- animated spinner indicator for statuslines
│       ├── buffer_refresh.lua       -- job_done → :checktime loop (attach helper)
│       ├── keymaps.lua              -- global <leader>sr/sh/sH installer
│       ├── config.lua               -- defaults + user-opts deep merge, XDG paths
│       ├── registry.lua             -- load JSON configs, merge, lookup by prefix
│       ├── snippet.lua              -- Snippet: validate, render body + insert w/ builtins
│       ├── params.lua               -- param types (string|text|select|boolean), validation
│       ├── events.lua               -- small synchronous pub/sub bus
│       ├── notify.lua               -- notify backend auto-detect + unified API
│       ├── jobs/
│       │   ├── init.lua             -- manager: spawn, list, get, cancel
│       │   └── job.lua              -- Job state machine + progress accumulator
│       ├── history/
│       │   ├── init.lua             -- public API: add_pending, finalize, list, get, clear, to_quickfix
│       │   └── store.lua            -- JSONL read/append/prune on disk
│       ├── claude/
│       │   ├── runner.lua           -- thin coordinator: session-id, tailer, term_runner
│       │   ├── term_runner.lua      -- PTY-hosted `claude` via vim.fn.termopen (DI seam)
│       │   ├── session_tailer.lua   -- fs_poll over ~/.claude/projects/<slug>/<sid>.jsonl
│       │   ├── session_paths.lua    -- pure cwd→transcript path mapping
│       │   └── parser.lua           -- NDJSON → normalized events (stream-json + session)
│       ├── ui/
│       │   ├── popup.lua            -- vim.ui.* facade for typed-field collection
│       │   ├── param_form.lua       -- snippet-aware form driven by ui.popup
│       │   ├── detail.lua           -- pure summary renderer + build_summary_buf
│       │   └── detail_tabs.lua      -- 2-tab float (Summary + Terminal) with buffer swap
│       ├── pickers/
│       │   ├── running.lua          -- Telescope picker of active jobs
│       │   └── history.lua          -- Telescope picker of history (project|all)
│       └── sources/
│           └── cmp.lua              -- nvim-cmp source
│
├── plugin/
│   └── snipai.lua                   -- :Snipai* user commands (all 7); dispatches to state
├── doc/
│   └── snipai.txt                   -- `:help snipai` (doc/tags is generated + gitignored)
│
├── tests/
│   ├── minimal_init.lua             -- headless nvim bootstrap for plenary
│   ├── helpers/                     -- shared test helpers (json encode/decode, etc.)
│   ├── unit/                        -- pure-Lua / DI-driven specs (mirrors lua/ tree)
│   ├── integration/                 -- full-nvim end-to-end (placeholder, none yet)
│   └── fixtures/
│       └── claude/                  -- captured stream-json event streams
│
├── scripts/
│   └── smoke.lua                    -- release-time real-CLI smoke runner
│
├── .editorconfig
├── .gitignore
├── .luarc.json                      -- lua-language-server config
├── stylua.toml                      -- formatter config
├── Makefile                         -- test/format/lint/deps targets
│
├── README.md                        -- end-user docs
├── ARCHITECTURE.md                  -- this file
├── CONTRIBUTING.md                  -- dev workflow
├── CHANGELOG.md
└── LICENSE
```

**Planned but not yet built:** `sources/blink.lua` (blink.cmp adapter, Phase 5). The file tree above reflects what exists on `main` today.

---

## Module responsibilities

Each file has **one** purpose. If you find yourself reaching for a second one, it probably belongs somewhere else.

### Core (pure Lua — no side effects, no Neovim APIs that do I/O)

| Module | Exports | Role |
|---|---|---|
| `config` | `defaults`, `merge(opts, env)`, `default_config_paths(env)` | XDG-pure defaults (`~/.config/snipai`, `~/.local/share/snipai`) + deep-merge of user opts. No Neovim dependency — resolution is injected `env` → `$XDG_*` → `$HOME/.config` and friends. Ships `--permission-mode acceptEdits --setting-sources ""` as the `claude.extra_args` default. |
| `params` | `validate_definition(def)`, `validate_value(def, value)`, `validate_all(defs, values)`, `resolve_defaults(defs, values)` | typed parameter rules — enforced at load time and submit time. Pure functions only. |
| `snippet` | `Snippet:validate()`, `Snippet:render(values, ctx?)`, `Snippet:render_insert(values, ctx?)`, `Snippet:matches_filetype(ft)`, `M.RESERVED` | one snippet: validates body + insert + filetype + parameter block; renders `{{placeholders}}` against declared params merged with plugin-supplied built-ins (`cursor_file`, `cursor_line`, `cursor_col`, `cwd`). |
| `registry` | `load(paths)`, `lookup_prefix(prefix)`, `get(name)`, `all()`, `reload()` | owns the snippet map. Loads JSON, merges by name (later paths win), skips invalids with a warning. |
| `events` | `new()` (factory) | small synchronous pub/sub bus. Factory-based so each setup owns its own bus and tests don't share global state. |
| `notify` | `new(opts)` → Notifier with `:notify(msg, level?, opts?)` and `:progress(title, initial?)` returning a Progress handle (`:update`, `:finish`) | unified notify API; auto-detects `nvim-notify` / `fidget.nvim` / `vim.notify`; `require`, `vim.notify`, and `vim.log.levels` are injectable for tests. |

### Execution (touches processes + filesystem)

| Module | Exports | Role |
|---|---|---|
| `claude.runner` | `spawn(prompt, opts, on_event, on_exit)` | coordinator. Generates a session-id, resolves the on-disk transcript path via `session_paths`, starts a `session_tailer` on it, and delegates the PTY to `term_runner`. Returns a handle exposing `bufnr / job_id / session_id / cancel`. Every dependency is injected via `opts` for tests. |
| `claude.term_runner` | `spawn(opts) -> handle` | PTY host. Creates a hidden scratch buffer, runs `claude --session-id <uuid> --name <snippet> …` via `vim.fn.termopen`, and sends the rendered prompt with `chansend` so the session stays alive for follow-up turns. All Neovim primitives (`nvim_create_buf`, `termopen`, `chansend`, `jobstop`, `nvim_buf_call`) are injected via `opts.primitives`. |
| `claude.session_tailer` | `new(opts)`, `:start(path)`, `:tick()`, `:stop()` | tracks a byte offset on the session JSONL and feeds newly-written bytes into `claude.parser`. The real backend uses `vim.uv.fs_poll` at 250 ms; tests pass a synchronous no-op poller and drive `:tick()` themselves. |
| `claude.session_paths` | `project_dir(opts)`, `session_file(opts)` | pure mapping between a working directory and Claude Code's on-disk transcript location (`~/.claude/projects/<cwd-slug>/<session-id>.jsonl`). |
| `claude.parser` | `parse(bytes)`, `new():feed(chunk)`, `:flush()` | NDJSON → normalized events (`{kind, ...}`). Accepts both stream-json shape (block content nested in `message`) and session-JSONL shape (top-level `tool_use` / `tool_result`, `assistant.content` carrying blocks). Pure. |
| `jobs.job` | `Job:new()`, 5-state lifecycle, progress accumulator | one snippet run: transitions `pending → running ⇄ idle → complete / cancelled / error`. `idle` flips on a parser `result` event and back on the next non-result event, so the UI knows whether Claude is actively producing output or waiting for the next user message. Holds `files_changed`, `session_id`, and exposes `terminal_buf()` for the detail popup. |
| `jobs` | `spawn(snippet, params, prompt)`, `list()`, `get(id)`, `cancel(id)`, `cancel_all()`, `get_terminal_buf(id)` | the Jobs manager. Owns the lifecycle and emits `job_*` events. `get_terminal_buf` lets the detail popup attach to the active PTY without reaching into private Job state. |
| `history.store` | `append(entry)`, `read_all()`, `prune(max)` | JSONL on-disk storage. Pure-ish: takes a path, returns entries. Atomic append via O_APPEND. |
| `history` | `add_pending`, `finalize`, `list`, `get`, `clear`, `to_quickfix` | public history API. Uses `store` for persistence; `to_quickfix(id)` builds one qf item per touched file (lnum=1 since Edit events carry no line numbers) and sets a `snipai: <snippet>` title. `setqflist` is injected for tests. |

### UI (wraps `vim.ui.*`; only touched when a user acts)

| Module | Exports | Role |
|---|---|---|
| `ui.popup` | `collect(fields, opts)` | sequential `vim.ui.input` / `vim.ui.select` chain for a list of typed fields; boolean is a two-option select mapped back to Lua booleans; both `vim.ui.*` fns are injectable for tests and alternate backends. |
| `ui.param_form` | `open(snippet, opts)` | snippet-aware layer: builds an ordered field list from `snippet.parameter`, delegates to `ui.popup`, resolves defaults and validates via `params.validate_all`, surfaces errors through the notifier, guarantees `on_submit` fires only with valid values. |
| `ui.detail` | `render(entry) -> { lines, title }`, `build_summary_buf(entry, api?)`, `open(entry, opts?)` | history-entry summary. `render` is a pure function returning section-assembled lines (status, meta, params, files, prompt, stderr); status `"success"` is rendered as `[complete]` so legacy rows read with current terminology. `build_summary_buf` is the single-tab buffer factory reused by `ui.detail_tabs`. |
| `ui.detail_tabs` | `tab_bar_line(active)`, `open(entry, opts)` | tabbed float (Summary + Terminal). `<Tab>` / `<S-Tab>` swap the float's underlying buffer via `nvim_win_set_buf` — no window recreation. When the entry's PTY is gone (historical row, or the buffer was closed), the Terminal tab falls back to a read-only placeholder so the keybind never crashes. |

### Pickers (Telescope-backed; soft-fail without it)

| Module | Exports | Role |
|---|---|---|
| `pickers.running` | `format_row(job, now_ms)` (pure), `_glyph(status)` (pure), `open(opts)` | active-job picker. Row is `<glyph> <name> <duration> <shortId> (<file>)` where `<glyph>` cycles `… running / ◦ idle / ✓ complete / ✗ cancelled / ! error`. `<CR>` opens the tabbed detail popup with the job's live terminal buffer attached; `<C-c>` cancels. Snapshot-on-open; live refresh lands in v0.3.0. |
| `pickers.history` | `format_row(entry)` (pure), `open(opts)` | history picker scoped by `opts.scope` (`project` default, `all`). Rows sorted newest-first with the same 5-state glyph set. `<CR>` opens detail (attaches a terminal tab when the entry's session is still active); `<C-q>` calls `history:to_quickfix(id)` then notifies the file count. `<C-r>` replay and `<C-d>` delete scoped to v0.3.0. |

Both picker modules accept `opts.telescope` with three modes: `nil` auto-resolves via `pcall`, `false` forces "absent" (test seam), a table is used as a pre-built bundle. `format_row` is unit-tested; the Telescope wrapper is smoke-only per the design spec.

### Adapters (thin, engine-specific)

| Module | Exports | Role |
|---|---|---|
| `sources.cmp` | `new(snipai_api?, opts?)`, `register(snipai_api?, cmp_mod?)` | nvim-cmp source. `complete()` maps `registry:lookup_prefix` to cmp items filtered by the current buffer's filetype. `insertText` re-inserts the typed prefix on confirm (zero visual change) so `trigger()` can swap the captured range for the rendered `insert` template once the param form submits. `execute()` builds `{buffer, replace_range}` ctx and delegates to `snipai.trigger(name, ctx)`. `register()` resolves cmp via `pcall(require, "cmp")`, is idempotent, returns false when cmp is not installed. `opts.filetype` is an injectable filetype resolver for tests. |

### Entry points

| File | Role |
|---|---|
| `init.lua` | `snipai.setup(opts)` composes config → registry → jobs → history → notify → event wiring. Delegates the `job_done` subscription to `buffer_refresh.attach`, spinner wiring to `statusline.attach`, and default-keymap installation to `keymaps.apply`. Re-exports public API (`trigger`, `jobs`, `history`, `reload`); `trigger` is a thin wrapper over `snipai.trigger.run(state, ...)`. Contains no direct `vim.api.*` calls. |
| `trigger.lua` | State-pure `run(state, name_or_snippet, ctx)` implementing the dispatch (form vs programmatic, insert placement + auto-save, refuse-on-unnamed-scratch). Owns the Neovim-side defaults for `gather_builtins` / `place_insert` / `save_buffer` — `state.<name>` overrides for tests, otherwise the locally-defined defaults run. |
| `statusline.lua` | `attach(events)`, `status(bufnr?)` returning `"⟳ snipai"` when an active job has touched this buffer's file, empty otherwise. Reads state via the public `snipai.jobs.list()` / `Job:files_changed()` API so it stays decoupled from internals. |
| `buffer_refresh.lua` | `attach(events, refresh_fn?)`. Subscribes the given bus's `job_done` and runs `:checktime` on every loaded buffer whose file appears in the job's `files_changed` list. Default refresh is pluggable for tests (no-op in the init_spec helper). |
| `keymaps.lua` | `apply(spec, opts)`. Installs `<leader>sr` / `<leader>sh` / `<leader>sH` → `:SnipaiRunning` / `:SnipaiHistory project` / `:SnipaiHistory all`. `spec = false` skips everything, per-key `false` / `""` disables a slot, string values override the lhs. `opts.keymap_set` is the test seam. |
| `plugin/snipai.lua` | Declares the full `:Snipai*` command set (Trigger, Running, History, Detail, ToQuickfix, Cancel, Reload). Each command pulls state from `require("snipai")._state` through a shared `get_state()` guard that warns cleanly when `setup()` hasn't run. Id-based commands autocomplete against `history:list{scope="all"}` or `jobs:list()`. Default keymaps are installed from `setup()` via `snipai.keymaps`, not here. |

---

## Dependency rules

The rule is simple: **arrows point downward in the Layers diagram; never upward.**

| Layer | May `require(...)` | May NOT require |
|---|---|---|
| `config`, `params`, `events`, `claude/parser` | standard library only | anything else in the plugin |
| `snippet`, `registry` | `config`, `params` | UI, pickers, adapters, jobs, history |
| `claude/session_paths`, `claude/parser` | standard library only | anything else in the plugin |
| `claude/session_tailer` | `claude/parser`, `vim.uv` (injectable) | jobs, history, UI |
| `claude/term_runner` | `vim.api` / `vim.fn` (injectable) | jobs, history, UI, parser |
| `claude/runner` | `claude/{session_paths, session_tailer, term_runner}` | jobs, history, UI |
| `jobs/*` | `claude/*`, `events`, `snippet`, `notify` | UI, pickers, adapters |
| `history/*` | filesystem (`vim.uv`, injectable fs), `events` | UI, pickers, adapters, jobs |
| `ui/*`, `sources/*` | core modules + their own runtime dep (`vim.ui` / cmp) | each other, pickers (UI should not require pickers; sources should not require UI) |
| `pickers/*` | core modules + `ui.detail` (for `<CR>` action) + Telescope | jobs internals, sources, history store internals |
| `buffer_refresh`, `statusline`, `keymaps` | `events` + `vim.*` | everything else in the plugin (they are leaf attach-helpers) |
| `init.lua`, `plugin/snipai.lua` | anything | — |

**Why this matters:** these rules are what make `tests/unit/` dependency-free. A new contributor can run the unit suite on pure-Lua modules (events, params, snippet, parser) in ~5ms with standalone `busted` — no Neovim process to boot.

**How to enforce it mentally:** if a module in a lower row needs to "tell the UI something," it emits an event. The UI subscribes. Never import upward.

---

## Data flow for one snippet run

```
User types "ailua" in buffer
  │
  ▼
nvim-cmp ─► sources/cmp.lua ─► registry.lookup_prefix() filtered by
             vim.bo.filetype ─► list of Snippet{} with insertText=prefix
  │
  ▼ user confirms; cmp re-inserts the prefix (zero visual change) and
    calls sources/cmp.lua :execute()
  ▼
sources/cmp.lua builds ctx = { buffer, replace_range = [col-#prefix, col] }
  │
  ▼
snipai.trigger(snippet_name, ctx) ─► trigger.run(state, name, ctx)
  │
  ▼ gather_builtins() → ctx.builtins = {
      cursor_file, cursor_line, cursor_col, cwd
    }
  │
  ▼ refuse if snippet.insert is set AND cursor_file == "" (scratch)
  │
  ▼ does snippet declare params AND ctx.params nil?
  │   yes ─► ui/param_form.lua (vim.ui.* chain) ─► resolved values
  │   no  ─► skip; spawn with ctx.params (or {} → declared defaults)
  ▼
snippet.insert present?
  yes ─► snippet:render_insert(values, ctx.builtins)
         state.place_insert(buffer, replace_range, text)
         state.save_buffer(buffer)  -- silent :write
  no  ─► skip buffer steps
  ▼
snippet:render(values, ctx.builtins)  -> final prompt string
  │
  ▼
jobs.spawn(snippet, values, ctx)
  ├─► Job captures cursor_file for statusline attribution
  ├─► history.add_pending({ id, cwd, started_at, status="running", ... })
  ├─► events.emit("job_started", job)  -- statusline spinner starts
  ▼
claude/runner.spawn(prompt, claude_opts)
  │   uuid = generated RFC4122-v4 session-id
  │   path = ~/.claude/projects/<cwd-slug>/<uuid>.jsonl
  │
  │   session_tailer:start(path)        -- fs_poll @ 250ms
  │   term_runner.spawn({
  │     prompt, session_id=uuid, snippet_name, extra_args,
  │     on_exit = (code, info) → tailer:stop(); run on_exit
  │   })
  │     vim.api.nvim_create_buf(false, true)     -- hidden scratch
  │     vim.fn.termopen({
  │       "claude", "--session-id", uuid, "--name", snippet,
  │       "--permission-mode", "acceptEdits",
  │       "--setting-sources", "",
  │     }, { on_exit = … })
  │     vim.fn.chansend(job_id, prompt .. "\r")  -- first turn
  ▼
session_tailer reads newly-appended JSONL bytes → claude/parser.feed:
    {kind="assistant_text", text="..."}
    {kind="tool_use", tool="Edit",  input={file_path=...}}
    {kind="tool_use", tool="Write", input={file_path=...}}
    {kind="result",   status="success"}           -- turn done → idle
    {kind="assistant_text", text="..."}           -- next turn → running
  │
  ▼ job:_on_event(evt)
    • result events flip running → idle; any other event flips back
    • filters Edit/Write/MultiEdit into job.files_changed[] (deduped)
    • events.emit("job_progress", job, evt)
  │
  ▼ buffer_refresh observes job_progress and runs :checktime on
    each new file the moment it first appears — so long sessions
    reload the user's buffers between turns, not only on exit.
  │
  ▼ PTY exit (user /exit, :bd!, or SIGTERM) ─► term_runner on_exit
    runner stops tailer → fires on_exit(code, { cancelled }) ─►
      jobs.job:_on_exit(code, info)
    • classify: code==0 → complete; cancelled flag → cancelled; else error
    • history.finalize(id, { status, duration_ms, files_changed, stderr, ... })
    • notifier finishes the progress toast
    • events.emit("job_done", job, exit_code)
  ▼
Subscribers that fire throughout:
  • buffer_refresh → :checktime per newly-observed file (on job_progress
    AND job_done)
  • statusline → decrements active_count, stops spinner timer when 0,
    triggers final :redrawstatus so the indicator clears
  • running picker (if open) → re-reads job state on next refresh;
    live-refresh subscription lands in v0.3.0
```

**Invariants to preserve when changing this flow:**

1. **One write point to history.** `add_pending` at start, `finalize` at end. Never write mid-run from elsewhere.
2. **Snippet trigger returns immediately.** Every step past `jobs.spawn` is async.
3. **`files_changed` is authoritative from the parser.** Do not re-derive it from git diff or filesystem scanning.
4. **Cancellation shares the `finalize` code path.** A cancelled job is a normal finalize with `status = "cancelled"`.
5. **Progress events are structured.** UI consumers see `{kind="tool_use", ...}`, not scraped stdout lines or PTY output — so future backends can emit the same shape.
6. **One history entry per session.** A long, multi-turn session stays on one row; `files_changed` accumulates across turns.

### Lifecycle states

The five tokens a job's `status` carries:

| State | Meaning | Reachable from | Terminal? |
|---|---|---|---|
| `pending` | constructed, not started | — | no |
| `running` | PTY alive; last parser event was not `result` (Claude is producing output or a tool is running) | `pending`, `idle` | no |
| `idle` | PTY alive; last event was `result` (Claude has finished its turn and is waiting for the next message — you can reopen the terminal and type) | `running` | no |
| `complete` | PTY exited cleanly (user `/exit`ed or closed the terminal) | `running`, `idle` | yes |
| `cancelled` | PTY killed via `jobs:cancel()` (SIGTERM from `:SnipaiCancel` or `<C-c>` in the running picker) | any non-terminal state | yes |
| `error` | PTY exited non-zero without a cancel | `running`, `idle` | yes |

Legacy entries written before the lifecycle rename carry `status = "success"`; UI layers (`ui.detail`, `pickers.running`, `pickers.history`) treat it as an alias for `complete`.

---

## Event catalog

Emitted by `jobs/*` and `history/*`. Subscribe via the plugin-wide bus:

```lua
local bus = require("snipai.events").global
local unsub = bus:subscribe("job_done", function(job, exit_code) ... end)
```

| Event | Payload | Emitted by |
|---|---|---|
| `job_started` | `job` | `jobs.job:start` |
| `job_progress` | `job`, `event {kind, ...}` | `jobs.job:_on_event` |
| `job_done` | `job`, `exit_code` | `jobs.job:_on_exit` (after `history.finalize`) |
| `history_added` | `entry` | `history.add_pending` |
| `history_finalized` | `entry` | `history.finalize` |

**Built-in subscribers** (wired in `init.lua` setup):

- `job_done` → `refresh_buffers(job:files_changed())` — `:checktime` every loaded buffer whose file Claude touched, so in-place edits reload.
- `job_started` / `job_done` → `statusline.attach` manages the spinner's `active_count` and uv timer.

**Do not add new event names without updating this table AND `doc/snipai.txt`.** The public event surface is documentation, not implementation.

---

## Extension points

### Add a new parameter type

1. Add the type string to the `valid_types` table in `params.lua`.
2. Implement `validate_field` and `coerce` branches for it.
3. Add a widget in `ui/param_form.lua` that renders the input.
4. Add one unit spec under `tests/unit/params_spec.lua`.
5. Update the schema table in `README.md` and `doc/snipai.txt`.

Everything else (registry, snippet, jobs, history) will work unchanged.

### Add a new completion engine (e.g. blink.cmp)

1. Write `lua/snipai/sources/blink.lua` that conforms to blink's source API.
2. Call `require("snipai").trigger(name, ctx)` from the engine's `execute` hook.
3. Expose a `register(snipai_api?, engine_mod?)` entry point mirroring `sources.cmp`; users call it from their engine config.
4. Copy `tests/unit/sources/cmp_spec.lua` → `blink_spec.lua` with the blink shape.

No core change.

### Add a new Claude backend (e.g. direct Anthropic API)

1. Create `lua/snipai/claude/runners/<name>.lua` exporting `spawn(prompt, opts, on_event, on_exit)`.
2. Ensure events emitted match the normalized shape produced by `claude/parser.lua` (`system`, `assistant_text`, `tool_use`, `tool_result`, `result`). Translate any backend-specific format into that shape inside the runner.
3. Select the runner from config (e.g. `claude.backend = "api" | "cli"` with CLI as default).
4. Record a fixture stream from the new backend and add a test under `tests/unit/jobs/` using the same recording-runner fake pattern.

### Add a new picker backend (e.g. fzf-lua)

1. Mirror `pickers/running.lua` → `pickers_fzf/running.lua`.
2. Select from `ui.picker` config.
3. Re-use all the actions (`to_quickfix`, `cancel`, etc.) — they're pure functions of a history entry, not Telescope-specific.

---

## Test layout

```
tests/
├── minimal_init.lua                  -- bootstraps plenary + plugin in headless nvim
├── helpers/
│   └── json.lua                      -- pure-Lua JSON encode/decode for fixture specs
├── unit/                             -- pure Lua / DI-driven specs
│   ├── config_spec.lua
│   ├── params_spec.lua
│   ├── snippet_spec.lua
│   ├── registry_spec.lua
│   ├── events_spec.lua
│   ├── notify_spec.lua
│   ├── init_spec.lua
│   ├── statusline_spec.lua
│   ├── claude/
│   │   ├── parser_spec.lua
│   │   └── runner_spec.lua
│   ├── history/
│   │   ├── store_spec.lua
│   │   └── init_spec.lua
│   ├── jobs/
│   │   ├── job_spec.lua
│   │   └── init_spec.lua
│   ├── ui/
│   │   ├── popup_spec.lua
│   │   └── param_form_spec.lua
│   └── sources/
│       └── cmp_spec.lua
├── integration/                      -- full-nvim end-to-end (placeholder)
└── fixtures/
    └── claude/
        └── success_multi.jsonl
```

**Principles:**

- **`unit/` is dependency-free.** Each module exposes injection seams (`opts._deps`, `opts.reader`, `opts.ui_input`, `opts.popup`, ...) so specs run in pure Lua without needing a real cmp / Telescope / vim.ui backend.
- **Fake runner inside specs.** `tests/unit/init_spec.lua` and `tests/unit/jobs/init_spec.lua` define their own recording runner fakes that implement the `spawn(prompt, opts, on_event, on_exit)` contract and drive exit/event callbacks explicitly — no timing flake.
- **Fixtures are real.** `success_multi.jsonl` is a captured stream from the actual Claude CLI. Do not hand-write fixture events — they will drift from the CLI.
- **UI specs are unit-level with injected `vim.ui.*`.** Full-nvim smoke tests can land under `tests/integration/` later; for now the `ui.popup` / `ui.param_form` specs stub the `vim.ui` seam and assert value flow end-to-end.

See `CONTRIBUTING.md` for how to run each tier.

---

## Coding conventions

- **Style:** `stylua.toml` rules — 2-space indent, 100-col, `AutoPreferDouble`, `call_parentheses = "Always"`. Run `make format` before committing.
- **Types:** `.luarc.json` configures lua-language-server. Add `---@class` / `---@param` annotations on any public API; internal helpers don't need them unless the shape is non-obvious.
- **Comments:** only for the non-obvious *why*. Don't explain what well-named code already says.
- **Module file shape:**
  ```lua
  -- One-line purpose.
  --
  -- Longer context only if the why is non-obvious (e.g. pointing out an
  -- invariant other modules rely on).

  local M = {}

  -- ... functions attached to M ...

  return M
  ```
- **Error handling:** core modules return `nil, err` rather than throwing; UI and adapter layers may `vim.notify(err, ERROR)` when surfacing to the user. Never let a handler crash the event bus — `events.lua` already pcalls subscribers.
- **Async:** `vim.system` + callbacks is preferred over `vim.fn.jobstart`. Wrap callbacks in `vim.schedule` when they need to touch buffers or UI.
- **Public vs. internal:** anything exported from `init.lua` is **public API** and must be kept stable between minor versions. Internal modules can break freely.
- **Commits:** one logical change per commit; AI planning docs stay out of git (see `.gitignore`).
