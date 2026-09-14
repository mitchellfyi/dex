#!/usr/bin/env bash
# Missing conversations retry once; other provider exits retain their status.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-provider-session-recovery.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/home"

cat > "$TMP_DIR/scenario.sh" <<'SH'
set -eu
source "$DEX_DIR/lib/common.sh"
__dx_claude() {
  local invocation=1
  [[ ! -f "$TEST_RECORD.count" ]] || invocation=$(($(cat "$TEST_RECORD.count") + 1))
  printf '%s\n' "$invocation" > "$TEST_RECORD.count"
  printf '%s\n' "$@" > "$TEST_RECORD.args.$invocation"
  printf '%s\n' "$DEX_SESSION_ID" "$DEX_LOOP_PHASE" "$PWD" > "$TEST_RECORD.context.$invocation"
  printf 'provider stdout %s\n' "$invocation"
  if [[ "$invocation" -eq 1 ]]; then
    # Include terminal colour and an unterminated final line.
    printf '\033[31m%s\033[0m' "$TEST_DIAGNOSTIC" >&2
    return "$TEST_FIRST_EXIT"
  fi
  printf '%s\n' "$TEST_DIAGNOSTIC" >&2
  return "$TEST_SECOND_EXIT"
}
dx_provider_run_session "ticket-3119" "$TEST_RESUMING" "$TEST_HANDLE" \
  --model "test-model" --append-system-prompt-file "phase-context.md" \
  "Continue the saved phase."
SH

run_case() {
  local case_name="$1" engine="$2" resuming="$3" handle="$4"
  local first_exit="$5" diagnostic="$6" second_exit="${7:-0}"
  CASE_RECORD="$TMP_DIR/${TEST_SHELL}-${case_name}"
  CASE_RESULT=0
  env HOME="$TMP_DIR/home" ZDOTDIR="$TMP_DIR/home" DEX_DIR="$ROOT" TMPDIR="$TMP_DIR" \
    DX_STATE_DIR="$TMP_DIR/state" DX_LOOP_DIR="$TMP_DIR/loops" \
    DEX_SESSION_ID=recovery-test DEX_LOOP_PHASE=1 DX_PROVIDER_ENGINE="$engine" \
    TEST_RECORD="$CASE_RECORD" TEST_RESUMING="$resuming" TEST_HANDLE="$handle" \
    TEST_FIRST_EXIT="$first_exit" TEST_SECOND_EXIT="$second_exit" \
    TEST_DIAGNOSTIC="$diagnostic" \
    "$TEST_SHELL" "$TMP_DIR/scenario.sh" > "$CASE_RECORD.out" 2> "$CASE_RECORD.err" \
    || CASE_RESULT=$?
  if compgen -G "$TMP_DIR/dx-provider-resume.*" >/dev/null; then
    cat "$CASE_RECORD.err" >&2
    fail "provider recovery left temporary state behind ($TEST_SHELL/$case_name)"
  fi
}

