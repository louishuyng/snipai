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
 nvim-cmp ──► cmp source│     ADAPTERS                 │◄── blink.cmp (phase 5)
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
                │  runner (vim.system)│ │  Volt popups (param,  │
                │  stream-json parser│  │   detail)              │
                │  event normalizer  │  │  Telescope pickers    │
                └────────────────────┘  │  notify abstraction   │
                                        └──────────────────────┘
```

**The non-negotiable rules:**

1. Core has **zero knowledge** of UI, cmp, or Telescope. It exposes functions and emits events; consumers decide what to do.
2. The Claude backend sits behind one interface (`run(prompt, opts) -> job_handle`) so a future Anthropic-API or self-hosted backend drops in without touching core.
3. Adapters are **thin** (~50 LoC each): the cmp source, blink source, and `:Snipai*` commands are all small translators.
4. UI is **pluggable**: Volt for popups, Telescope for pickers, `notify` auto-detects its backend. Each has a sensible fallback.
5. The event bus is the seam between async work and UI. Running-jobs picker **subscribes** to `job_*` events for live updates — it never polls.

---

## Folder tree

```
snipai/
├── lua/
│   └── snipai/
│       ├── init.lua                 -- setup(opts), re-exports, command dispatcher
│       ├── config.lua               -- defaults + user-opts deep merge, path resolution
│       ├── registry.lua             -- load JSON configs, merge, lookup by prefix
│       ├── snippet.lua              -- Snippet object: validate, render body w/ params
│       ├── params.lua               -- param types (string|text|select|boolean), validation
│       ├── events.lua               -- small synchronous pub/sub bus
│       ├── notify.lua               -- notify backend auto-detect + unified API
│       ├── jobs/
│       │   ├── init.lua             -- manager: spawn, list, get, cancel
│       │   └── job.lua              -- Job state machine + progress accumulator
│       ├── history/
│       │   ├── init.lua             -- public API: add, list, get, clear, to_quickfix
│       │   └── store.lua            -- JSONL read/append/prune on disk
│       ├── claude/
│       │   ├── runner.lua           -- spawn claude CLI via vim.system (DI seam)
│       │   ├── parser.lua           -- stream-json NDJSON parser (pure function)
│       │   └── events.lua           -- normalized event shape {kind, payload}
│       ├── ui/
│       │   ├── volt.lua             -- Volt availability check + shared helpers
│       │   ├── param_form.lua       -- popup to collect snippet parameters
│       │   └── detail.lua           -- popup showing a single history entry
│       ├── pickers/
│       │   ├── running.lua          -- Telescope picker of active jobs
│       │   └── history.lua          -- Telescope picker of history + qf action
│       └── sources/
│           ├── cmp.lua              -- nvim-cmp source (phase 1)
│           └── blink.lua            -- blink.cmp source (phase 5)
│
├── plugin/
│   └── snipai.lua                   -- :Snipai* user commands, default mappings
├── doc/
│   └── snipai.txt                   -- `:help snipai` (doc/tags is generated + gitignored)
│
├── tests/
│   ├── minimal_init.lua             -- headless nvim bootstrap for plenary
│   ├── helpers/                     -- shared test helpers (tmpdir, fake runner, fixtures)
│   ├── unit/                        -- pure-Lua unit tests (mirrors lua/ tree)
│   ├── integration/                 -- end-to-end with fake runner in real nvim
│   ├── ui/                          -- smoke tests for popups and pickers
│   └── fixtures/
│       ├── snippets/                -- JSON snippet fixtures
│       └── claude/                  -- captured stream-json event streams
│
├── scripts/
│   └── record_fixture.sh            -- capture a new stream-json fixture from real claude
│
├── .busted                          -- busted config for standalone `busted` runs
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

---

## Module responsibilities

Each file has **one** purpose. If you find yourself reaching for a second one, it probably belongs somewhere else.

### Core (pure Lua — no side effects, no Neovim APIs that do I/O)

