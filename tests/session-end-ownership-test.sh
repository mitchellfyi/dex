#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-session-end-ownership-test.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DEX_SESSION_ID="session-end-owner-test"
mkdir -p "$DX_STATE_DIR" "$DX_LOOP_DIR"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

TIMES_FILE=$(dx_times_file "$DEX_SESSION_ID")
CTX_FILE=$(dx_context_file "$DEX_SESSION_ID")
OWNER_FILE=$(dx_owner_file "$DEX_SESSION_ID")

printf '0:100\n' > "$TIMES_FILE"
printf 'context\n' > "$CTX_FILE"
printf 'claude-owner\n' > "$OWNER_FILE"

printf '%s\n' '{"session_id":"claude-bystander"}' | bash "$ROOT/hooks/session-end.sh"
[[ -f "$CTX_FILE" ]] || assert_at $LINENO
[[ $(wc -l < "$TIMES_FILE") -eq 1 ]] || assert_at $LINENO

printf '%s\n' 'not-json' | bash "$ROOT/hooks/session-end.sh"
[[ -f "$CTX_FILE" ]] || assert_at $LINENO
[[ $(wc -l < "$TIMES_FILE") -eq 1 ]] || assert_at $LINENO

printf '%s\n' '{"session_id":"claude-owner"}' | bash "$ROOT/hooks/session-end.sh"
[[ ! -f "$CTX_FILE" ]] || assert_at $LINENO
[[ $(wc -l < "$TIMES_FILE") -eq 2 ]] || assert_at $LINENO
grep -q '^end:[0-9][0-9]*$' "$TIMES_FILE"

printf 'session end ownership tests passed\n'
