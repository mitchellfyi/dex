#!/usr/bin/env bash
set -euo pipefail
umask 077

# Tests for the Stop-hook ownership guard and review-pass isolation in
# hooks/phase-loop.sh:
#   - a bystander Claude session (different hook session_id) resolving the same
#     dex session id must stay inert instead of being captured by the loop
#   - the owning session claims/reclaims the loop and still gets the audit gate
#   - a review-wave pass (DEX_REVIEW_PASS_ACTIVE=1) completing must exit via
#     the plain loop-complete path, never the inline phase handoff that
#     advances the lifecycle phase and instructs commit/push

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
HOOK="$ROOT/hooks/phase-loop.sh"
export DEX_DIR="$ROOT"
# The hook re-resolves the review policy from its working directory, and the
# expected bindings below are computed from $ROOT — pin the cwd so the suite
# also passes when invoked from outside the Dex checkout.
cd "$ROOT"

# Hermeticity: this suite may itself run inside a Dex lifecycle or review-wave
# session whose environment already carries loop state. `env VAR=x` preserves
# the rest of the caller's environment, so strip everything the hook reads
# before the cases run; each case sets exactly the vars it needs.
unset DEX_LOOP_ACTIVE DEX_REVIEW_PASS_ACTIVE DEX_PHASE_HANDOFF DEX_LOOP_PHASE \
  DEX_LOOP_PROMISE DEX_LOOP_PROMPT DEX_LOOP_MIN_AUDITS DEX_LOOP_MAX_ITERATIONS \
  DEX_LOOP_STALL_TIMEOUT DEX_LOOP_STALL_ESCALATE DEX_COMPLETE_WAIT_MINUTES \
  DEX_REVIEW_PASS_TIMEOUT DEX_REVIEW_PASS_NOTICE_INTERVAL \
  DEX_REVIEW_PASS_RECHECK_SECONDS DEX_SESSION_ID

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-phase-loop-test.XXXXXX")"
cleanup() {
  chmod -R u+w "$TMP_DIR" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_STATE_DIR="$TMP_DIR/phases"
export DX_RUN_ROOT="$TMP_DIR/runs"
mkdir -p "$DX_LOOP_DIR" "$DX_STATE_DIR"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"
# shellcheck disable=SC1091
source "$ROOT/tests/review-proof-fixture.sh"

REVIEW_REPO="$TMP_DIR/review-repo"
git init -q "$REVIEW_REPO"
git -C "$REVIEW_REPO" config user.email dex@example.test
git -C "$REVIEW_REPO" config user.name "Dex Test"
printf '%s\n' "review fixture" > "$REVIEW_REPO/README.md"
git -C "$REVIEW_REPO" add README.md
git -C "$REVIEW_REPO" commit -q -m "test: initialize review fixture"

pass=0
fail=0

# Assertions read the case-scoped globals OUT/RC directly. Hook output must
# never be re-parsed as shell (no eval): it contains JSON quotes and backtick
# fences that would be mangled or executed.
report() {
  if [[ "$2" -eq 0 ]]; then
    pass=$((pass + 1))
  else
    printf 'FAIL: %s\n' "$1" >&2
    fail=$((fail + 1))
  fi
}

assert_rc() { # <desc> <expected-rc>
  if [[ "$RC" -eq "$2" ]]; then report "$1" 0; else report "$1" 1; fi
}

assert_out_empty() { # <desc>
  if [[ -z "$OUT" ]]; then report "$1" 0; else report "$1" 1; fi
}

assert_out_contains() { # <desc> <fixed-string>
  if [[ "${OUT}" == *"$2"* ]]; then report "$1" 0; else report "$1" 1; fi
}

assert_out_lacks() { # <desc> <fixed-string>
  if [[ "${OUT}" == *"$2"* ]]; then report "$1" 1; else report "$1" 0; fi
}

assert_file_eq() { # <desc> <path> <expected-content>
  if [[ "$(cat "$2" 2>/dev/null)" == "$3" ]]; then report "$1" 0; else report "$1" 1; fi
}

backdate_versioned_busy_record() { # <busy-file> <age-seconds>
  local busy_file="$1" age_seconds="$2" raw rest schema epoch token
  local owner_pid timeout_field label token_nonce backdated_epoch
  raw=$(cat "$busy_file")
  schema="${raw%%$'\t'*}"
  rest="${raw#*$'\t'}"
  epoch="${rest%%$'\t'*}"
  rest="${rest#*$'\t'}"
  token="${rest%%$'\t'*}"
  rest="${rest#*$'\t'}"
  owner_pid="${rest%%$'\t'*}"
  rest="${rest#*$'\t'}"
  timeout_field="${rest%%$'\t'*}"
  label="${rest#*$'\t'}"
  [[ "$schema" == "dex-phase-busy-v2" && "$token" == "$epoch-$owner_pid-"* ]] \
    || return 1
  token_nonce="${token##*-}"
  backdated_epoch=$(( $(date +%s) - age_seconds ))
  dx_lifecycle_atomic_write "$busy_file" \
    "${schema}"$'\t'"${backdated_epoch}"$'\t'\
"${backdated_epoch}-${owner_pid}-${token_nonce}"$'\t'"${owner_pid}"$'\t'\
"${timeout_field}"$'\t'"${label}"
}

write_review_context() { # <session-id>
  {
    printf '%s\n\n' "## Scope"
    printf '%s\n\n' "Reviewed the complete supplied scope for this hook contract fixture."
    printf '%s\n\n' "## Acceptance Criteria"
    printf '%s\n\n' "Criteria binding: standalone"
    printf '%s\n\n' "## Deterministic Checks"
    printf '%s\n\n' "All applicable fixture checks passed."
    printf '%s\n\n' "## Review Coverage"
    printf '%s\n\n' "Correctness, security, contracts, tests, and architecture were covered."
    printf '%s\n\n' "## Verification"
    printf '%s\n' "The independent fixture verifier passed."
  } > "$(dx_review_context_file "$1")"
}

write_review_criteria() { # <session-id>
  printf '%s\n' '{"version":1,"source":"approved-plan","objectives":["Exercise the lifecycle handoff."],"acceptance_criteria":["The next phase starts only after its gates pass."],"verification_requirements":["Run tests/phase-loop-ownership-test.sh."]}' > "$(dx_review_criteria_file "$1")"
}

configure_lifecycle_completion() { # <session-id> <phase> <audit-file>
  local session_id="$1" phase="$2" audit_file="$3" generation
  generation=$(dx_completion_issue "$session_id" lifecycle phase "$phase")
  printf '%s:PHASE_%s_COMPLETE:%s:1:lifecycle:phase:%s\n' \
    "$phase" "$phase" "$audit_file" "$generation" > "$(dx_loop_config_file "$session_id")"
}

write_lifecycle_completion() { # <session-id> <phase>
  local generation
  generation=$(dx_completion_current_generation "$1" lifecycle phase "$2")
  dx_completion_write_receipt "$1" "$generation"
}

prepare_review_pass_bindings() { # <session-id> <fingerprint>
  REVIEW_PASS_ID="$1"
  REVIEW_PASS_BINDING=$(dx_review_pass_binding "$REVIEW_PASS_ID" "$2" standalone "$REVIEW_POLICY_BINDING")
}

configure_review_pass_completion() { # <session-id>
  REVIEW_PASS_GENERATION=$(dx_completion_loop_activate \
    "$1" child review-pass 3)
}

write_review_pass_completion() { # <session-id>
  dx_completion_write_receipt "$1" "$REVIEW_PASS_GENERATION"
}

write_review_evidence() { # <session-id> <result> <fingerprint>
  local session_id="$1" result="$2" fingerprint="$3" checks=pass verifier=pass
  case "$result" in
    BLOCKED:*|CHURN:*) checks=partial; verifier=not-run ;;
    ESCALATE:*|ESCALATE_THOROUGH:*) checks=partial; verifier=pass ;;
  esac
  prepare_review_pass_bindings "$session_id" "$fingerprint"
  printf '{"version":3,"scope_fingerprint":"%s","criteria_binding":"standalone","policy_binding":"%s","pass_binding":"%s","criteria_evidence":{"acceptance_criteria":[],"objectives":[],"verification_requirements":[]},"deterministic_checks":"%s","coverage":["correctness","security","contracts","tests","architecture"],"verifier":"%s","verified_findings":0,"fixes_applied":0}\n' \
    "$fingerprint" "$REVIEW_POLICY_BINDING" "$REVIEW_PASS_BINDING" "$checks" "$verifier" > "$(dx_review_evidence_file "$session_id")"
}

