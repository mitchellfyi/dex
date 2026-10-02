#!/usr/bin/env bash
set -euo pipefail
umask 077
# dex-test-lane: serial
# Asserts dx_run_with_timeout completes when called from an interactive zsh on
# a real terminal. Before the nomonitor fix the backgrounded supervisor became
# a job in its own process group, zsh stopped it with SIGTTOU ("suspended (tty
# output)") even with the command's stdio redirected, and the wait never
# returned. That is the `dx <ticket>` hang at the after_create worktree hook.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"

if ! command -v expect >/dev/null 2>&1 || ! command -v zsh >/dev/null 2>&1; then
  printf 'skip: expect and zsh are both needed to drive an interactive zsh on a pty\n'
  exit 0
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-timeout-zsh-test.XXXXXX")"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

hook_log="$TMP_DIR/hook.log"
transcript="$TMP_DIR/transcript.txt"

# `zsh -i` on a pty: monitor is on, exactly as in the operator's terminal.
# DEX_DIR points at this checkout so the shell's own rc file cannot swap in
# another copy of the library. The supervised command's stdio is redirected
# away from the tty, as the worktree hook runner does, so any stop can only
# come from job control itself.
# The hermetic runner hands this test a fresh HOME. Without a .zshrc there,
# an interactive zsh runs its new-user wizard and the prompt never comes.
ZDOTDIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-zdotdir.XXXXXX")"
: > "$ZDOTDIR/.zshrc"
export ZDOTDIR

expect -c "
set timeout 30
spawn zsh -ic {export DEX_DIR=\"$ROOT\"; source \"$ROOT/dx.sh\" >/dev/null 2>&1; dx_run_with_timeout 10 env bash -c \"echo hook-ran\" </dev/null >\"$hook_log\" 2>&1; echo \"rc=\$?\"; echo DX_TEST_END; exit}
expect {
  \"DX_TEST_END\" { }
  timeout { puts \"DX_TEST_HUNG\"; exec kill -9 [exp_pid] }
  eof { }
}
" 2>&1 | tr -d '\r' > "$transcript" || true

assert_not_contains "DX_TEST_HUNG" "$transcript"
assert_not_contains "suspended" "$transcript"
assert_contains "rc=0" "$transcript"
assert_file "$hook_log"
assert_contains "hook-ran" "$hook_log"

echo "timeout interactive zsh test passed"
