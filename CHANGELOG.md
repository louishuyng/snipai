# Changelog

All notable changes to `snipai` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added
- Initial project scaffolding: `Makefile`, `stylua.toml`, `.luarc.json`, `.editorconfig`, `.gitignore`, `.busted`, `tests/minimal_init.lua`.
- Pub/sub event bus (`lua/snipai/events.lua`) with factory-based buses so each job can own its own bus without shared global state.
- Full project documentation: `README.md`, `doc/snipai.txt` (vimdoc), `ARCHITECTURE.md`, `CONTRIBUTING.md`, this changelog.

### Changed
- _(nothing yet)_

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

### v0.1.0-alpha — first usable build (Phase 3 exit)

Target: MVP that a real user can drive end-to-end for the first time.

- [ ] Core primitives: `config`, `params`, `snippet`, `registry`, `claude/parser`, `history/store`, `notify` (Phase 1).
- [ ] Execution plumbing: `claude/runner`, `jobs/*`, `history/init`, `:SnipaiTrigger <name>` (Phase 2).
- [ ] `nvim-cmp` source that lists AI snippets by prefix.
- [ ] Volt-based parameter popup with `string` / `text` / `select` / `boolean` types, per-field validation, submit-gated.
- [ ] Per-project history persisted to disk (`stdpath("data")/snipai/history.jsonl`).
- [ ] Notification backend auto-detect (`nvim-notify` / `fidget.nvim` / `vim.notify`).

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