REVIEW_SCOPE_FINGERPRINT=$(dx_review_scope_fingerprint "$ROOT")
REVIEW_POLICY_BINDING=$(dx_review_policy_resolve "$ROOT" | cut -f4)

# --- case 1: bystander session with a claimed loop stays inert ---
SID="repo-test-1-main"
touch "$DX_LOOP_DIR/$SID.active"
printf '%s\n' "claude-owner" > "$DX_LOOP_DIR/$SID.owner"
set +e
OUT="$(printf '{"session_id":"claude-bystander"}' | env DEX_SESSION_ID="$SID" bash "$HOOK" 2>&1)"
RC=$?
set -e
assert_rc "bystander exits 0" 0
assert_out_empty "bystander gets no injected output"
assert_file_eq "bystander did not steal the claim" "$DX_LOOP_DIR/$SID.owner" "claude-owner"
rm -f "$DX_LOOP_DIR/$SID".*

# A policy record written after provider launch is read by the next Stop hook
# invocation and wins over the inherited environment.
SID="repo-test-8-dynamic-loop-limit"
touch "$DX_LOOP_DIR/$SID.active"
printf '%s\n' "1:$(date +%s):0" > "$(dx_loop_file "$SID")"
dx_override_set "$SID" loop.max-iterations 1 phase prompt-loop agent \
  "Stop this exploratory loop after its current audit" 0
set +e
OUT="$(printf '{"session_id":"claude-dynamic-limit"}' | env \
  DEX_SESSION_ID="$SID" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=prompt-loop \
  DEX_LOOP_MAX_ITERATIONS=30 bash "$HOOK" 2>&1)"
RC=$?
set -e
assert_rc "dynamic loop limit stops the current provider session" 0
assert_out_contains "dynamic loop limit is applied" "max iterations (1)"
rm -f "$DX_LOOP_DIR/$SID".* "$DX_STATE_DIR/$SID".*

# --- case 2: file-only activation without a trusted context fails closed ---
SID="repo-test-2-main"
touch "$DX_LOOP_DIR/$SID.active"
set +e
OUT="$(printf '{"session_id":"claude-first"}' | env DEX_SESSION_ID="$SID" bash "$HOOK" 2>&1)"
RC=$?
set -e
assert_rc "contextless file activation blocks stop" 2
assert_out_contains "contextless activation explains recovery" "could not recover a versioned completion context"
if [[ ! -e "$DX_LOOP_DIR/$SID.active" ]]; then report "contextless activation is inert" 0; else report "contextless activation is inert" 1; fi
if [[ ! -e "$(dx_completion_expectation_file "$SID")" ]]; then report "contextless activation has no expectation" 0; else report "contextless activation has no expectation" 1; fi
rm -f "$DX_LOOP_DIR/$SID".*

# A canonical standalone context remains claimable by its first real stopper.
SID="repo-test-2-valid-main"
VALID_GENERATION=$(dx_completion_issue "$SID" standalone dxcomplete 6)
printf '6:DEX_TICKET_COMPLETE:%s/prompts/phase-audits/6-complete.md:1:standalone:dxcomplete:%s\n' \
  "$ROOT" "$VALID_GENERATION" > "$DX_LOOP_DIR/$SID.config"
touch "$DX_LOOP_DIR/$SID.active"
set +e
OUT="$(printf '{"session_id":"claude-first-valid"}' | env DEX_SESSION_ID="$SID" bash "$HOOK" 2>&1)"
RC=$?
set -e
assert_rc "canonical unclaimed loop blocks stop for audit" 2
assert_file_eq "canonical loop claim recorded" "$DX_LOOP_DIR/$SID.owner" "claude-first-valid"
dx_completion_cleanup "$SID"
rm -f "$DX_LOOP_DIR/$SID".*

# Tuple-shaped config is not enough: the gate prefix and lifecycle identity
# must match the exact launch contract before file activation is trusted.
SID="repo-test-2-corrupt-main"
CORRUPT_GENERATION=$(dx_completion_issue "$SID" standalone dxcomplete 6)
printf '6:WRONG:%s/prompts/phase-audits/1-plan.md:0:standalone:dxcomplete:%s\n' \
  "$ROOT" "$CORRUPT_GENERATION" > "$DX_LOOP_DIR/$SID.config"
touch "$DX_LOOP_DIR/$SID.active"
set +e
OUT="$(printf '{"session_id":"claude-corrupt"}' | env DEX_SESSION_ID="$SID" bash "$HOOK" 2>&1)"
RC=$?
set -e
assert_rc "wrong-prefix file activation blocks" 2
if [[ ! -e "$DX_LOOP_DIR/$SID.active" ]]; then report "wrong-prefix activation is inert" 0; else report "wrong-prefix activation is inert" 1; fi
if [[ ! -e "$(dx_completion_expectation_file "$SID")" ]]; then report "wrong-prefix expectation revoked" 0; else report "wrong-prefix expectation revoked" 1; fi
rm -f "$DX_LOOP_DIR/$SID".*

SID="repo-test-2-uncorrelated-main"
UNCORRELATED_GENERATION=$(dx_completion_issue "$SID" lifecycle phase 2)
printf '2:PHASE_2_COMPLETE:%s/prompts/phase-audits/2-implement.md:1:lifecycle:phase:%s\n' \
  "$ROOT" "$UNCORRELATED_GENERATION" > "$DX_LOOP_DIR/$SID.config"
touch "$DX_LOOP_DIR/$SID.active"
set +e
OUT="$(printf '{"session_id":"claude-uncorrelated"}' | env DEX_SESSION_ID="$SID" bash "$HOOK" 2>&1)"
RC=$?
set -e
assert_rc "uncorrelated lifecycle config blocks" 2
if [[ ! -e "$(dx_completion_expectation_file "$SID")" ]]; then report "uncorrelated lifecycle expectation revoked" 0; else report "uncorrelated lifecycle expectation revoked" 1; fi
if [[ ! -e "$DX_STATE_DIR/$SID.phase" ]]; then report "uncorrelated config did not invent phase state" 0; else report "uncorrelated config did not invent phase state" 1; fi
rm -f "$DX_LOOP_DIR/$SID".*