| Module | Exports | Role |
|---|---|---|
| `config` | `defaults`, `merge(opts)`, `default_config_paths()` | zero-config-ready default table; deep-merges user opts. Pure; knows nothing about other modules. |
| `params` | `validate_field(def, value)`, `validate_all(defs, values)`, `resolve_defaults(defs, values)` | typed parameter rules — enforced before a snippet runs. Pure functions only. |
| `snippet` | `Snippet:validate()`, `Snippet:render(params)` | object model for a single snippet. Renders `{{placeholders}}` against a params table. |
| `registry` | `load(paths)`, `lookup_prefix(prefix)`, `get(name)`, `all()` | owns the snippet map. Loads JSON, merges by name (later paths win), skips invalids with a warning. |
| `events` | `new()` (factory) | small synchronous pub/sub bus. Factory-based so each job can own one and tests don't share global state. |
| `notify` | `info`, `warn`, `error`, `progress(id, opts)` | unified notify API; auto-detects `nvim-notify` / `fidget.nvim` / `vim.notify`. |

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

### UI (depends on Volt; only touched when a user acts)

| Module | Exports | Role |
|---|---|---|
| `ui.volt` | `ensure_loaded()`, shared window helpers | centralizes Volt setup so other UI modules don't each probe for it. |
| `ui.param_form` | `open(snippet, on_submit, on_cancel)` | Volt popup collecting typed param values, per-field validation hints, submit-gated. |
| `ui.detail` | `open(history_entry)` | Volt popup showing one history entry: prompt, params, status, duration, `files_changed`, stdout. |

### Pickers (depends on Telescope)

| Module | Exports | Role |
|---|---|---|
| `pickers.running` | `open()` | Telescope picker of active jobs; subscribes to `job_progress` for live updates. |
| `pickers.history` | `open(scope)` | Telescope picker of history, scope = `"project"` or `"all"`; defines `<C-q>` / `<C-r>` / `<C-d>` actions. |

### Adapters (thin, engine-specific)

| Module | Exports | Role |
|---|---|---|
| `sources.cmp` | nvim-cmp source object | translates cmp context into `registry.lookup_prefix`, handles `execute()` to call `snipai.trigger`. |
| `sources.blink` | blink.cmp source object (phase 5) | same contract, different engine API. |

### Entry points

| File | Role |
|---|---|
| `init.lua` | `snipai.setup(opts)` composes config → registry → jobs → history → notify → event wiring. Re-exports public API (`trigger`, `jobs`, `history`, `reload`). |
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
| `history/*` | filesystem (`vim.fn.stdpath`, `vim.uv`), `events` | UI, pickers, adapters, jobs |
| `ui/*`, `pickers/*`, `sources/*` | core modules + their own UI dep (Volt / Telescope / cmp) | each other (UI should not require pickers; sources should not require UI) |
| `init.lua`, `plugin/snipai.lua` | anything | — |

**Why this matters:** these rules are what make `tests/unit/` dependency-free. A new contributor can run the unit suite on pure-Lua modules (events, params, snippet, parser) in ~5ms with standalone `busted` — no Neovim process to boot.

**How to enforce it mentally:** if a module in a lower row needs to "tell the UI something," it emits an event. The UI subscribes. Never import upward.

---

## Data flow for one snippet run

