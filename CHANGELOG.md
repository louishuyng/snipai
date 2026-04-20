# Changelog

All notable changes to `snipai` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added — session-terminal backend (v0.2.0 in-flight)
- PTY-hosted interactive `claude` sessions via `vim.fn.termopen`. Every snippet now spawns a persistent session addressable by `--session-id <uuid>`; follow-up turns are a single `chansend` away.
- `lua/snipai/claude/session_paths.lua` — pure cwd → `~/.claude/projects/<cwd-slug>/<sid>.jsonl` mapping.
- `lua/snipai/claude/session_tailer.lua` — `vim.uv.fs_poll` tailer that forwards new transcript bytes into the existing `claude.parser`, so `files_changed` and quickfix integration survive the backend swap unchanged.
- `lua/snipai/claude/term_runner.lua` — hidden scratch buffer + `termopen` + `chansend` host, with every Neovim primitive injectable through `opts.primitives` for unit tests.
- `lua/snipai/ui/detail_tabs.lua` — tabbed detail float (Summary + Terminal). `<Tab>` / `<S-Tab>` swap the float's buffer via `nvim_win_set_buf`; historical rows without a live PTY fall back to a read-only placeholder.
- Five-state job lifecycle: `pending / running / idle / complete / cancelled / error`. `running ⇄ idle` transitions fire on parser `result` events so the UI can distinguish "Claude is producing output" from "Claude is waiting for your next message" across a multi-turn session.
- `session_id` field on history entries, carried through `history.store` additively. Legacy rows written with `status = "success"` keep parsing; UI layers display them as `complete`.
- Running and history pickers ship 5-state glyphs: `… running / ◦ idle / ✓ complete / ✗ cancelled / ! error`. Selecting a row lands in the tabbed detail popup; running rows attach to the live PTY buffer.
- `snipai.jobs.get_terminal_buf(id)` exposed so pickers and the detail popup can jump into the active PTY without reaching into private Job state.
- `VimLeavePre` autocmd soft-stops every active session on Neovim exit so no orphan `claude` processes survive the editor.
- Mid-session buffer refresh: `buffer_refresh.attach` now subscribes to `job_progress` (not only `job_done`), so each new file a long session touches reloads in open buffers the moment it first appears. Per-job dedup stops the same path from being refreshed twice.
- Parser accepts session-JSONL shape additively — top-level `tool_use` / `tool_result` records and `assistant.content` (in addition to `assistant.message.content`) now produce the same normalized event stream as stream-json. Existing stream-json fixtures unaffected.

### Changed — session-terminal backend
- `claude/runner.lua` rewritten as a thin coordinator: generates a session-id, resolves the transcript path via `session_paths`, starts a `session_tailer`, and delegates the PTY to `term_runner`. Public `spawn(prompt, opts, on_event, on_exit) -> handle` contract unchanged; the old `vim.system` + `--output-format stream-json` code path is gone.
- Job terminal successful state renamed `success` → `complete` in `jobs/job.lua`. `history.store` and UI layers accept the legacy `success` token as a transparent alias for readback.

