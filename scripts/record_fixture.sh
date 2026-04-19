#!/usr/bin/env bash
# Record a Claude Code stream-json fixture for the snipai test suite.
#
# Usage:
#   scripts/record_fixture.sh "<prompt>" > tests/fixtures/claude/<name>.jsonl
#
# Notes:
#   * Runs Claude Code with --output-format stream-json --verbose so the
#     captured bytes are exactly what the plugin parses at runtime.
#   * The prompt is passed verbatim; quote it to preserve whitespace.
#   * An optional leading `# comment` line documenting the scenario is a
#     documented convention — prepend it manually after recording.
#   * Run this in a throwaway directory. The prompt executes for real —
#     any Edit/Write/Bash tool calls will actually touch the filesystem.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  cat >&2 <<USAGE
usage: $0 "<prompt>" > tests/fixtures/claude/<name>.jsonl

Records Claude Code's --output-format stream-json output for the given
prompt, for use as a unit-test fixture. Run from a throwaway workdir.
USAGE
  exit 2
fi

if ! command -v claude >/dev/null 2>&1; then
  echo "error: 'claude' CLI not found on PATH" >&2
  exit 1
fi

exec claude -p "$1" --output-format stream-json --verbose --permission-mode acceptEdits