```
User types "sample_sn" in buffer
  │
  ▼
nvim-cmp ─► sources/cmp.lua ─► registry.lookup_prefix() ─► list of Snippet{}
  │
  ▼ user selects "sample_snippet"
sources/cmp.lua :execute() hook ─► snipai.trigger(snippet, ctx)
  │
  ▼ does snippet have params?
  │   yes ─► ui/param_form.lua (Volt popup) ─► values
  │   no  ─► skip
  ▼
snippet:render(params)  -> final prompt string
  │
  ▼
jobs.spawn(snippet, params, prompt)
  ├─► history.add_pending(entry)  -- UUID, cwd, timestamp, status="running"
  ├─► events.emit("job_started", job)
  ▼
claude/runner.spawn(prompt, {output_format="stream-json"})
  │   vim.system({"claude","-p",prompt,"--output-format","stream-json","--verbose"})
  ▼
claude/parser.feed(chunk) yields normalized events:
    {kind="message_start"}
    {kind="tool_use",  tool="Edit",  path="src/x.ts"}
    {kind="tool_use",  tool="Write", path="src/x.test.ts"}
    {kind="assistant_text", text="..."}
    {kind="tool_use",  tool="Bash",  command="npm test"}
    {kind="result",    status="success", usage={...}}
  │
  ▼ job.on_event(evt)
    • appends to job.progress
    • records file paths into job.files_changed[]
    • events.emit("job_progress", job, evt)
    • notify backend updates its persistent notification
  │
  ▼ process exit
runner ─► events.emit("job_done", job, exit_code)
  ▼
history.finalize(entry_id, { status, duration_ms, files_changed, stdout, stderr })
  ▼
UI reactions (all subscribers):
  • notify: "snippet_name ✓ (3 files changed, 4.2s)"
  • pickers/running.lua: removes entry from live list
  • pickers/history.lua: new entry shows on next open
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
| `job_started` | `job` | `jobs.spawn` |
| `job_progress` | `job`, `event {kind, ...}` | `jobs.job:on_event` |
| `job_done` | `job`, `exit_code` | `claude.runner` on process exit |
| `job_cancelled` | `job` | `jobs.cancel` |
| `history_added` | `entry` | `history.add_pending` |
| `history_finalized` | `entry` | `history.finalize` |

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
2. Call `require("snipai").trigger(snippet, ctx)` from the engine's `execute`/`complete` hook.
3. Register it from `init.lua:setup()` when the engine is available (`pcall(require, "blink.cmp")`).
4. Copy `tests/integration/cmp_source_spec.lua` → `blink_source_spec.lua` with the blink shape.

No core change.

### Add a new Claude backend (e.g. direct Anthropic API)

1. Create `lua/snipai/claude/runners/<name>.lua` exporting `spawn(prompt, opts, on_event, on_exit)`.
2. Ensure events emitted match `claude/events.lua`'s shape (`message_start`, `tool_use`, `result`, ...). Translate any backend-specific format into that shape inside the runner.
3. Select the runner from config (e.g. `claude.backend = "api" | "cli"` with CLI as default).
4. Record a fixture stream from the new backend and add a test in `tests/integration/jobs_spec.lua`.

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
│   ├── fixtures.lua                  -- load JSON snippets + stream-json fixtures
│   ├── fake_runner.lua               -- stub runner that replays fixtures
│   └── tmpdir.lua                    -- isolated tmp cwd + stdpath("data") per test
├── unit/                             -- pure Lua, no nvim state needed
│   ├── config_spec.lua
│   ├── params_spec.lua
│   ├── snippet_spec.lua
│   ├── registry_spec.lua
│   ├── events_spec.lua
│   ├── notify_spec.lua
│   ├── claude/parser_spec.lua
│   └── history/store_spec.lua
├── integration/                      -- real nvim APIs + fake runner
│   ├── jobs_spec.lua
│   ├── history_spec.lua
│   └── cmp_source_spec.lua
├── ui/                               -- smoke tests only
│   ├── param_form_spec.lua
│   └── pickers_spec.lua
└── fixtures/
    ├── snippets/
    │   ├── global.json
    │   └── project.json
    └── claude/
        ├── success_edit.jsonl
        ├── success_multi.jsonl
        ├── failure_permission.jsonl
        ├── failure_parse.jsonl
        ├── cancelled.jsonl
        └── long_running.jsonl
```

**Principles:**

- **`unit/` is dependency-free.** Use standalone `busted tests/unit/foo_spec.lua` for tight loops.
- **Fake runner is the linchpin.** `tests/helpers/fake_runner.lua` swaps in via the DI seam in `claude/runner.lua`. It replays real captured `stream-json` fixtures, so every integration test is sub-second and deterministic.
- **Fixtures are real.** `scripts/record_fixture.sh "<prompt>"` captures a fresh stream from the actual Claude CLI. Do not hand-write fixture events — they will drift from the CLI.
- **UI tests are smoke only.** Verify "popup opens, values come back correctly" — no pixel assertions.

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
