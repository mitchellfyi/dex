#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-triage-hooks.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
export HOME="$TMP_DIR/home" DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state" DX_LOOP_DIR="$TMP_DIR/loops"
export DX_RUN_ROOT="$TMP_DIR/runs" DX_RTK_ENABLED=0
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR" "$TMP_DIR/repo"
git -C "$TMP_DIR/repo" init -q
cd "$TMP_DIR/repo"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
export DEX_SESSION_ID="$(dx_session_id)" DEX_TRIAGE_ACTIVE=1
export DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=6 DEX_PHASE_HANDOFF=inline
printf 'original active lifecycle\n' > "$(dx_active_file "$DEX_SESSION_ID")"
printf 'original context\n' > "$(dx_context_file "$DEX_SESSION_ID")"
printf 'original state\n' > "$(dx_state_file "$DEX_SESSION_ID")"
printf 'original times\n' > "$(dx_times_file "$DEX_SESSION_ID")"

snapshot() {
  python3 - "$DX_STATE_DIR" "$DX_LOOP_DIR" <<'PY'
import hashlib, json, sys
from pathlib import Path
print(json.dumps({str(p): hashlib.sha256(p.read_bytes()).hexdigest()
    for folder in sys.argv[1:] for p in sorted(Path(folder).rglob('*')) if p.is_file()}, sort_keys=True))
PY
}
before="$(snapshot)"
for hook in phase-loop user-prompt-submit session-end; do
  bash "$ROOT/hooks/$hook.sh" <<<'{"prompt":"done","session_id":"triage-fixture"}' > "$TMP_DIR/$hook.out"
  [[ ! -s "$TMP_DIR/$hook.out" ]] || assert_at "$LINENO"
  [[ "$(snapshot)" == "$before" ]] || assert_at "$LINENO"
done
bash "$ROOT/hooks/load-ticket-context.sh" > "$TMP_DIR/start"
assert_contains 'triage' "$TMP_DIR/start"
if rg -q 'Phase 0|set.*In Progress|Use /dex to begin' "$TMP_DIR/start"; then
  assert_at "$LINENO" 'triage received implementation intake'
fi
bash "$ROOT/hooks/pre-compact.sh" > "$TMP_DIR/compact"
assert_contains 'processed/pending tickets' "$TMP_DIR/compact"
[[ "$(snapshot)" == "$before" ]] || assert_at "$LINENO"

# The provider's checkout alias is shared with other sessions. Exercise this
# under bash as well as the zsh launcher covered by triage-command-test.sh.
DX_PROVIDER_ENGINE=claude
dx_provider_write_session_state "$DEX_SESSION_ID"
alias_contents="$(cat "$(dx_provider_state_file "$DEX_SESSION_ID")")"
dx_provider_write_session_state "triage-$DEX_SESSION_ID-fixture"
[[ "$(cat "$(dx_provider_state_file "$DEX_SESSION_ID")")" == "$alias_contents" ]] || assert_at "$LINENO"
dx_provider_cleanup_session_state "triage-$DEX_SESSION_ID-fixture"
[[ "$(cat "$(dx_provider_state_file "$DEX_SESSION_ID")")" == "$alias_contents" ]] || assert_at "$LINENO"

# Repo and checkout cleanup recognise triage state, including old interrupted runs.
for cleanup_mode in checkout repo; do
  triage_id="triage-$(dx_unique_session_id)"
  printf 'context\n' > "$(dx_context_file "$triage_id")"
  if [[ "$cleanup_mode" == checkout ]]; then
    dx_cleanup_current_checkout_sessions
  else
    dx_cleanup_repo_sessions
  fi
  [[ ! -f "$(dx_context_file "$triage_id")" ]] || assert_at "$LINENO"
done
printf 'triage hook tests passed\n'