# --- case 3: env-activated session reclaims a stale claim ---
SID="repo-test-3-main"
touch "$DX_LOOP_DIR/$SID.active"
printf '%s\n' "claude-stale" > "$DX_LOOP_DIR/$SID.owner"
printf '%s\n' "2" > "$DX_STATE_DIR/$SID.phase"
printf '%s\n' "inline" > "$DX_LOOP_DIR/$SID.handoff-mode"
set +e
OUT="$(printf '{"session_id":"claude-relaunch"}' | env DEX_SESSION_ID="$SID" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=2 bash "$HOOK" 2>&1)"
RC=$?
set -e
assert_rc "env-activated session proceeds" 2
assert_file_eq "env-activated session reclaims" "$DX_LOOP_DIR/$SID.owner" "claude-relaunch"
rm -f "$DX_LOOP_DIR/$SID".* "$DX_STATE_DIR/$SID".*

# A stale provider environment survives the Phase 6 handoff, but Phase 7 is
# already terminal and has no completion config to recover. Older hooks paused
# here before reaching their terminal-state check; repair that exact artifact
# and let Claude exit normally.
SID="repo-test-3-completed-main"
dx_lifecycle_atomic_write "$(dx_state_file "$SID")" 7
dx_lifecycle_control_lock_acquire "$SID"
dx_lifecycle_terminal_commit_publish_unlocked "$SID" \
  0123456789abcdef0123456789abcdef
dx_lifecycle_control_lock_release "$SID"
dx_write_pause_state "$SID" invalid-completion-context phase-loop
dx_lifecycle_atomic_write "$(dx_paused_file "$SID")" paused
set +e
OUT="$(printf '{"session_id":"claude-completed"}' | env \
  DEX_SESSION_ID="$SID" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=6 \
  DEX_PHASE_HANDOFF=inline bash "$HOOK" 2>&1)"
RC=$?
set -e
assert_rc "completed lifecycle exits normally" 0
assert_out_lacks "completed lifecycle avoids invalid context" \
  "could not recover a versioned completion context"
if dx_lifecycle_terminal_commit_valid "$SID"; then
  report "completed lifecycle retains valid terminal proof" 0
else
  report "completed lifecycle retains valid terminal proof" 1
fi
if [[ ! -e "$(dx_paused_file "$SID")" \
  && ! -e "$(dx_pause_state_file "$SID")" ]]; then
  report "completed lifecycle retires false pause" 0
else
  report "completed lifecycle retires false pause" 1
fi
rm -f "$DX_LOOP_DIR/$SID".* "$DX_STATE_DIR/$SID".*

# --- case 4: completed review pass never runs the inline phase handoff ---
SID="repo-test-4-main-pass-1-999"
configure_review_pass_completion "$SID"
printf '%s\n' "3" > "$DX_STATE_DIR/$SID.phase"
printf '%s\n' "CLEAN" > "$DX_LOOP_DIR/$SID.review-result"
write_review_context "$SID"
write_review_evidence "$SID" CLEAN "$REVIEW_SCOPE_FINGERPRINT"
printf '%s\n' "0123456789abcdef" > "$DX_LOOP_DIR/$SID.findings"
write_review_pass_completion "$SID"
set +e
OUT="$(printf '{"session_id":"claude-wave"}' | env DEX_SESSION_ID="$SID" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=3 DEX_REVIEW_PASS_ACTIVE=1 DEX_REVIEW_PROFILE=light DEX_REVIEW_SCOPE_FINGERPRINT="$REVIEW_SCOPE_FINGERPRINT" DEX_REVIEW_POLICY_BINDING="$REVIEW_POLICY_BINDING" DEX_REVIEW_PASS_ID="$REVIEW_PASS_ID" DEX_REVIEW_PASS_BINDING="$REVIEW_PASS_BINDING" bash "$HOOK" 2>&1)"
RC=$?
set -e
assert_rc "review pass allowed to stop" 0
assert_out_contains "review pass gets plain loop-complete stop" "Dex loop complete"
assert_out_lacks "review pass did not trigger phase handoff" "Phase Handoff"
assert_file_eq "phase state not advanced by review pass" "$DX_STATE_DIR/$SID.phase" "3"
# The launching wrapper harvests the pass findings hash into the parent
# session stuck-loop history after the wave exits, so the hook must leave it.
assert_file_eq "findings hash preserved for wrapper harvest" "$DX_LOOP_DIR/$SID.findings" "0123456789abcdef"
if [[ -f "$(dx_completion_receipt_file "$SID" "$REVIEW_PASS_GENERATION")" ]]; then report "completion receipt preserved for wrapper harvest" 0; else report "completion receipt preserved for wrapper harvest" 1; fi
rm -f "$DX_LOOP_DIR/$SID".* "$DX_STATE_DIR/$SID".*

# --- case 5: review pass with invalid result is held open ---
SID="repo-test-5-main-pass-2-999"
configure_review_pass_completion "$SID"
prepare_review_pass_bindings "$SID" "$REVIEW_SCOPE_FINGERPRINT"
printf '%s\n' "not-a-result" > "$DX_LOOP_DIR/$SID.review-result"
write_review_pass_completion "$SID"
set +e
OUT="$(printf '{"session_id":"claude-wave2"}' | env DEX_SESSION_ID="$SID" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=3 DEX_REVIEW_PASS_ACTIVE=1 DEX_REVIEW_PROFILE=light DEX_REVIEW_SCOPE_FINGERPRINT="$REVIEW_SCOPE_FINGERPRINT" DEX_REVIEW_POLICY_BINDING="$REVIEW_POLICY_BINDING" DEX_REVIEW_PASS_ID="$REVIEW_PASS_ID" DEX_REVIEW_PASS_BINDING="$REVIEW_PASS_BINDING" bash "$HOOK" 2>&1)"
RC=$?
set -e
assert_rc "invalid result blocks review pass stop" 2
assert_out_contains "invalid result message shown" "result signal missing or invalid"
rm -f "$DX_LOOP_DIR/$SID".*

# --- case 6: a review pass cannot complete without a substantive context pack ---
SID="repo-test-6-main-pass-3-999"
configure_review_pass_completion "$SID"
printf '%s\n' "CLEAN" > "$DX_LOOP_DIR/$SID.review-result"
printf '%s\n' "   " > "$DX_LOOP_DIR/$SID.review-context"
printf '%s\n' "0123456789abcdef" > "$DX_LOOP_DIR/$SID.findings"
write_review_pass_completion "$SID"
prepare_review_pass_bindings "$SID" "$REVIEW_SCOPE_FINGERPRINT"
set +e
OUT="$(printf '{"session_id":"claude-wave3"}' | env DEX_SESSION_ID="$SID" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=3 DEX_REVIEW_PASS_ACTIVE=1 DEX_REVIEW_PROFILE=light DEX_REVIEW_SCOPE_FINGERPRINT="$REVIEW_SCOPE_FINGERPRINT" DEX_REVIEW_POLICY_BINDING="$REVIEW_POLICY_BINDING" DEX_REVIEW_PASS_ID="$REVIEW_PASS_ID" DEX_REVIEW_PASS_BINDING="$REVIEW_PASS_BINDING" bash "$HOOK" 2>&1)"
RC=$?
set -e
assert_rc "empty context pack blocks review pass stop" 2
assert_out_contains "empty context pack message shown" "context pack missing or empty"
rm -f "$DX_LOOP_DIR/$SID".*

