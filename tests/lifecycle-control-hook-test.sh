#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
HOOK="$ROOT/hooks/user-prompt-submit.sh"
HANDLER="$ROOT/hooks/guard-handler.py"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-lifecycle-control-hook.XXXXXX")"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_RUN_ROOT="$TMP_DIR/runs"
export DEX_SESSION_ID="human-control-hook"
export DEX_LOOP_ACTIVE=1
export DEX_LOOP_PHASE=3
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

payload() {
  python3 -c 'import json, sys; print(json.dumps({"prompt": sys.argv[1]}))' "$1"
}

owned_payload() {
  python3 -c 'import json, sys; print(json.dumps({"prompt": sys.argv[1], "session_id": sys.argv[2]}))' "$1" "$2"
}

guard_payload() {
  python3 -c 'import json, sys; print(json.dumps({"tool_input": {"command": sys.argv[1]}}))' "$1"
}

CONTROL_FILE=$(dx_lifecycle_control_file "$DEX_SESSION_ID")
PAUSED_FILE=$(dx_paused_file "$DEX_SESSION_ID")
OWNER_FILE=$(dx_owner_file "$DEX_SESSION_ID")
CONTROL_OWNER="claude-owner"

# A prompt cannot claim an ownerless lifecycle without a valid hook session.
payload "Stop Dex and let me take over." | bash "$HOOK" > "$TMP_DIR/stop.out"
[[ ! -e "$CONTROL_FILE" ]] || assert_at $LINENO
[[ ! -e "$OWNER_FILE" ]] || assert_at $LINENO

# A file-activated bystander cannot manufacture the missing launcher authority.
touch "$(dx_active_file "$DEX_SESSION_ID")"
printf '3:PHASE_3_COMPLETE:%s/prompts/phase-audits/3-review-loop.md:1\n' "$ROOT" \
  > "$(dx_loop_config_file "$DEX_SESSION_ID")"
owned_payload "Stop Dex." "claude-bystander" | env DEX_LOOP_ACTIVE=0 bash "$HOOK" > "$TMP_DIR/bystander.out"
[[ ! -e "$CONTROL_FILE" ]] || assert_at $LINENO
[[ ! -e "$OWNER_FILE" ]] || assert_at $LINENO

# The launcher-authorized prompt binds ownership before publishing control.
owned_payload "Please stop now." "$CONTROL_OWNER" | bash "$HOOK" > "$TMP_DIR/stop.out"
[[ "$(dx_lifecycle_control_read "$DEX_SESSION_ID" action)" == "cancel" ]] || assert_at $LINENO
[[ "$(dx_lifecycle_control_read "$DEX_SESSION_ID" source)" == "user-prompt" ]] || assert_at $LINENO
[[ -f "$PAUSED_FILE" ]] || assert_at $LINENO
[[ "$(cat "$OWNER_FILE")" == "$CONTROL_OWNER" ]] || assert_at $LINENO
grep -q "latest human request has priority" "$TMP_DIR/stop.out"
grep -q "lifecycle sequencing is disabled" "$TMP_DIR/stop.out"
grep -q "security guards remain active" "$TMP_DIR/stop.out"
grep -q "Commit, push, and PR operations are not phase-blocked" "$TMP_DIR/stop.out"

PROMPT_HASH=$(dx_lifecycle_control_read "$DEX_SESSION_ID" prompt_sha256)
[[ "$PROMPT_HASH" =~ ^[0-9a-f]{64}$ ]] || assert_at $LINENO
if grep -q "let me take over" "$CONTROL_FILE"; then
  printf 'control file retained raw prompt text\n' >&2
  exit 1
fi

set +e
GUARD_OUT=$(guard_payload "git push origin main" | env \
  DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=3 \
  DEX_SESSION_ID="$DEX_SESSION_ID" DX_LOOP_DIR="$DX_LOOP_DIR" \
  DEX_GUARD_EVENT=bash python3 "$HANDLER" 2>&1)