### Added
- Initial project scaffolding: `Makefile`, `stylua.toml`, `.luarc.json`, `.editorconfig`, `.gitignore`, `.busted`, `tests/minimal_init.lua`.
- Pub/sub event bus (`lua/snipai/events.lua`) with factory-based buses so each job can own its own bus without shared global state.
- Typed parameter model (`lua/snipai/params.lua`) with `string` / `text` / `select` / `boolean` types, default resolution, and pure validation predicates shared by load-time and submit-time paths.
- Snippet object (`lua/snipai/snippet.lua`) that validates a snippet definition, extracts placeholders in body order, and renders `{{placeholders}}` against a param values table.
- Registry (`lua/snipai/registry.lua`) loading JSON configs, merging by name (later paths win), skipping invalid entries with a warning so one bad snippet cannot starve the rest.
- Config merge (`lua/snipai/config.lua`) with zero-config defaults, deep merge for `history` / `claude` / `ui`, and `keymaps = false` to opt out of defaults.
- Claude Code integration: NDJSON parser (`lua/snipai/claude/parser.lua`) and process runner (`lua/snipai/claude/runner.lua`) with DI seams for `vim.system`, the scheduler, and the parser.
- Jobs pipeline (`lua/snipai/jobs/*`): Job lifecycle, files-changed deduplication, stderr-first-line error messages, manager over the runner with active-set tracking and cancellation.
- History (`lua/snipai/history/*`): two-write lifecycle (`add_pending` → `finalize`), JSONL persistence with prune to `max_entries`, project-scoped or all-scope listing.
- Notify facade (`lua/snipai/notify.lua`) auto-detecting `nvim-notify` / `fidget.nvim` / `vim.notify`, with progress handles that emit prefixed update / finish messages.
- Top-level `snipai.setup()` / `snipai.trigger()` / `snipai.reload()` and the `:SnipaiTrigger <name>` command.
- UI popup facade (`lua/snipai/ui/popup.lua`): sequential `vim.ui.input` / `vim.ui.select` chain over a typed field list; boolean is a two-option select mapped back to Lua booleans; both `vim.ui.*` fns are injectable so tests and alternate backends plug in behind the same API.
- Snippet-aware parameter form (`lua/snipai/ui/param_form.lua`): translates `snippet.parameter` into an ordered field list (placeholders in body order, leftovers alphabetically), collects raw values, resolves defaults, validates via `params.validate_all`, and guarantees `on_submit` only fires with valid values.
- `snipai.trigger()` opens the parameter form when the caller passes no `ctx.params` and the snippet declares any; an explicit `ctx.params` table (even `{}`) skips the form for programmatic callers.
- nvim-cmp completion source (`lua/snipai/sources/cmp.lua`): prefix-based matching against the registry, `[AI]` menu tag, and `execute()` delegating to `snipai.trigger`. `insertText` re-inserts the typed prefix on confirm so the buffer stays visually stable while the param form collects values; `trigger()` swaps that range for the rendered `insert` template on submit. `require("snipai.sources.cmp").register()` installs the source under name `"snipai"`; idempotent and a no-op when cmp is not installed.
- Optional `filetype` field on snippets — single string (`"lua"`) or non-empty array (`["lua","luau"]`). Missing is backward-compatible "any buffer". Enforced at the cmp source via `Snippet:matches_filetype(ft)`; non-matching snippets are silently dropped from completion.
- Optional `insert` field on snippets — a template rendered at trigger time and placed at the cursor (replacing the cmp-typed prefix) before the Claude run, with a silent `:write` so Claude has an on-disk scaffold to enrich. Snippets without `insert` keep the "run body only" behaviour.
- Reserved built-in placeholders available inside `insert` and `body`: `{{cursor_file}}`, `{{cursor_line}}`, `{{cursor_col}}`, `{{cwd}}`. Auto-populated at trigger time from the buffer/window state; declaring any reserved name in `parameter` is rejected at load time.
- Buffer refresh after job completion: `snipai.setup()` subscribes to `job_done` and runs `:checktime` on every loaded buffer whose file appears in the job's `files_changed` list, so Claude's in-place edits reload without manual `:e!`. Extracted into `lua/snipai/buffer_refresh.lua` with an `attach(events, refresh_fn?)` helper that mirrors `statusline.attach` and keeps `init.lua` free of `:checktime` plumbing.
- History → quickfix: `history:to_quickfix(id)` and the `snipai.history.to_quickfix(id)` facade push the entry's `files_changed` into the quickfix list with one item per path (lnum=1 since Claude's Edit events don't carry line numbers) and a `snipai: <snippet>` title so multiple runs stay visually distinguishable. The `setqflist` dependency is injected so the behaviour is fully unit-testable without touching Neovim's qf state.
- Detail popup (`lua/snipai/ui/detail.lua`): floating window over a read-only scratch buffer (markdown filetype, centered, rounded border) rendering a finalized or pending history row — status badge with duration + exit code, timestamps, parameters sorted by key, files-changed bullets, rendered prompt with preserved newlines, and a stderr section reserved for failed runs. Renderer is a pure function (`M.render(entry) -> { lines, title }`) split from the window wrapper so formatting is fully unit-tested.
- Telescope pickers (`lua/snipai/pickers/*`):
  - `pickers.running` — active-job picker. Row: name, status badge, elapsed duration, short id, triggering file basename. `<CR>` opens the detail popup for the job's history entry; `<C-c>` cancels. Point-in-time snapshot for v0.1.0; live refresh ships in v0.2.0.
  - `pickers.history` — history picker with `project` (default) or `all` scope. Row: status glyph (`+` / `x` / `~` / `…`), HH:MM:SS, name, duration, file count, short id. Sorted newest-first. `<CR>` opens detail; `<C-q>` pushes the entry's `files_changed` into the quickfix list and reports the count. Replay (`<C-r>`) and delete (`<C-d>`) are scoped to v0.2.0.
  - Both pickers soft-fail (notify + return) when Telescope isn't installed or the input list is empty; `opts.telescope = false` sentinel forces the "absent" path for tests.