# --- case 7: a review pass must write exactly one valid findings hash ---
SID="repo-test-7-main-pass-4-999"
configure_review_pass_completion "$SID"
printf '%s\n' "CLEAN" > "$DX_LOOP_DIR/$SID.review-result"
write_review_context "$SID"
write_review_evidence "$SID" CLEAN "$REVIEW_SCOPE_FINGERPRINT"
printf '%s\n%s\n' "0123456789abcdef" "fedcba9876543210" > "$DX_LOOP_DIR/$SID.findings"
write_review_pass_completion "$SID"
set +e
OUT="$(printf '{"session_id":"claude-wave4"}' | env DEX_SESSION_ID="$SID" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=3 DEX_REVIEW_PASS_ACTIVE=1 DEX_REVIEW_PROFILE=light DEX_REVIEW_SCOPE_FINGERPRINT="$REVIEW_SCOPE_FINGERPRINT" DEX_REVIEW_POLICY_BINDING="$REVIEW_POLICY_BINDING" DEX_REVIEW_PASS_ID="$REVIEW_PASS_ID" DEX_REVIEW_PASS_BINDING="$REVIEW_PASS_BINDING" bash "$HOOK" 2>&1)"
RC=$?
set -e
assert_rc "multiple findings hashes block review pass stop" 2
assert_out_contains "findings hash message shown" "findings hash missing or invalid"
rm -f "$DX_LOOP_DIR/$SID".*

# --- case 8: invalid numeric limits block with an actionable error ---
LIMIT_INDEX=0
for LIMIT_NAME in DEX_LOOP_MAX_ITERATIONS DEX_LOOP_MIN_AUDITS DEX_LOOP_STALL_TIMEOUT DEX_LOOP_STALL_ESCALATE; do
  LIMIT_INDEX=$((LIMIT_INDEX + 1))
  SID="repo-test-8-limit-$LIMIT_INDEX"
  touch "$DX_LOOP_DIR/$SID.active"
  set +e
  OUT="$(printf '{"session_id":"claude-limit"}' | env DEX_SESSION_ID="$SID" \
    DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=prompt-loop \
    "$LIMIT_NAME=abc" bash "$HOOK" 2>&1)"
  RC=$?
  set -e
  assert_rc "$LIMIT_NAME blocks cleanly" 2
  assert_out_contains "$LIMIT_NAME names the invalid setting" "$LIMIT_NAME='abc'"
  assert_out_lacks "$LIMIT_NAME avoids shell arithmetic errors" "unbound variable"
  rm -f "$DX_LOOP_DIR/$SID".*
done

SID="repo-test-8-limit-overflow"
touch "$DX_LOOP_DIR/$SID.active"
set +e
OUT="$(printf '{"session_id":"claude-limit"}' | env DEX_SESSION_ID="$SID" \
  DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=prompt-loop \
  DEX_LOOP_MAX_ITERATIONS=9999999999999999 bash "$HOOK" 2>&1)"
RC=$?
set -e
assert_rc "oversized loop limit blocks cleanly" 2
assert_out_contains "oversized loop limit names the invalid setting" "must be a non-negative decimal with at most 15 digits"
rm -f "$DX_LOOP_DIR/$SID".*

# Timeout-bearing review fences use a versioned record. Legacy labels remain
# opaque, even when their first tab-delimited word resembles timeout metadata.
SID="repo-test-8-versioned-busy-timeout"
BOUND_BUSY_TOKEN=$(dx_phase_busy_begin \
  "$SID" 3 "versioned timeout fixture" 2400)
BOUND_BUSY_RAW=$(cat "$(dx_phase_busy_file "$SID" 3)")
if [[ "$BOUND_BUSY_RAW" == dex-phase-busy-v2$'\t'* ]]; then
  report "timeout-bearing busy record is versioned" 0
else
  report "timeout-bearing busy record is versioned" 1
fi
BOUND_TIMEOUT_RC=0
BOUND_TIMEOUT=$(dx_phase_busy_timeout "$SID" 3) || BOUND_TIMEOUT_RC=$?
if [[ "$BOUND_TIMEOUT_RC" -eq 0 && "$BOUND_TIMEOUT" == "2400" ]]; then
  report "versioned busy record exposes its bound timeout" 0
else
  report "versioned busy record exposes its bound timeout" 1
fi
if [[ "$(dx_phase_busy_token "$SID" 3)" == "$BOUND_BUSY_TOKEN" ]]; then
  report "versioned busy record preserves its exact owner token" 0
else
  report "versioned busy record preserves its exact owner token" 1
fi
rm -f "$DX_LOOP_DIR/$SID".*

SID="repo-test-8-legacy-tabbed-label"
LEGACY_BUSY_TOKEN=$(dx_phase_busy_begin \
  "$SID" 3 $'timeout=0\tlegacy label')
LEGACY_TIMEOUT_RC=0
LEGACY_TIMEOUT=$(dx_phase_busy_timeout "$SID" 3) || LEGACY_TIMEOUT_RC=$?
if [[ "$LEGACY_TIMEOUT_RC" -eq 1 && -z "$LEGACY_TIMEOUT" ]]; then
  report "legacy tabbed label does not become timeout metadata" 0
else
  report "legacy tabbed label does not become timeout metadata" 1
fi
if [[ "$(dx_phase_busy_token "$SID" 3)" == "$LEGACY_BUSY_TOKEN" ]]; then
  report "legacy tabbed label preserves its exact owner token" 0
else
  report "legacy tabbed label preserves its exact owner token" 1
fi
rm -f "$DX_LOOP_DIR/$SID".*

SID="repo-test-8-malformed-busy-timeout"
MALFORMED_BUSY_RECORDS=(
  $'1\t1-1-1\ttimeout=0'
  $'dex-phase-busy-v2\t1\t1-1-1\t1\ttimeout=0'
  $'dex-phase-busy-v2\t1\t2-1-1\t1\ttimeout=0\twrong epoch'
  $'dex-phase-busy-v2\t1\t1-2-1\t1\ttimeout=0\twrong pid'
  $'dex-phase-busy-v2\t1\t1-1-1\t1\ttimeout=bad\tbad timeout'
)
MALFORMED_CASE=0
for MALFORMED_BUSY_RAW in "${MALFORMED_BUSY_RECORDS[@]}"; do
  MALFORMED_CASE=$((MALFORMED_CASE + 1))
  dx_lifecycle_atomic_write "$(dx_phase_busy_file "$SID" 3)" \
    "$MALFORMED_BUSY_RAW"
  MALFORMED_TIMEOUT_RC=0
  dx_phase_busy_timeout "$SID" 3 >/dev/null 2>&1 \
    || MALFORMED_TIMEOUT_RC=$?
  if [[ "$MALFORMED_TIMEOUT_RC" -eq 2 ]]; then
    report "malformed busy timeout ${MALFORMED_CASE} fails closed" 0
  else
    report "malformed busy timeout ${MALFORMED_CASE} fails closed" 1
  fi
  if [[ -z "$(dx_phase_busy_token "$SID" 3)" ]]; then
    report "malformed busy token ${MALFORMED_CASE} is not authoritative" 0
  else
    report "malformed busy token ${MALFORMED_CASE} is not authoritative" 1
  fi
  rm -f "$DX_LOOP_DIR/$SID".*
