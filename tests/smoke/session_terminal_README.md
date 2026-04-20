# Session-terminal smoke test

Requires a working `claude` CLI with credentials. Unit tests fake both the PTY
and the filesystem; this checklist exercises the real seam between Neovim's
terminal buffer and Claude Code's on-disk transcript writer.

Run every item before tagging **v0.2.0**. All nine must pass on macOS and
Ubuntu.

1. `nvim` in a scratch repo. Create a tiny `~/.config/snipai/snippets.json`
   with one snippet; run `:SnipaiTrigger <name>`.
2. `<leader>sr` → picker shows exactly one row with glyph `…` (running).
3. `<CR>` on the row → tabbed detail popup opens on Summary; `<Tab>` → Terminal
   tab shows the live PTY. The glyph in the running picker (re-open with
   `<leader>sr`) flips from `…` to `◦` (idle) after Claude finishes its turn.
4. In Terminal-Insert mode, send a follow-up: `please add a docstring to that
   function`. A new turn streams in the transcript; glyph cycles `◦ → … → ◦`.
5. Close the window without `/exit`. Back to the base buffer. Fire the snippet
   a second time — a NEW row appears in the running picker, old row still
   present. Two concurrent sessions both listed with their own glyphs.
6. `<leader>sh` → both sessions visible. `<CR>` on either opens the tabbed
   detail popup. `<Tab>` swaps cleanly; the live transcript is visible; no
   flicker.
7. `:SnipaiCancel <short-id-of-the-first>` → glyph flips to `✗` (cancelled).
   `files_changed` captured before the kill are preserved in the detail's
   Summary tab.
8. In the second session's terminal, type `/exit` → glyph flips to `✓`
   (complete).
9. `:q` Neovim with both sessions at rest. Outside Neovim, `pgrep claude`
   returns nothing — the `VimLeavePre` autocmd cleaned up.

Done. If step 3's glyph does NOT transition to `◦` after Claude finishes a
turn, the jsonl tailer's 250ms poll is probably missing a file-growth event
— bump `DEFAULT_POLL_MS` in `lua/snipai/claude/session_tailer.lua` or verify
`vim.uv.fs_poll` callbacks are firing on your platform.