- Full `:Snipai*` user command set in `plugin/snipai.lua`: `:SnipaiRunning`, `:SnipaiHistory [project|all]`, `:SnipaiDetail <id>`, `:SnipaiToQuickfix <id>`, `:SnipaiCancel <id>`, `:SnipaiReload` join the existing `:SnipaiTrigger <name>`. Each dispatches through a shared `get_state()` guard that warns cleanly when `setup()` hasn't run. Id-based commands autocomplete against `history:list{scope="all"}` or `jobs:list()`; scope completion for `:SnipaiHistory` returns `{"project", "all"}`.
- Default global keymaps (`lua/snipai/keymaps.lua`): `<leader>sr` / `<leader>sh` / `<leader>sH` installed from `setup()` via `keymaps.apply(spec, opts)`. `setup({ keymaps = false })` skips everything, `setup({ keymaps = { running = false } })` disables a single entry, `spec[key] = "<C-s>"` overrides the lhs. `opts.keymap_set` is the test seam.
- Full project documentation: `README.md`, `doc/snipai.txt` (vimdoc), `ARCHITECTURE.md`, `CONTRIBUTING.md`, this changelog.

### Changed
- `init.lua` is now strictly compositional: the Neovim-side trigger defaults (`default_gather_builtins`, `default_place_insert`, `default_save_buffer`) moved into `lua/snipai/trigger.lua` where they are actually used, and the `job_done → :checktime` subscription moved into `lua/snipai/buffer_refresh.lua` behind `attach(events, refresh_fn?)`. Shrinks `init.lua` from ~294 lines back to ~228 and removes every direct `vim.api.*` call from the top-level module. No public API change.
- Dropped the hard dependency on `nvchad/volt` in favour of `vim.ui.input` / `vim.ui.select`; users get popup-style prompts automatically when any `dressing.nvim` / `snacks.nvim` / `telescope-ui-select.nvim` override is installed.
- **BREAKING** (pre-1.0): default snippet location moved from `~/.config/nvim/snipai/snippets.json` to `~/.config/snipai/snippets.json`; default history location moved from `~/.local/share/nvim/snipai/history.jsonl` to `~/.local/share/snipai/history.jsonl`. Snipai now owns its own XDG directories instead of nesting under the Neovim config/data trees. `config.lua` no longer probes `vim.fn.stdpath()` — path resolution is pure XDG (env overrides → `$XDG_{CONFIG,DATA}_HOME` → `$HOME/.config` / `$HOME/.local/share`). Users who relied on the old paths can either `mv` their files or set `config_paths` / `history.path` explicitly in `setup({...})`.
- Default `claude.extra_args` is now `{ "--permission-mode", "acceptEdits", "--setting-sources", "" }` (previously empty). `--permission-mode acceptEdits` prevents non-interactive `claude -p` from silently skipping Edit / Write / MultiEdit tools (there is nobody to approve them otherwise). `--setting-sources ""` loads no settings sources for the invocation, suppressing user-installed Claude Code plugins (superpowers, etc.) and their SessionStart hooks for the run — measurably ~2–3× faster on typical snippet workloads because the plugin bootstrap injects 12k+ tokens of context into every non-interactive session. Interactive `claude` sessions are unaffected. Keychain auth, memory, CLAUDE.md discovery, and MCP servers continue to work. Override via `setup({ claude = { extra_args = {...} } })` — the field is a nested array so user values REPLACE the default outright.

### Fixed
- _(nothing yet)_

### Deprecated
- _(nothing yet)_

### Removed
- _(nothing yet)_

### Security
- _(nothing yet)_

---

## Planned releases

These are commitments to *scope*, not release dates. Items may move between milestones as the design stabilizes.

### v0.1.0-alpha — first usable build

Target: MVP that a real user can drive end-to-end for the first time. All items below are merged on `main` and ready to tag.

- [x] Core primitives: `config`, `params`, `snippet`, `registry`, `claude/parser`, `history/store`, `notify`.
- [x] Execution plumbing: `claude/runner`, `jobs/*`, `history/init`, `:SnipaiTrigger <name>`.
- [x] `nvim-cmp` source that lists AI snippets by prefix (`require("snipai.sources.cmp").register()`).
- [x] Parameter popup over `vim.ui.input` / `vim.ui.select` with `string` / `text` / `select` / `boolean` types, submit-time validation, notifier-surfaced errors.
- [x] Per-project history persisted to disk (`stdpath("data")/snipai/history.jsonl`).
- [x] Notification backend auto-detect (`nvim-notify` / `fidget.nvim` / `vim.notify`).

### v0.1.0 — first stable release (Phase 4 exit)

