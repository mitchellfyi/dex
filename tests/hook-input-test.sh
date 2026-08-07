#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-hook-input-test.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DEX_SESSION_ID="hook-input-test"
export DEX_LOOP_PHASE=6
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

PAUSE_FILE=$(dx_watch_pause_file "$DEX_SESSION_ID")
printf 'paused\n' > "$PAUSE_FILE"

printf '%s\n' '{"prompt":"Please resume watcher monitoring."}' \
  | bash "$ROOT/hooks/user-prompt-submit.sh" > "$TMP_DIR/resume.out"
[[ ! -f "$PAUSE_FILE" ]]
grep -q 'resumed scheduled Phase 6 watcher loops' "$TMP_DIR/resume.out"

printf 'paused\n' > "$PAUSE_FILE"
printf '%s\n' '{"prompt":"Do not resume watcher monitoring."}' \
  | bash "$ROOT/hooks/user-prompt-submit.sh" > "$TMP_DIR/negated.out"
[[ -f "$PAUSE_FILE" ]]
grep -q 'paused the scheduled PR watcher loop' "$TMP_DIR/negated.out"

printf '%s\n' '{"prompt":"Please do not run /dxcomplete yet."}' \
  | bash "$ROOT/hooks/user-prompt-submit.sh" > "$TMP_DIR/negated-command.out"
[[ -f "$PAUSE_FILE" ]]
grep -q 'paused the scheduled PR watcher loop' "$TMP_DIR/negated-command.out"

REPO="$TMP_DIR/repo"
git init -q "$REPO"
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name Test
git -C "$REPO" commit --allow-empty -qm init
git -C "$REPO" checkout -qb ticket-12-ticket-34

(
  cd "$REPO"
  DEX_SESSION_ID="ticket-hook-test" bash "$ROOT/hooks/load-ticket-context.sh"
) > "$TMP_DIR/ticket.out"

grep -q '^Ticket number: 12$' "$TMP_DIR/ticket.out"
if grep -q '^34$' "$TMP_DIR/ticket.out"; then
  printf 'ticket hook emitted more than one ticket number\n' >&2
  exit 1
fi

printf 'hook input tests passed\n'