GUARD_RC=$?
set -e
[[ "$GUARD_RC" -eq 0 ]] || assert_at $LINENO
if grep -q 'block-pre-phase4-push' <<<"$GUARD_OUT"; then
  printf 'human cancel did not lift stale lifecycle push guards\n' >&2
  exit 1
fi

set +e
GUARD_OUT=$(guard_payload "git push origin main" | env \
  DEX_REVIEW_PASS_ACTIVE=1 DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=3 \
  DEX_SESSION_ID="$DEX_SESSION_ID" DX_LOOP_DIR="$DX_LOOP_DIR" \
  DEX_GUARD_EVENT=bash python3 "$HANDLER" 2>&1)
GUARD_RC=$?
set -e
[[ "$GUARD_RC" -eq 0 ]] || assert_at $LINENO
if grep -Eq 'block-review-pass-push|block-pre-phase4-push' <<<"$GUARD_OUT"; then
  printf 'review pass still blocked a human-authorized push\n' >&2
  exit 1
fi

dx_clear_lifecycle_control "$DEX_SESSION_ID"
rm -f "$PAUSED_FILE"
owned_payload "Do not stop Dex; keep reviewing." "$CONTROL_OWNER" | bash "$HOOK" > "$TMP_DIR/negated.out"
[[ ! -e "$CONTROL_FILE" ]] || assert_at $LINENO

owned_payload "Skip verification and prepare the PR." "$CONTROL_OWNER" | bash "$HOOK" > "$TMP_DIR/jump.out"
[[ "$(dx_lifecycle_control_read "$DEX_SESSION_ID" action)" == "jump" ]] || assert_at $LINENO
[[ "$(dx_lifecycle_control_read "$DEX_SESSION_ID" target_phase)" == "5" ]] || assert_at $LINENO
[[ ! -e "$PAUSED_FILE" ]] || assert_at $LINENO
grep -q "Phase 5" "$TMP_DIR/jump.out"
grep -qi "stop once" "$TMP_DIR/jump.out"

set +e
GUARD_OUT=$(guard_payload "git push origin main" | env \
  DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=3 DEX_SESSION_ID="$DEX_SESSION_ID" \
  DX_LOOP_DIR="$DX_LOOP_DIR" DEX_GUARD_EVENT=bash python3 "$HANDLER" 2>&1)
GUARD_RC=$?
set -e
[[ "$GUARD_RC" -eq 0 ]] || assert_at $LINENO
if grep -q 'block-pre-phase4-push' <<<"$GUARD_OUT"; then
  printf 'jump to Phase 5 did not lift the stale Phase 3 push guard\n' >&2
  exit 1
fi

dx_clear_lifecycle_control "$DEX_SESSION_ID"
owned_payload "Skip implementation." "$CONTROL_OWNER" | env DEX_LOOP_PHASE=1 bash "$HOOK" > "$TMP_DIR/skip-implementation.out"
[[ "$(dx_lifecycle_control_read "$DEX_SESSION_ID" target_phase)" == "3" ]] || assert_at $LINENO
set +e
GUARD_OUT=$(guard_payload "git push origin main" | env \
  DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=1 DEX_SESSION_ID="$DEX_SESSION_ID" \
  DX_LOOP_DIR="$DX_LOOP_DIR" DEX_GUARD_EVENT=bash python3 "$HANDLER" 2>&1)
GUARD_RC=$?
set -e
[[ "$GUARD_RC" -eq 0 ]] || assert_at $LINENO
if grep -Eq 'block-review-pass-push|block-pre-phase4-push' <<<"$GUARD_OUT"; then
  printf 'Phase 1 still blocked a push after a Phase 3 transition request\n' >&2
  exit 1
fi

