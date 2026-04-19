# Contributing to snipai

Thanks for considering a contribution! This file is the short version; read `ARCHITECTURE.md` first if you're changing anything bigger than a typo.

## Table of contents

1. [Ways to contribute](#ways-to-contribute)
2. [Getting set up](#getting-set-up)
3. [The dev loop](#the-dev-loop)
4. [Testing tiers](#testing-tiers)
5. [Recording a new Claude fixture](#recording-a-new-claude-fixture)
6. [Code style](#code-style)
7. [Commit messages](#commit-messages)
8. [Pull request checklist](#pull-request-checklist)
9. [Filing bugs](#filing-bugs)
10. [Proposing features](#proposing-features)

---

## Ways to contribute

- **Bug reports** with a minimal reproducer (see [Filing bugs](#filing-bugs)).
- **Docs fixes** — typos, unclear sections, outdated examples in `README.md`, `ARCHITECTURE.md`, or `doc/snipai.txt`.
- **Snippet recipes** for common languages — submit to a future `snippets/examples/` directory (planned for `v0.1.0`).
- **New picker backends** (fzf-lua, snacks.nvim) — follow the extension recipe in `ARCHITECTURE.md`.
- **New param types** or **new Claude backends** — also documented as extension points in `ARCHITECTURE.md`.
- **Test fixtures** recorded from real `claude` CLI output.

Please **open an issue before starting a large PR** so we can agree on scope first.

---

## Getting set up

Prerequisites:

- Neovim 0.10 or newer
- Lua 5.1+ (LuaJIT is fine; used in nvim-headless tests)
- Lua 5.4 and `luarocks` (optional; for running standalone `busted` on pure-Lua modules)
- `git`, `make`
- `stylua` on `$PATH` (`brew install stylua` on macOS)
- `claude` CLI on `$PATH` — only required for release smoke tests and fixture recording. Day-to-day dev never calls the real CLI (fake runner in tests).

Clone and install test deps:

```bash
git clone https://github.com/louishuyng/snipai
cd snipai
make deps   # clones plenary.nvim into .deps/
```

Optional: install standalone busted for the fastest inner loop on pure-Lua modules:

```bash
luarocks install --local busted
# add ~/.luarocks/bin to PATH, e.g. for fish:
fish_add_path ~/.luarocks/bin
```

Verify everything works:

```bash
make test        # full suite via plenary in headless nvim
make test-unit   # unit-only subset (fastest plenary path)
busted tests/unit/events_spec.lua  # single-file standalone (needs local busted)
```

All three should exit 0.

---

## The dev loop

1. **Branch:** `git switch -c <scope>/<short-description>` (e.g. `feat/filetype-scoping`, `fix/parser-escaped-quotes`, `docs/readme-install`).
2. **Write the test first.** Add a spec under `tests/unit/` (or `integration/`) that fails for the right reason.
3. **Implement the change.** Keep modules small; respect the dependency rules in `ARCHITECTURE.md` (core may not require UI or pickers).
4. **Run `make format`** before committing. CI runs `make format-check` and will fail on unformatted code.
5. **Run the relevant test tier** (see [Testing tiers](#testing-tiers)).
6. **Commit with a clear message** (see [Commit messages](#commit-messages)).
7. **Push and open a PR** — the template will prompt for the checklist.

Prefer **small, focused PRs**. Refactors-plus-features bundled together are harder to review and easier to revert badly.

---

## Testing tiers

There are four tiers. Pick the lowest one that exercises your change, add a test there, and only climb higher if a downstream module changes observably.

| Tier | Where | How to run | When to use |
|---|---|---|---|
| **Unit** | `tests/unit/**/*_spec.lua` | `make test-unit` OR `busted tests/unit/foo_spec.lua` | any pure-Lua module: `events`, `params`, `snippet`, `registry`, `config`, `claude.parser`, `history.store`. No Neovim APIs. |
| **Integration** | `tests/integration/**/*_spec.lua` | `make test` | jobs lifecycle, history wiring, cmp source behavior. Uses fake runner replaying `tests/fixtures/claude/*.jsonl`. |
| **UI smoke** | `tests/ui/**/*_spec.lua` | `make test` | popup opens with the right fields; picker lists expected entries. Verifies boolean presence, not pixels. |
| **Manual smoke** | `scripts/smoke.sh` (planned) | run before tagging a release | real `claude` CLI end-to-end. Catches CLI format drift. |

**Rules:**

- **Fake runner, not real Claude.** In every `integration/` test, swap `require("snipai.claude.runner").spawn` for `tests/helpers/fake_runner.lua`. Never shell out to the real CLI from the test suite.
- **Fixtures come from the real CLI.** Handwritten fixtures drift; use `scripts/record_fixture.sh` (see below).
- **UI tests stay smoke-only.** Verify values round-trip and popups open; don't assert exact screen content or highlight groups.
- **`tests/unit/` has zero plugin deps.** A new contributor should be able to run any single unit spec via `busted` without any Neovim process.

Coverage target: **80%+ on `lua/snipai/`**, excluding `ui/` and `pickers/` (which are exercised by smoke tests, not line coverage).

---

## Recording a new Claude fixture

When Claude Code's `stream-json` format changes (or you add a new test case), regenerate a fixture instead of handwriting one:

```bash
scripts/record_fixture.sh "<prompt to run>" > tests/fixtures/claude/<name>.jsonl
```

The script runs:

```bash
claude -p "$PROMPT" --output-format stream-json --verbose
```

and pipes the raw NDJSON into a fixture file. Guidelines:

- **Pick realistic prompts.** One real Edit beats ten synthetic ones.
- **Keep fixtures small.** Strip boring middle events if the test doesn't need them, but keep start/end boundaries intact.
- **Name deliberately.** `success_multi.jsonl` is better than `test1.jsonl`.
- **Document the scenario** in the fixture's first line as a `# comment` (our parser tolerates and skips leading `#` lines in fixtures).
- **Commit fixtures, not transcripts.** The fixture is the event stream; no terminal recordings.

If your test needs an error scenario the real CLI won't produce on demand (e.g. a mid-stream parse error), handcraft *minimal* edits to an existing real fixture and call it out in a comment at the top.

---

## Code style

- Formatter: **stylua**, config in `stylua.toml` (100 col, 2-space indent, `AutoPreferDouble`, `call_parentheses = "Always"`).
- Linter: **luacheck** if installed, otherwise just stylua's format check. Neither is required to pass, but `stylua --check` is.
- Language server: `.luarc.json` sets up lua-language-server with Neovim globals and busted globals preconfigured.

Run:

```bash
make format         # format all lua/ and tests/
make format-check   # dry run, non-zero exit on issues
make lint           # format-check + luacheck if installed
```

**Conventions that aren't enforced but matter:**

- **One module per file, one purpose per module.** If a file is doing two things, split it.
- **Public API lives in `lua/snipai/init.lua`** and is re-exported from there. Internal modules can break freely; public modules cannot between minor versions.
- **`---@class`, `---@param`, `---@return` annotations** on anything user-facing. Skip them on internal helpers unless the shape is non-obvious.
- **Comments only explain the non-obvious WHY.** Don't narrate WHAT — well-named code already does that.
- **No emoji in source files, docs, or commit messages** unless the user explicitly asks.
- **Errors:** core modules `return nil, err`. UI and adapters may `vim.notify(err, vim.log.levels.ERROR)` when surfacing to a user. The event bus `pcall`s subscribers — don't rely on that, but don't fight it.

---

## Commit messages

Short, imperative, conventional-style prefix optional:

```
feat(params): add select type with required options[]
fix(parser): handle escaped quotes in tool_use payload
docs(readme): clarify per-project override semantics
test(history): cover prune at max_entries boundary
refactor(jobs): extract progress accumulator to jobs/job.lua
chore(ci): bump nvim-nightly matrix entry
```

Rules:

- **First line ≤ 72 characters.** Body optional; wrap at 80.
- **Explain the WHY in the body**, not the what — the diff shows what.
- If an AI assistant helped, that belongs in your own process notes, not the public git history (like superpowers doc). The commit message should read as if it were written by a human who understands the change, not a transcript of an AI conversation.
- **One logical change per commit.** Refactor + feature = two commits.

---

## Pull request checklist

Before requesting review, confirm:

- [ ] Branch is rebased on the latest `main`.
- [ ] `make format-check` passes.
- [ ] `make test` passes locally on nvim 0.10+ (CI will retest on nightly).
- [ ] New behavior has a test (unit > integration > UI, lowest possible).
- [ ] Docs are updated if the public API, commands, keymaps, or event catalog changed: `README.md`, `doc/snipai.txt`, `ARCHITECTURE.md` (the event-catalog table and extension points).
- [ ] `CHANGELOG.md` has an entry under **Unreleased** (format below).
- [ ] No leftover `print`, `vim.print`, `P(...)` debug calls.
- [ ] No new runtime dependencies without discussion (open an issue first).

**CHANGELOG entry format:**

```markdown
## [Unreleased]

### Added
- Brief, user-facing description. (#PR-number)

### Changed / Fixed / Deprecated / Removed / Security
- ...
```

---

## Filing bugs

A good bug report has:

1. **Neovim version** (`nvim --version | head -1`).
2. **snipai version** (commit SHA or tag).
3. **Claude CLI version** (`claude --version`).
4. **Minimal repro:** the smallest snippet JSON + steps that reproduce the issue. A `.snipai.json` paste is ideal.
5. **Expected vs. actual** behavior.
6. **Log:** relevant lines from `:messages` and, if it's a parser issue, the `stream-json` output that broke things. Run `claude -p "<your prompt>" --output-format stream-json --verbose` and paste the offending event.
7. **Notification backend:** one of `nvim-notify`, `fidget.nvim`, or `vim.notify` — auto-detect can misreport.

Before filing, try:

- `:SnipaiReload` to rule out stale configs.
- `:checkhealth snipai` (planned for `v0.1.0`) for dependency sanity.

---

## Proposing features

- **Small:** open an issue with a one-paragraph description and a usage example.
- **Medium:** open an issue, then a draft PR that includes tests and a `README.md` / `doc/snipai.txt` update. Expect design feedback.
- **Large** (new backend, new picker, new param type): open a design proposal in the issue tracker first. Reference the extension-point recipe in `ARCHITECTURE.md`. Get a maintainer's sign-off before implementing — it's frustrating to rewrite a 500-line PR because an earlier design choice didn't fit.

**What gets rejected quickly:**

- PRs that add a runtime dependency without prior discussion.
- PRs that couple core to UI (core must stay dependency-free — see `ARCHITECTURE.md`).
- PRs that add features without tests.
- PRs that silently change the public API or event catalog.

Thanks for reading this far — excited to see what you ship.