CLAUDE_DIAGNOSTIC="No conversation found with session ID: saved-conversation"
CODEX_DIAGNOSTIC='No saved session found with ID saved-conversation. Run `codex resume` without an ID to choose from existing sessions.'
for TEST_SHELL in bash zsh; do
  for engine in claude anthropic-gateway ccr codex-plugin; do
    diagnostic="$CLAUDE_DIAGNOSTIC"
    [[ "$engine" != codex-plugin ]] || diagnostic="$CODEX_DIAGNOSTIC"
    run_case "missing-$engine" "$engine" 1 saved-conversation 1 "$diagnostic"
    assert_eq 0 "$CASE_RESULT" "fresh launch result ($TEST_SHELL/$engine)"
    assert_eq 2 "$(cat "$CASE_RECORD.count")" "one retry ($TEST_SHELL/$engine)"
    assert_contains --resume "$CASE_RECORD.args.1"
    assert_contains saved-conversation "$CASE_RECORD.args.1"
    assert_not_contains --resume "$CASE_RECORD.args.2"
    assert_not_contains --continue "$CASE_RECORD.args.2"
    assert_not_contains saved-conversation "$CASE_RECORD.args.2"
    assert_contains ticket-3119 "$CASE_RECORD.args.2"
    assert_contains test-model "$CASE_RECORD.args.2"
    assert_contains phase-context.md "$CASE_RECORD.args.2"
    assert_contains "Continue the saved phase." "$CASE_RECORD.args.2"
    cmp "$CASE_RECORD.context.1" "$CASE_RECORD.context.2"
    assert_contains "provider stdout 1" "$CASE_RECORD.out"
    assert_contains "provider stdout 2" "$CASE_RECORD.out"
    assert_contains "$diagnostic" "$CASE_RECORD.err"
    assert_not_contains "provider stdout" "$CASE_RECORD.err"
    assert_contains "starting a new conversation at the current Dex phase" "$CASE_RECORD.err"
  done

  run_case legacy-claude claude 1 "" 1 "No conversation found with session ID: ticket-3119"
  assert_eq 0 "$CASE_RESULT" "legacy Claude recovery"
  assert_eq 2 "$(cat "$CASE_RECORD.count")" "legacy Claude retry"

  run_case legacy-codex codex-plugin 1 "" 0 ""
  assert_eq 0 "$CASE_RESULT" "legacy Codex success"
  assert_eq 1 "$(cat "$CASE_RECORD.count")" "legacy Codex not retried"
  assert_contains --continue "$CASE_RECORD.args.1"

  for first_exit in 0 2 130 143; do
    run_case "exit-$first_exit" claude 1 saved-conversation "$first_exit" "$CLAUDE_DIAGNOSTIC"
    assert_eq "$first_exit" "$CASE_RESULT" "provider exit preserved"
    assert_eq 1 "$(cat "$CASE_RECORD.count")" "non-lookup exit not retried"
  done
  for diagnostic in "Authentication failed" "No conversation found with session ID: unrelated-conversation"; do
    run_case unrelated-error claude 1 saved-conversation 1 "$diagnostic"
    assert_eq 1 "$CASE_RESULT" "unrelated error preserved"
    assert_eq 1 "$(cat "$CASE_RECORD.count")" "unrelated error not retried"
    rm "$CASE_RECORD.count"
  done

  run_case fresh-failure claude 0 "" 1 "$CLAUDE_DIAGNOSTIC"
  assert_eq 1 "$CASE_RESULT" "new launch error preserved"
  assert_eq 1 "$(cat "$CASE_RECORD.count")" "new launch not retried"

  run_case retry-failure claude 1 saved-conversation 1 "$CLAUDE_DIAGNOSTIC" 1
  assert_eq 1 "$CASE_RESULT" "retry error preserved"
  assert_eq 2 "$(cat "$CASE_RECORD.count")" "retry limited to one attempt"
done

python3 - "$ROOT" "$TMP_DIR" <<'PY'
import os
import pty
import subprocess
import sys

root, temporary = sys.argv[1:]
script = r'''
source "$DEX_DIR/lib/common.sh"
__dx_claude() {
  [[ -t 0 && -t 1 ]] || return 90
  if [[ "$1" == --resume ]]; then
    printf '%s\n' 'No conversation found with session ID: saved-conversation' >&2
    return 1
  fi
  return 0
}
dx_provider_run_session ticket-3119 1 saved-conversation prompt
'''
for shell in ("bash", "zsh"):
    master, slave = pty.openpty()
    try:
        result = subprocess.run(
            [shell, "-c", script], stdin=slave, stdout=slave,
            stderr=subprocess.PIPE, timeout=15,
            env={**os.environ, "DEX_DIR": root, "TMPDIR": temporary,
                 "HOME": temporary + "/home", "ZDOTDIR": temporary + "/home",
                 "DX_PROVIDER_ENGINE": "claude"},
        )
        assert result.returncode == 0, (shell, result.returncode, result.stderr)
        assert b"starting a new conversation" in result.stderr, (shell, result.stderr)
    finally:
        os.close(master)
        os.close(slave)
PY

if compgen -G "$TMP_DIR/dx-provider-resume.*" >/dev/null; then
  fail "provider recovery left temporary state behind"
fi
printf '%s\n' "provider session recovery tests passed"
