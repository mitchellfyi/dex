#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
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

CAPTURE_SID="provider-session-capture"
CLAUDE_HANDLE="01999999-1111-4222-8333-444444444444"
CODEX_HANDLE="01999999-aaaa-4bbb-8ccc-dddddddddddd"
printf '%s\n' \
  "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"$CLAUDE_HANDLE\"}" \
  | DEX_SESSION_ID="$CAPTURE_SID" DX_PROVIDER_ENGINE=claude \
    bash "$ROOT/hooks/capture-provider-session.sh"
assert_eq "$CLAUDE_HANDLE" \
  "$(dx_agent_session_handle_read "$CAPTURE_SID" claude)" \
  "captured Claude session ID"
assert_eq "600" \
  "$(dx_path_mode "$(dx_agent_session_handle_file "$CAPTURE_SID" claude)")" \
  "Claude session ID permissions"

printf '%s\n' \
  "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"$CODEX_HANDLE\"}" \
  | DEX_SESSION_ID="$CAPTURE_SID" DX_PROVIDER_ENGINE=codex-plugin \
    bash "$ROOT/hooks/capture-provider-session.sh"
assert_eq "$CODEX_HANDLE" \
  "$(dx_agent_session_handle_read "$CAPTURE_SID" codex)" \
  "captured Codex session ID"

INVALID_CAPTURE_SID="provider-session-invalid"
printf '%s\n' '{"hook_event_name":"Stop","session_id":"../unsafe"}' \
  | DEX_SESSION_ID="$INVALID_CAPTURE_SID" DX_PROVIDER_ENGINE=claude \
    bash "$ROOT/hooks/capture-provider-session.sh"
assert_no_file "$(dx_agent_session_handle_file "$INVALID_CAPTURE_SID" claude)"

PAUSE_FILE=$(dx_watch_pause_file "$DEX_SESSION_ID")
printf 'paused\n' > "$PAUSE_FILE"

printf '%s\n' '{"prompt":"Please resume watcher monitoring."}' \
  | bash "$ROOT/hooks/user-prompt-submit.sh" > "$TMP_DIR/resume.out"
[[ ! -f "$PAUSE_FILE" ]] || assert_at $LINENO
grep -q 'resumed scheduled Phase 6 watcher loops' "$TMP_DIR/resume.out"

printf 'paused\n' > "$PAUSE_FILE"
printf '%s\n' '{"prompt":"Do not resume watcher monitoring."}' \
  | bash "$ROOT/hooks/user-prompt-submit.sh" > "$TMP_DIR/negated.out"
[[ -f "$PAUSE_FILE" ]] || assert_at $LINENO
grep -q 'paused the scheduled PR watcher loop' "$TMP_DIR/negated.out"

printf '%s\n' '{"prompt":"Please do not run /dxcomplete yet."}' \
  | bash "$ROOT/hooks/user-prompt-submit.sh" > "$TMP_DIR/negated-command.out"
[[ -f "$PAUSE_FILE" ]] || assert_at $LINENO
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
