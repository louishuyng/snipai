# Changelog

All notable changes to `snipai` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

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
- nvim-cmp completion source (`lua/snipai/sources/cmp.lua`): prefix-based matching against the registry, `[AI]` menu tag, `insertText=""` so the typed prefix is dropped on confirm, and `execute()` delegating to `snipai.trigger`. `require("snipai.sources.cmp").register()` installs the source under name `"snipai"`; idempotent and a no-op when cmp is not installed.
- Optional `filetype` field on snippets — single string (`"lua"`) or non-empty array (`["lua","luau"]`). Missing is backward-compatible "any buffer". Enforced at the cmp source via `Snippet:matches_filetype(ft)`; non-matching snippets are silently dropped from completion.
- Full project documentation: `README.md`, `doc/snipai.txt` (vimdoc), `ARCHITECTURE.md`, `CONTRIBUTING.md`, this changelog.

### Changed
- Dropped the hard dependency on `nvchad/volt` in favour of `vim.ui.input` / `vim.ui.select`; users get popup-style prompts automatically when any `dressing.nvim` / `snacks.nvim` / `telescope-ui-select.nvim` override is installed.
- **BREAKING** (pre-1.0): default snippet location moved from `~/.config/nvim/snipai/snippets.json` to `~/.config/snipai/snippets.json`; default history location moved from `~/.local/share/nvim/snipai/history.jsonl` to `~/.local/share/snipai/history.jsonl`. Snipai now owns its own XDG directories instead of nesting under the Neovim config/data trees. `config.lua` no longer probes `vim.fn.stdpath()` — path resolution is pure XDG (env overrides → `$XDG_{CONFIG,DATA}_HOME` → `$HOME/.config` / `$HOME/.local/share`). Users who relied on the old paths can either `mv` their files or set `config_paths` / `history.path` explicitly in `setup({...})`.
- Default `claude.extra_args` is now `{ "--permission-mode", "acceptEdits" }` (previously empty). Non-interactive `claude -p` runs under the `default` permission mode otherwise, which silently skips Edit / Write / MultiEdit tool uses because there is nobody to approve them — snippets completed "successfully" but produced no file changes. Override via `setup({ claude = { extra_args = { "--permission-mode", "plan" } } })` for a read-only dry run, or any other Claude CLI flags you want.

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

- [ ] Telescope picker of active jobs (`:SnipaiRunning`).
- [ ] Telescope picker of history with `project` / `all` scopes (`:SnipaiHistory`).
- [ ] History entry detail popup (`:SnipaiDetail`).
- [ ] `files_changed → quickfix` action (`:SnipaiToQuickfix`, `<C-q>` in picker).
- [ ] All default user commands: `:SnipaiRunning`, `:SnipaiHistory`, `:SnipaiDetail`, `:SnipaiToQuickfix`, `:SnipaiCancel`, `:SnipaiReload`, `:SnipaiTrigger`.
- [ ] Default keymaps (`<leader>sr`, `<leader>sh`, `<leader>sH`, picker-local actions).
- [ ] `:checkhealth snipai` reporting dependency status.
- [ ] `:help snipai` with full vimdoc tags.
- [ ] README polished with screenshots / GIFs.
- [ ] CI matrix: nvim 0.10 stable + nightly on Ubuntu and macOS.

### v0.2.0 — second adapter and polish (Phase 5 exit)

- [ ] `blink.cmp` source adapter (parallel to the existing `nvim-cmp` source, from a shared core).
- [ ] Streaming progress in the notification (live tool-use counter as events arrive).
- [ ] Replay from history (`<C-r>` in history picker re-runs with original parameters).
- [ ] `:SnipaiCancel <id>` wired to a keymap inside the running picker.
- [ ] Configurable concurrency limits (`max_concurrent` jobs).
- [ ] Stress test: five concurrent runs without state corruption.

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