dx_write_lifecycle_control "$DEX_SESSION_ID" cancel "" user-prompt "$(printf stale | shasum -a 256 | awk '{print $1}')"
touch "$PAUSED_FILE"
owned_payload "Resume Dex." "$CONTROL_OWNER" | bash "$HOOK" > "$TMP_DIR/resume.out"
[[ ! -e "$CONTROL_FILE" ]] || assert_at $LINENO
[[ ! -e "$PAUSED_FILE" ]] || assert_at $LINENO
grep -q "Dex lifecycle controls resumed" "$TMP_DIR/resume.out"

dx_clear_lifecycle_control "$DEX_SESSION_ID"
printf '%s\n' "$CONTROL_OWNER" > "$(dx_owner_file "$DEX_SESSION_ID")"
payload "Stop Dex." | bash "$HOOK" > "$TMP_DIR/missing-owner.out"
[[ ! -e "$CONTROL_FILE" ]] || assert_at $LINENO
owned_payload "Stop Dex." "claude-bystander" | bash "$HOOK" > "$TMP_DIR/wrong-owner.out"
[[ ! -e "$CONTROL_FILE" ]] || assert_at $LINENO
owned_payload "Stop Dex." "$CONTROL_OWNER" | bash "$HOOK" > "$TMP_DIR/right-owner.out"
[[ "$(dx_lifecycle_control_read "$DEX_SESSION_ID" action)" == "cancel" ]] || assert_at $LINENO
[[ "$(cat "$(dx_owner_file "$DEX_SESSION_ID")")" == "$CONTROL_OWNER" ]] || assert_at $LINENO

dx_clear_lifecycle_control "$DEX_SESSION_ID"
rm -f "$(dx_owner_file "$DEX_SESSION_ID")" "$(dx_paused_file "$DEX_SESSION_ID")"
VICTIM="$TMP_DIR/victim"
printf '%s\n' "keep" > "$VICTIM"
ln -s "$VICTIM" "$CONTROL_FILE"
if dx_write_lifecycle_control "$DEX_SESSION_ID" cancel "" user-prompt "$PROMPT_HASH"; then
  printf 'control writer accepted a linked control target\n' >&2
  exit 1
fi
[[ "$(cat "$VICTIM")" == "keep" ]] || assert_at $LINENO
rm -f "$CONTROL_FILE"

HISTORY_FILE=$(dx_lifecycle_control_history_file "$DEX_SESSION_ID")
rm -f "$HISTORY_FILE"
ln -s "$VICTIM" "$HISTORY_FILE"
if dx_write_lifecycle_control "$DEX_SESSION_ID" cancel "" user-prompt "$PROMPT_HASH"; then
  printf 'control writer accepted a linked history target\n' >&2
  exit 1
fi
[[ "$(cat "$VICTIM")" == "keep" ]] || assert_at $LINENO
[[ ! -e "$CONTROL_FILE" ]] || assert_at $LINENO
rm -f "$HISTORY_FILE" "$CONTROL_FILE"

if dx_write_lifecycle_control "../outside" cancel "" user-prompt "$PROMPT_HASH"; then
  printf 'control writer accepted an unsafe session id\n' >&2
  exit 1
fi

dx_clear_lifecycle_control "$DEX_SESSION_ID"
unset DEX_LOOP_ACTIVE
rm -f "$(dx_active_file "$DEX_SESSION_ID")" "$(dx_loop_config_file "$DEX_SESSION_ID")"
payload "Stop Dex." | bash "$HOOK" > "$TMP_DIR/inactive.out"
[[ ! -e "$CONTROL_FILE" ]] || assert_at $LINENO
[[ ! -s "$TMP_DIR/inactive.out" ]] || assert_at $LINENO

# Stale launcher environment cannot reactivate an authoritative completed phase.
printf '%s\n' 7 > "$(dx_state_file "$DEX_SESSION_ID")"
owned_payload "Stop." "$CONTROL_OWNER" | env DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=3 bash "$HOOK" > "$TMP_DIR/completed.out"
[[ ! -e "$CONTROL_FILE" ]] || assert_at $LINENO

printf 'lifecycle control hook tests passed\n'
