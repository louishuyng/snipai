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
                ┌────────────────────┐  ┌──────────────────────┐
                │  CLAUDE BACKEND    │  │       UI / PICKERS    │
                │  runner (vim.system)│ │  vim.ui popups (param,│
                │  stream-json parser│  │   detail)              │
                │  event normalizer  │  │  Telescope pickers    │
                └────────────────────┘  │  notify abstraction   │
                                        └──────────────────────┘
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
│       ├── init.lua                 -- setup(opts), reload, facades, subscribes job_done
│       ├── trigger.lua              -- state-pure run(state, name, ctx) dispatcher
│       ├── statusline.lua           -- animated spinner indicator for statuslines
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
│       │   ├── init.lua             -- public API: add_pending, finalize, list, get, clear
│       │   └── store.lua            -- JSONL read/append/prune on disk
│       ├── claude/
│       │   ├── runner.lua           -- spawn claude CLI via vim.system (DI seam)
│       │   └── parser.lua           -- stream-json NDJSON parser (pure function)
│       ├── ui/
│       │   ├── popup.lua            -- vim.ui.* facade for typed-field collection
│       │   └── param_form.lua       -- snippet-aware form driven by ui.popup
│       └── sources/
│           └── cmp.lua              -- nvim-cmp source
│
├── plugin/
│   └── snipai.lua                   -- :Snipai* user commands, default mappings
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

**Planned but not yet built:** `ui/detail.lua` (history-entry popup), `pickers/running.lua` + `pickers/history.lua` (Telescope pickers), `sources/blink.lua` (blink.cmp adapter). These land in a later release; the file tree above reflects what exists on `main` today.

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
| `claude.runner` | `spawn(prompt, opts, on_event, on_exit)` | shells out to the `claude` CLI via `vim.system`. **This is the DI seam** — tests replace `M.spawn` with a fake that replays fixtures. |
| `claude.parser` | `feed(bytes) -> events` | NDJSON → normalized events (`{kind, ...}`). Pure function; no state across calls. |
| `claude.events` | normalized event type constants | shared vocabulary so `jobs/` and UI consumers agree on event shape. |
| `jobs.job` | `Job:new()`, state machine, accumulators | one snippet run: state transitions (`pending` → `running` → `success`/`failure`/`cancelled`), progress accumulation, file-path collection. |
| `jobs` | `spawn(snippet, params, prompt)`, `list()`, `get(id)`, `cancel(id)` | the Jobs manager. Owns the lifecycle and emits `job_*` events. |
| `history.store` | `append(entry)`, `read_all()`, `prune(max)` | JSONL on-disk storage. Pure-ish: takes a path, returns entries. Atomic append via O_APPEND. |
| `history` | `add_pending`, `finalize`, `list`, `get`, `clear`, `to_quickfix` | public history API. Uses `store` for persistence, subscribes to `job_*` events to record lifecycle. |

### UI (wraps `vim.ui.*`; only touched when a user acts)

| Module | Exports | Role |
|---|---|---|
| `ui.popup` | `collect(fields, opts)` | sequential `vim.ui.input` / `vim.ui.select` chain for a list of typed fields; boolean is a two-option select mapped back to Lua booleans; both `vim.ui.*` fns are injectable for tests and alternate backends. |
| `ui.param_form` | `open(snippet, opts)` | snippet-aware layer: builds an ordered field list from `snippet.parameter`, delegates to `ui.popup`, resolves defaults and validates via `params.validate_all`, surfaces errors through the notifier, guarantees `on_submit` fires only with valid values. |

### Adapters (thin, engine-specific)

| Module | Exports | Role |
|---|---|---|
| `sources.cmp` | `new(snipai_api?, opts?)`, `register(snipai_api?, cmp_mod?)` | nvim-cmp source. `complete()` maps `registry:lookup_prefix` to cmp items filtered by the current buffer's filetype. `insertText` re-inserts the typed prefix on confirm (zero visual change) so `trigger()` can swap the captured range for the rendered `insert` template once the param form submits. `execute()` builds `{buffer, replace_range}` ctx and delegates to `snipai.trigger(name, ctx)`. `register()` resolves cmp via `pcall(require, "cmp")`, is idempotent, returns false when cmp is not installed. `opts.filetype` is an injectable filetype resolver for tests. |