Target: installable, documented, ready for external users.

- [x] Telescope picker of active jobs (`:SnipaiRunning`).
- [x] Telescope picker of history with `project` / `all` scopes (`:SnipaiHistory`).
- [x] History entry detail popup (`:SnipaiDetail`).
- [x] `files_changed → quickfix` action (`:SnipaiToQuickfix`, `<C-q>` in picker).
- [x] All default user commands: `:SnipaiRunning`, `:SnipaiHistory`, `:SnipaiDetail`, `:SnipaiToQuickfix`, `:SnipaiCancel`, `:SnipaiReload`, `:SnipaiTrigger`.
- [x] Default keymaps (`<leader>sr`, `<leader>sh`, `<leader>sH`, picker-local actions).
- [ ] `:checkhealth snipai` reporting dependency status.
- [x] `:help snipai` with full vimdoc tags.
- [ ] README polished with screenshots / GIFs.
- [ ] CI matrix: nvim 0.10 stable + nightly on Ubuntu and macOS.

### v0.2.0 — session-terminal backend

- [x] PTY-hosted `claude` session per snippet; `--session-id <uuid>` + `--name <snippet>`.
- [x] JSONL-tailer-fed event model; `files_changed` / quickfix preserved across the backend swap.
- [x] 5-state job lifecycle (`running / idle / complete / cancelled / error`).
- [x] Tabbed detail popup (`<Tab>` / `<S-Tab>` swaps Summary ↔ Terminal).
- [x] 5-state glyphs in the running and history pickers.
- [x] `:SnipaiCancel <id>` via `vim.fn.jobstop` (SIGTERM → SIGKILL).
- [x] `VimLeavePre` soft-stop for active sessions.
- [x] Mid-session `:checktime` — each new file a long session touches refreshes in open buffers the moment it first appears.
- [ ] Manual smoke pass on macOS and Ubuntu against a real `claude` CLI.

### v0.3.0 — second adapter and polish

- [ ] `blink.cmp` source adapter (parallel to the existing `nvim-cmp` source, from a shared core).
- [ ] Live-refresh Telescope pickers (`:SnipaiRunning` / `:SnipaiHistory` subscribe to the event bus so rows transition in place as jobs complete; currently a point-in-time snapshot at open).
- [ ] Replay from history (`<C-r>` in the Telescope history picker re-runs with original parameters; `claude --resume <uuid>` when the session-id is known).
- [ ] Delete from history (`<C-d>` in the Telescope history picker removes the entry from the JSONL).
- [ ] Notification heartbeat for hidden sessions (running-count summary so users who never open the terminal still see liveness).
- [ ] `:SnipaiCancel <id>` wired to a keymap inside the running picker.
- [ ] Configurable concurrency limits (`max_concurrent` sessions).
- [ ] Stress test: five concurrent sessions without state corruption.

---

## Roadmap (unscheduled)

Tracked here for visibility; no implementation order committed.

### Snippet authoring
- Lua-config entry point (`setup({ snippets = { ... } })`) as an alternative to JSON.
- Filetype scoping so unrelated snippets don't pollute `cmp` in every buffer.
- Snippet groups / namespaces.
- Importers for existing snippet libraries (VSCode, UltiSnips-style).

### UX
- Diff view showing file changes inline before accepting them.
- Dry-run mode that parses the prompt without actually spawning Claude.
- Live token / cost meter in the progress notification.
- Inline ghost-text preview for text-only snippets (no tool use).

### Backends
- Direct Anthropic API backend for text-only snippets (skipping the CLI when the tool loop isn't needed).
- Per-snippet backend selection (`backend: "cli" | "api"` in JSON schema).
- Support for local / self-hosted models via existing tools.

### Integrations
- `fzf-lua` picker backend in parallel to Telescope.
- `snacks.nvim` picker backend.
- `Trouble.nvim` integration as an alternative to quickfix.
- `which-key` registration for default keymaps.

### Collaboration
- Shared team snippet repos (git URL → auto-pull into `config_paths`).
- Snippet import / export (single-file bundles).

### Observability
- Per-project cost dashboard (uses aggregate token usage from history).
- Tag-based history filtering (user-defined tags on snippets).
- Usage analytics (most-run snippets, average durations, failure rates).

### Safety
- Per-snippet allowlist of Claude tools (`tools: ["Edit", "Read"]`).
- Confirmation gate before destructive operations (Bash with `rm`, force-push, etc.).
- Sandboxed working-directory option (run the snippet inside a temporary workspace).

---

[Unreleased]: https://github.com/louishuyng/snipai/compare/HEAD...HEAD