done

SID="repo-test-8-noncanonical-busy-token"
for NONCANONICAL_BUSY_TOKEN in "1-1-1-" "1-1-1--"; do
  dx_lifecycle_atomic_write "$(dx_phase_busy_file "$SID" 3)" \
    $'dex-phase-busy-v2\t1\t'"${NONCANONICAL_BUSY_TOKEN}"$'\t1\ttimeout=0\tbad token'
  for BUSY_RECORD_SHELL in bash zsh; do
    BUSY_PARSE_RC=0
    BUSY_PARSE_OUT=$(env DEX_DIR="$ROOT" DX_LOOP_DIR="$DX_LOOP_DIR" \
      DX_STATE_DIR="$DX_STATE_DIR" "$BUSY_RECORD_SHELL" -c '
        source "$DEX_DIR/lib/common.sh" || exit 99
        busy_timeout_rc=0
        dx_phase_busy_timeout "$1" 3 >/dev/null 2>&1 || busy_timeout_rc=$?
        busy_token=$(dx_phase_busy_token "$1" 3)
        printf "%s:%s" "$busy_timeout_rc" "$busy_token"
      ' "$BUSY_RECORD_SHELL" "$SID") || BUSY_PARSE_RC=$?
    if [[ "$BUSY_PARSE_RC" -eq 0 && "$BUSY_PARSE_OUT" == "2:" ]]; then
      report "$BUSY_RECORD_SHELL rejects noncanonical token $NONCANONICAL_BUSY_TOKEN" 0
    else
      report "$BUSY_RECORD_SHELL rejects noncanonical token $NONCANONICAL_BUSY_TOKEN" 1
    fi
  done
  rm -f "$DX_LOOP_DIR/$SID".*
done

# The review owner persists its selected timeout in the busy record. The
# parent Stop hook must use that value instead of the environment inherited
# when Claude launched.
SID="repo-test-8-persisted-timeout-waits"
printf '%s\n' "3" > "$DX_STATE_DIR/$SID.phase"
printf '%s\n' "inline" > "$DX_LOOP_DIR/$SID.handoff-mode"
configure_lifecycle_completion "$SID" 3 "$ROOT/prompts/phase-audits/3-review-loop.md"
touch "$DX_LOOP_DIR/$SID.active"
dx_phase_busy_begin "$SID" 3 "persisted timeout fixture" 2400 >/dev/null
dx_override_set "$SID" review.pass-timeout 3600 phase 3 agent \
  "The current wave needs another twenty minutes" 0
BUSY_FILE=$(dx_phase_busy_file "$SID" 3)
backdate_versioned_busy_record "$BUSY_FILE" 2401
set +e
OUT="$(printf '{"session_id":"claude-timeout-wait"}' | env \
  DEX_SESSION_ID="$SID" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=3 \
  DEX_PHASE_HANDOFF=inline DEX_REVIEW_PASS_TIMEOUT=900 \
  DEX_REVIEW_PASS_NOTICE_INTERVAL=0 DEX_REVIEW_PASS_RECHECK_SECONDS=0 \
  bash "$HOOK" 2>&1)"
RC=$?
set -e
assert_rc "persisted timeout keeps a live review wave waiting" 2
assert_out_contains "dynamic timeout reports the selected deadline" "1h 0m"
assert_out_lacks "dynamic timeout does not pause the wave" "review pass timeout reached"
if [[ ! -e "$(dx_paused_file "$SID")" ]]; then report "dynamic timeout leaves lifecycle active" 0; else report "dynamic timeout leaves lifecycle active" 1; fi
dx_completion_cleanup "$SID"
rm -f "$DX_LOOP_DIR/$SID".* "$DX_STATE_DIR/$SID".*

SID="repo-test-8-persisted-timeout-pauses"
printf '%s\n' "3" > "$DX_STATE_DIR/$SID.phase"
printf '%s\n' "inline" > "$DX_LOOP_DIR/$SID.handoff-mode"
configure_lifecycle_completion "$SID" 3 "$ROOT/prompts/phase-audits/3-review-loop.md"
touch "$DX_LOOP_DIR/$SID.active"
dx_phase_busy_begin "$SID" 3 "persisted timeout fixture" 2400 >/dev/null
BUSY_FILE=$(dx_phase_busy_file "$SID" 3)
backdate_versioned_busy_record "$BUSY_FILE" 2401
set +e
OUT="$(printf '{"session_id":"claude-timeout-pause"}' | env \
  DEX_SESSION_ID="$SID" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=3 \
  DEX_PHASE_HANDOFF=inline DEX_REVIEW_PASS_TIMEOUT=9999 \
  DEX_REVIEW_PASS_NOTICE_INTERVAL=0 DEX_REVIEW_PASS_RECHECK_SECONDS=0 \
  bash "$HOOK" 2>&1)"
RC=$?
set -e
assert_rc "persisted timeout pauses an overdue review wave" 2
assert_out_contains "persisted timeout pause reports its deadline" "40m 0s"
assert_out_contains "persisted timeout pause is explicit" "review pass timeout reached"
if [[ -e "$(dx_paused_file "$SID")" ]]; then report "persisted timeout records a lifecycle pause" 0; else report "persisted timeout records a lifecycle pause" 1; fi
dx_completion_cleanup "$SID"
rm -f "$DX_LOOP_DIR/$SID".* "$DX_STATE_DIR/$SID".*

SID="repo-test-8-persisted-timeout-disabled"
printf '%s\n' "3" > "$DX_STATE_DIR/$SID.phase"
printf '%s\n' "inline" > "$DX_LOOP_DIR/$SID.handoff-mode"
configure_lifecycle_completion "$SID" 3 "$ROOT/prompts/phase-audits/3-review-loop.md"
touch "$DX_LOOP_DIR/$SID.active"
dx_phase_busy_begin "$SID" 3 "disabled timeout fixture" 0 >/dev/null
BUSY_FILE=$(dx_phase_busy_file "$SID" 3)
backdate_versioned_busy_record "$BUSY_FILE" 10000
set +e
OUT="$(printf '{"session_id":"claude-timeout-disabled"}' | env \
  DEX_SESSION_ID="$SID" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=3 \
  DEX_PHASE_HANDOFF=inline DEX_REVIEW_PASS_TIMEOUT=1 \
  DEX_REVIEW_PASS_NOTICE_INTERVAL=0 DEX_REVIEW_PASS_RECHECK_SECONDS=0 \
  bash "$HOOK" 2>&1)"
RC=$?
set -e
assert_rc "persisted zero timeout keeps an old review wave waiting" 2
assert_out_contains "disabled timeout is reported accurately" "timeout is disabled"
assert_out_lacks "disabled timeout does not pause the wave" "review pass timeout reached"
if [[ ! -e "$(dx_paused_file "$SID")" ]]; then report "disabled timeout leaves lifecycle active" 0; else report "disabled timeout leaves lifecycle active" 1; fi
dx_completion_cleanup "$SID"
rm -f "$DX_LOOP_DIR/$SID".* "$DX_STATE_DIR/$SID".*

# --- case 6: every centralized review result alias is accepted ---
VALID_REVIEW_RESULTS=(
  "CHURN:repeated-fingerprint"
  "ESCALATE:normal:cross-module"
  "ESCALATE:complex:security"
  "ESCALATE_THOROUGH:legacy"
)
case_number=0
for review_result in "${VALID_REVIEW_RESULTS[@]}"; do
  case_number=$((case_number + 1))
  SID="repo-test-6-${case_number}-main-pass"
  configure_review_pass_completion "$SID"
  printf '%s\n' "$review_result" > "$DX_LOOP_DIR/$SID.review-result"
  write_review_context "$SID"
  write_review_evidence "$SID" "$review_result" "$REVIEW_SCOPE_FINGERPRINT"
  printf '%s\n' "0123456789abcdef" > "$DX_LOOP_DIR/$SID.findings"
  write_review_pass_completion "$SID"
  set +e
  OUT="$(printf '{\"session_id\":\"claude-wave-alias-%s\"}' "$case_number" | env DEX_SESSION_ID="$SID" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=3 DEX_REVIEW_PASS_ACTIVE=1 DEX_REVIEW_PROFILE=light DEX_REVIEW_SCOPE_FINGERPRINT="$REVIEW_SCOPE_FINGERPRINT" DEX_REVIEW_POLICY_BINDING="$REVIEW_POLICY_BINDING" DEX_REVIEW_PASS_ID="$REVIEW_PASS_ID" DEX_REVIEW_PASS_BINDING="$REVIEW_PASS_BINDING" bash "$HOOK" 2>&1)"
  RC=$?
  set -e
  assert_rc "review result '$review_result' is accepted" 0
  assert_out_contains "review result '$review_result' exits the pass" "Dex loop complete"
  rm -f "$DX_LOOP_DIR/$SID".*
done

# FINDINGS_FIXED and FINDINGS must report at least one finding.
SID="repo-test-6-zero-main-pass"
configure_review_pass_completion "$SID"
prepare_review_pass_bindings "$SID" "$REVIEW_SCOPE_FINGERPRINT"
printf '%s\n' "FINDINGS_FIXED:0" > "$DX_LOOP_DIR/$SID.review-result"
write_review_pass_completion "$SID"
set +e
OUT="$(printf '{\"session_id\":\"claude-wave-zero\"}' | env DEX_SESSION_ID="$SID" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=3 DEX_REVIEW_PASS_ACTIVE=1 DEX_REVIEW_PROFILE=light DEX_REVIEW_SCOPE_FINGERPRINT="$REVIEW_SCOPE_FINGERPRINT" DEX_REVIEW_POLICY_BINDING="$REVIEW_POLICY_BINDING" DEX_REVIEW_PASS_ID="$REVIEW_PASS_ID" DEX_REVIEW_PASS_BINDING="$REVIEW_PASS_BINDING" bash "$HOOK" 2>&1)"
RC=$?
set -e
assert_rc "zero-finding result is rejected" 2
assert_out_contains "zero-finding result shows validation message" "result signal missing or invalid"
rm -f "$DX_LOOP_DIR/$SID".*

# --- case 6b: Phase 1 preserves approved criteria before implementation ---
SID="repo-test-6b-main"
touch "$DX_LOOP_DIR/$SID.active" "$DX_LOOP_DIR/$SID.phase-1.ready"
printf '%s\n' "inline" > "$DX_LOOP_DIR/$SID.handoff-mode"
printf '%s\n' "1" > "$DX_STATE_DIR/$SID.phase"
configure_lifecycle_completion "$SID" 1 "$ROOT/prompts/phase-audits/1-plan.md"
write_lifecycle_completion "$SID" 1
set +e
OUT="$(cd "$REVIEW_REPO" && printf '{"session_id":"claude-phase-1-criteria"}' | env DEX_SESSION_ID="$SID" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=1 DEX_PHASE_HANDOFF=inline bash "$HOOK" 2>&1)"
RC=$?
set -e
assert_rc "Phase 1 without approved criteria is blocked" 2
assert_out_contains "missing Phase 1 criteria message shown" "approved review criteria missing"
assert_file_eq "missing Phase 1 criteria leaves phase active" "$DX_STATE_DIR/$SID.phase" "1"

write_review_criteria "$SID"
write_lifecycle_completion "$SID" 1
set +e
OUT="$(cd "$REVIEW_REPO" && printf '{"session_id":"claude-phase-1-criteria"}' | env DEX_SESSION_ID="$SID" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=1 DEX_PHASE_HANDOFF=inline bash "$HOOK" 2>&1)"
RC=$?
set -e
assert_rc "valid Phase 1 criteria reach handoff" 2
assert_out_contains "Phase 1 criteria emit Phase 2 handoff" "Phase Handoff: Phase 1 complete"
assert_file_eq "valid Phase 1 criteria advance to Phase 2" "$DX_STATE_DIR/$SID.phase" "2"
if dx_review_read_criteria_approval "$SID" >/dev/null; then
  report "Phase 1 transition seals approved criteria" 0
else
  report "Phase 1 transition seals approved criteria" 1
fi
printf '%s\n' '{"version":1,"source":"approved-plan","objectives":["Replace the approved lifecycle handoff."],"acceptance_criteria":["Unapproved replacements must be rejected."],"verification_requirements":["Run tests/phase-loop-ownership-test.sh."]}' > "$(dx_review_criteria_file "$SID")"
touch "$DX_LOOP_DIR/$SID.phase-2.ready"
write_lifecycle_completion "$SID" 2
set +e
OUT="$(cd "$REVIEW_REPO" && printf '{"session_id":"claude-phase-2-criteria-tamper"}' | env DEX_SESSION_ID="$SID" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=2 DEX_PHASE_HANDOFF=inline bash "$HOOK" 2>&1)"
RC=$?
set -e
assert_rc "criteria replacement after Phase 1 is blocked" 2
assert_out_contains "criteria replacement reports approval mismatch" "changed after approval"
assert_file_eq "criteria replacement leaves Phase 2 active" "$DX_STATE_DIR/$SID.phase" "2"
rm -f "$DX_LOOP_DIR/$SID".* "$DX_STATE_DIR/$SID".*

# --- case 7: Phase 2 requires approved criteria and a current risk selection ---
SID="repo-test-7-main"
touch "$DX_LOOP_DIR/$SID.active" "$DX_LOOP_DIR/$SID.phase-2.ready"
printf '%s\n' "inline" > "$DX_LOOP_DIR/$SID.handoff-mode"
printf '%s\n' "2" > "$DX_STATE_DIR/$SID.phase"
configure_lifecycle_completion "$SID" 2 "$ROOT/prompts/phase-audits/2-implement.md"
write_lifecycle_completion "$SID" 2
set +e
OUT="$(cd "$REVIEW_REPO" && printf '{"session_id":"claude-phase-2-selection"}' | env DEX_SESSION_ID="$SID" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=2 DEX_PHASE_HANDOFF=inline bash "$HOOK" 2>&1)"
RC=$?
set -e
assert_rc "Phase 2 without approved criteria is blocked" 2
assert_out_contains "missing Phase 2 criteria message shown" "approved review criteria missing"
assert_file_eq "missing Phase 2 criteria leaves phase active" "$DX_STATE_DIR/$SID.phase" "2"

write_review_criteria "$SID"
dx_review_approve_criteria "$SID" initial "$(dx_review_criteria_hash "$(dx_review_criteria_file "$SID")")" >/dev/null
write_lifecycle_completion "$SID" 2
set +e
OUT="$(cd "$REVIEW_REPO" && printf '{"session_id":"claude-phase-2-selection"}' | env DEX_SESSION_ID="$SID" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=2 DEX_PHASE_HANDOFF=inline bash "$HOOK" 2>&1)"
RC=$?
set -e
assert_rc "Phase 2 without a risk selection is blocked" 2
assert_out_contains "missing Phase 2 selection message shown" "review risk selection missing or stale"
assert_file_eq "missing Phase 2 selection leaves phase active" "$DX_STATE_DIR/$SID.phase" "2"

printf '%s\n' "candidate change" >> "$REVIEW_REPO/README.md"
dx_review_write_selection "$SID" normal lifecycle-agent bounded-production-change "$REVIEW_REPO"
write_lifecycle_completion "$SID" 2
set +e
OUT="$(cd "$REVIEW_REPO" && printf '{"session_id":"claude-phase-2-selection"}' | env DEX_SESSION_ID="$SID" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=2 DEX_PHASE_HANDOFF=inline bash "$HOOK" 2>&1)"
RC=$?
set -e
assert_rc "current Phase 2 risk selection reaches handoff" 2
assert_out_contains "Phase 2 selection emits Phase 3 handoff" "Phase Handoff: Phase 2 complete"
assert_file_eq "Phase 2 selection advances to Phase 3" "$DX_STATE_DIR/$SID.phase" "3"
rm -f "$DX_LOOP_DIR/$SID".* "$DX_STATE_DIR/$SID".*

# --- case 8: a legacy Phase 3 marker is rejected before review gates run ---
SID="repo-test-8-main"
touch "$DX_LOOP_DIR/$SID.active"
printf '%s\n' "inline" > "$DX_LOOP_DIR/$SID.handoff-mode"
printf '%s\n' "3" > "$DX_STATE_DIR/$SID.phase"
configure_lifecycle_completion "$SID" 3 "$ROOT/prompts/phase-audits/3-review-loop.md"
touch "$DX_LOOP_DIR/$SID.complete"
set +e
OUT="$(cd "$REVIEW_REPO" && printf '{\"session_id\":\"claude-phase-3-bypass\"}' | env DEX_SESSION_ID="$SID" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=3 DEX_PHASE_HANDOFF=inline bash "$HOOK" 2>&1)"
RC=$?
set -e
assert_rc "bare Phase 3 completion is blocked" 2
assert_out_contains "legacy marker diagnostic shown" "Legacy completion marker ignored"
assert_out_lacks "missing receipt does not hand off" "Phase Handoff"
assert_file_eq "missing receipt leaves Phase 3 active" "$DX_STATE_DIR/$SID.phase" "3"
if [[ ! -f "$DX_LOOP_DIR/$SID.complete" ]]; then
  report "rejected Phase 3 completion marker is removed" 0
else
  report "rejected Phase 3 completion marker is removed" 1
fi
rm -f "$DX_LOOP_DIR/$SID".* "$DX_STATE_DIR/$SID".*

# --- case 9: a current valid receipt authorizes the Phase 3 handoff ---
SID="repo-test-9-main"
touch "$DX_LOOP_DIR/$SID.active"
printf '%s\n' "inline" > "$DX_LOOP_DIR/$SID.handoff-mode"
printf '%s\n' "3" > "$DX_STATE_DIR/$SID.phase"
configure_lifecycle_completion "$SID" 3 "$ROOT/prompts/phase-audits/3-review-loop.md"
write_review_criteria "$SID"
dx_review_approve_criteria "$SID" initial "$(dx_review_criteria_hash "$(dx_review_criteria_file "$SID")")" >/dev/null
dx_review_write_selection "$SID" normal lifecycle-agent bounded-production-change "$REVIEW_REPO"
RECEIPT_FINGERPRINT=$(dx_review_scope_fingerprint "$REVIEW_REPO")
RECEIPT_CRITERIA_BINDING=$(dx_review_read_criteria_approval "$SID")
RECEIPT_POLICY_BINDING=$(dx_review_policy_resolve "$REVIEW_REPO" | cut -f4)
if dx_review_write_receipt "$SID" normal 3 3 "$REVIEW_REPO" \
  "$RECEIPT_CRITERIA_BINDING" "$RECEIPT_POLICY_BINDING"; then
  report "receipt cannot be minted without clean-pass ledger" 1
else
  report "receipt cannot be minted without clean-pass ledger" 0
fi
for ledger_iteration in 1 2 3; do
  receipt_pass_id="phase-clean-${ledger_iteration}"
  receipt_evidence="$TMP_DIR/phase-clean-${ledger_iteration}.evidence.json"
  receipt_context="$TMP_DIR/phase-clean-${ledger_iteration}.context.md"
  dx_test_write_clean_review_proof "$SID" "$receipt_pass_id" standard \
    "$RECEIPT_FINGERPRINT" "$RECEIPT_CRITERIA_BINDING" "$RECEIPT_POLICY_BINDING" \
    "$receipt_evidence" "$receipt_context"
  dx_review_ledger_append "$SID" "$ledger_iteration" "$receipt_pass_id" standard \
    "$RECEIPT_FINGERPRINT" "$RECEIPT_CRITERIA_BINDING" "$RECEIPT_POLICY_BINDING" \
    "$receipt_evidence" "$receipt_context"
done
dx_review_write_receipt "$SID" normal 3 3 "$REVIEW_REPO" \
  "$RECEIPT_CRITERIA_BINDING" "$RECEIPT_POLICY_BINDING"
write_lifecycle_completion "$SID" 3
set +e
OUT="$(cd "$REVIEW_REPO" && printf '{\"session_id\":\"claude-phase-3-receipt\"}' | env DEX_SESSION_ID="$SID" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=3 DEX_PHASE_HANDOFF=inline bash "$HOOK" 2>&1)"
RC=$?
set -e
assert_rc "valid Phase 3 receipt reaches the handoff" 2
assert_out_contains "valid receipt emits Phase 4 handoff" "Phase Handoff: Phase 3 complete"
assert_file_eq "valid receipt advances to Phase 4" "$DX_STATE_DIR/$SID.phase" "4"
if [[ ! -e "$(dx_review_proof_dir "$SID")" && ! -L "$(dx_review_proof_dir "$SID")" ]]; then
  report "Phase 3 handoff removes retained proof bundles" 0
else
  report "Phase 3 handoff removes retained proof bundles" 1
fi
rm -f "$DX_LOOP_DIR/$SID".* "$DX_STATE_DIR/$SID".*

# --- case 10: a finalizer rollback wins before Phase 3 acceptance ---
SID="repo-test-10-main"
touch "$DX_LOOP_DIR/$SID.active"
printf '%s\n' "inline" > "$DX_LOOP_DIR/$SID.handoff-mode"
printf '%s\n' "3" > "$DX_STATE_DIR/$SID.phase"
configure_lifecycle_completion "$SID" 3 "$ROOT/prompts/phase-audits/3-review-loop.md"
write_review_criteria "$SID"
dx_review_approve_criteria "$SID" initial \
  "$(dx_review_criteria_hash "$(dx_review_criteria_file "$SID")")" >/dev/null
dx_review_write_selection "$SID" normal lifecycle-agent \
  bounded-production-change "$REVIEW_REPO"
RECEIPT_FINGERPRINT=$(dx_review_scope_fingerprint "$REVIEW_REPO")
RECEIPT_CRITERIA_BINDING=$(dx_review_read_criteria_approval "$SID")
RECEIPT_POLICY_BINDING=$(dx_review_policy_resolve "$REVIEW_REPO" | cut -f4)
for ledger_iteration in 1 2 3; do
  receipt_pass_id="phase-race-clean-${ledger_iteration}"
  receipt_evidence="$TMP_DIR/phase-race-clean-${ledger_iteration}.evidence.json"
  receipt_context="$TMP_DIR/phase-race-clean-${ledger_iteration}.context.md"
  dx_test_write_clean_review_proof "$SID" "$receipt_pass_id" standard \
    "$RECEIPT_FINGERPRINT" "$RECEIPT_CRITERIA_BINDING" "$RECEIPT_POLICY_BINDING" \
    "$receipt_evidence" "$receipt_context"
  dx_review_ledger_append "$SID" "$ledger_iteration" "$receipt_pass_id" standard \
    "$RECEIPT_FINGERPRINT" "$RECEIPT_CRITERIA_BINDING" "$RECEIPT_POLICY_BINDING" \
    "$receipt_evidence" "$receipt_context"
done
dx_review_write_receipt "$SID" normal 3 3 "$REVIEW_REPO" \
  "$RECEIPT_CRITERIA_BINDING" "$RECEIPT_POLICY_BINDING"
write_lifecycle_completion "$SID" 3

# Pause the hook immediately before its second top-level transition-lock call.
# The first is preflight; the second is the late acceptance lock. A DEBUG trap
# installed only in this child process identifies that named call without
# depending on retries or unrelated lock activity inside validation helpers.
RACE_BASH_ENV="$TMP_DIR/phase-3-race-bash-env"
RACE_BARRIER="$TMP_DIR/phase-3-race-lock-waiting"
RACE_RELEASE="$TMP_DIR/phase-3-race-release"
RACE_LOCK_COUNT="$TMP_DIR/phase-3-race-lock-count"
RACE_OUT="$TMP_DIR/phase-3-race.out"
RACE_RC_FILE="$TMP_DIR/phase-3-race.rc"
cat > "$RACE_BASH_ENV" <<'SH'
#!/usr/bin/env bash

__dx_test_phase3_acceptance_barrier() {
  [[ "${1:-}" == 'dx_lifecycle_control_lock_acquire "$SESSION_ID"' ]] \
    || return 0
  count=$(cat "${DX_TEST_LOCK_COUNT:?}" 2>/dev/null || printf '0')
  count=$((count + 1))
  printf '%s\n' "$count" > "$DX_TEST_LOCK_COUNT"
  if [[ "$count" -eq 2 ]]; then
    : > "${DX_TEST_LOCK_BARRIER:?}"
    while [[ ! -e "${DX_TEST_LOCK_RELEASE:?}" ]]; do
      /bin/sleep 0.01
    done
  fi
}

trap '__dx_test_phase3_acceptance_barrier "$BASH_COMMAND"' DEBUG
SH
(
  set +e
  cd "$REVIEW_REPO" || exit 98
  printf '{"session_id":"claude-phase-3-race"}' | env \
    BASH_ENV="$RACE_BASH_ENV" DX_TEST_LOCK_BARRIER="$RACE_BARRIER" \
    DX_TEST_LOCK_RELEASE="$RACE_RELEASE" \
    DX_TEST_LOCK_COUNT="$RACE_LOCK_COUNT" \
    DEX_SESSION_ID="$SID" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=3 \
    DEX_PHASE_HANDOFF=inline bash "$HOOK" > "$RACE_OUT" 2>&1
  race_rc=$?
  printf '%s\n' "$race_rc" > "$RACE_RC_FILE"
) &
RACE_PID=$!
# This is an event wait, not a timing assertion. Parallel manifest lanes can
# delay hook startup, so leave enough time for the child to reach either event.
for _attempt in $(seq 1 600); do
  [[ -e "$RACE_BARRIER" || -e "$RACE_RC_FILE" ]] && break
  kill -0 "$RACE_PID" 2>/dev/null || break
  /bin/sleep 0.05
done
if [[ -e "$RACE_BARRIER" && ! -e "$RACE_RC_FILE" ]]; then
  report "Phase 3 hook reached the acceptance lock" 0
else
  report "Phase 3 hook reached the acceptance lock" 1
fi
if [[ "$(cat "$RACE_LOCK_COUNT" 2>/dev/null || true)" == "2" ]]; then
  report "Phase 3 barrier targets the late acceptance lock" 0
else
  report "Phase 3 barrier targets the late acceptance lock" 1
fi
dx_lifecycle_control_lock_acquire "$SID"
dx_review_revoke_receipt "$SID"
if ! dx_review_receipt_valid "$SID" "$REVIEW_REPO" \
  "$RECEIPT_CRITERIA_BINDING" "$RECEIPT_POLICY_BINDING"; then
  report "finalizer rollback invalidates the temporary receipt" 0
else
  report "finalizer rollback invalidates the temporary receipt" 1
fi
dx_lifecycle_control_lock_release "$SID"
touch "$RACE_RELEASE"
wait "$RACE_PID" 2>/dev/null || true
OUT=$(cat "$RACE_OUT" 2>/dev/null || true)
RC=$(cat "$RACE_RC_FILE" 2>/dev/null || printf '99')
assert_rc "revoked Phase 3 receipt blocks the handoff" 2
assert_out_contains "revoked receipt is rejected inside the lock" \
  "review receipt became stale before the transition committed"
assert_out_lacks "revoked receipt emits no Phase 4 handoff" "Phase Handoff"
assert_file_eq "revoked receipt leaves Phase 3 authoritative" \
  "$DX_STATE_DIR/$SID.phase" "3"
chmod -R u+w "$(dx_review_proof_dir "$SID")" 2>/dev/null || true
rm -rf "$(dx_review_proof_dir "$SID")"
rm -f "$DX_LOOP_DIR/$SID".* "$DX_STATE_DIR/$SID".*

printf 'phase-loop-ownership-test: %d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || assert_at $LINENO