### Entry points

| File | Role |
|---|---|
| `init.lua` | `snipai.setup(opts)` composes config → registry → jobs → history → notify → event wiring + subscribes `job_done` for the buffer-refresh step. Re-exports public API (`trigger`, `jobs`, `history`, `reload`); `trigger` is a thin wrapper over `snipai.trigger.run(state, ...)`. |
| `trigger.lua` | State-pure `run(state, name_or_snippet, ctx)` implementing the dispatch (form vs programmatic, insert placement + auto-save, refuse-on-unnamed-scratch). Extracted so `init.lua` stays focused on wiring. |
| `statusline.lua` | `status(bufnr?)` returning `"⟳ snipai"` when an active job has touched this buffer's file, empty otherwise. Reads state via the public `snipai.jobs.list()` / `Job:files_changed()` API so it stays decoupled from internals. |
| `plugin/snipai.lua` | Declares `:Snipai*` commands and sets up default keymaps (unless `keymaps = false`). Runs once per Neovim startup. |

---

## Dependency rules

The rule is simple: **arrows point downward in the Layers diagram; never upward.**

| Layer | May `require(...)` | May NOT require |
|---|---|---|
| `config`, `params`, `events`, `claude/parser` | standard library only | anything else in the plugin |
| `snippet`, `registry` | `config`, `params` | UI, pickers, adapters, jobs, history |
| `claude/runner` | `vim.system` (or plenary.job fallback), `claude/parser` | jobs, history, UI |
| `jobs/*` | `claude/*`, `events`, `snippet`, `notify` | UI, pickers, adapters |
| `history/*` | filesystem (`vim.uv`, injectable fs), `events` | UI, pickers, adapters, jobs |
| `ui/*`, `pickers/*`, `sources/*` | core modules + their own runtime dep (`vim.ui` / Telescope / cmp) | each other (UI should not require pickers; sources should not require UI) |
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
  │   vim.system({
  │     "claude", "-p", prompt,
  │     "--output-format", "stream-json", "--verbose",
  │     "--permission-mode", "acceptEdits",
  │     "--setting-sources", "",
  │   })
  ▼
claude/parser.feed(chunk) yields normalized events:
    {kind="system",   subtype="init", model, tools}
    {kind="tool_use", tool="Edit",  input={file_path=...}}
    {kind="tool_use", tool="Write", input={file_path=...}}
    {kind="assistant_text", text="..."}
    {kind="result",   status="success", usage={...}}
  │
  ▼ job:_on_event(evt)
    • filters Edit/Write/MultiEdit into job.files_changed[] (deduped)
    • events.emit("job_progress", job, evt)
  │
  ▼ process exit  ─► job:_on_exit(code, info)
    • history.finalize(id, { status, duration_ms, files_changed, stderr, ... })
    • notifier finishes the progress toast
    • events.emit("job_done", job, exit_code)
  ▼
Subscribers fire on job_done:
  • init.lua → refresh_buffers(files_changed): :checktime per touched
    buffer so open buffers reload externally-written content
  • statusline.lua → decrements active_count, stops spinner timer
    when 0, triggers final :redrawstatus so the indicator clears
```

**Invariants to preserve when changing this flow:**

1. **One write point to history.** `add_pending` at start, `finalize` at end. Never write mid-run from elsewhere.
2. **Snippet trigger returns immediately.** Every step past `jobs.spawn` is async.
3. **`files_changed` is authoritative from the parser.** Do not re-derive it from git diff or filesystem scanning.
4. **Cancellation shares the `finalize` code path.** A cancelled job is a normal finalize with `status = "cancelled"`.
5. **Progress events are structured.** UI consumers see `{kind="tool_use", ...}`, not scraped stdout lines — so future backends can emit the same shape.

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
