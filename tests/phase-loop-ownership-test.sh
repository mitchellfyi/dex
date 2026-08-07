#!/usr/bin/env bash
set -euo pipefail

# Tests for the Stop-hook ownership guard and review-pass isolation in
# hooks/phase-loop.sh:
#   - a bystander Claude session (different hook session_id) resolving the same
#     dex session id must stay inert instead of being captured by the loop
#   - the owning session claims/reclaims the loop and still gets the audit gate
#   - a review-wave pass (DEX_REVIEW_PASS_ACTIVE=1) completing must exit via
#     the plain loop-complete path, never the inline phase handoff that
#     advances the lifecycle phase and instructs commit/push

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/hooks/phase-loop.sh"
export DEX_DIR="$ROOT"

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
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_STATE_DIR="$TMP_DIR/phases"
export DX_RUN_ROOT="$TMP_DIR/runs"
mkdir -p "$DX_LOOP_DIR" "$DX_STATE_DIR"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

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
  if printf '%s' "$OUT" | grep -qF -- "$2"; then report "$1" 0; else report "$1" 1; fi
}

assert_out_lacks() { # <desc> <fixed-string>
  if printf '%s' "$OUT" | grep -qF -- "$2"; then report "$1" 1; else report "$1" 0; fi
}

assert_file_eq() { # <desc> <path> <expected-content>
  if [[ "$(cat "$2" 2>/dev/null)" == "$3" ]]; then report "$1" 0; else report "$1" 1; fi
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

write_review_evidence() { # <session-id> <result> <fingerprint>
  local session_id="$1" result="$2" fingerprint="$3" checks=pass verifier=pass
  case "$result" in
    BLOCKED:*|CHURN:*) checks=partial; verifier=not-run ;;
    ESCALATE:*|ESCALATE_THOROUGH:*) checks=partial; verifier=pass ;;
  esac
  printf '{"version":2,"scope_fingerprint":"%s","criteria_binding":"standalone","criteria_coverage":{"acceptance_criteria":[],"objectives":[],"verification_requirements":[]},"deterministic_checks":"%s","coverage":["correctness","security","contracts","tests","architecture"],"verifier":"%s","verified_findings":0,"fixes_applied":0}\n' \
    "$fingerprint" "$checks" "$verifier" > "$(dx_review_evidence_file "$session_id")"
}

REVIEW_SCOPE_FINGERPRINT=$(dx_review_scope_fingerprint "$ROOT")

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

# --- case 2: unclaimed file-activated loop is claimed by first stopper ---
SID="repo-test-2-main"
touch "$DX_LOOP_DIR/$SID.active"
set +e
OUT="$(printf '{"session_id":"claude-first"}' | env DEX_SESSION_ID="$SID" bash "$HOOK" 2>&1)"
RC=$?
set -e
assert_rc "unclaimed loop blocks stop for claimer" 2
assert_file_eq "claim recorded" "$DX_LOOP_DIR/$SID.owner" "claude-first"
rm -f "$DX_LOOP_DIR/$SID".*

# --- case 3: env-activated session reclaims a stale claim ---
SID="repo-test-3-main"
touch "$DX_LOOP_DIR/$SID.active"
printf '%s\n' "claude-stale" > "$DX_LOOP_DIR/$SID.owner"
set +e
OUT="$(printf '{"session_id":"claude-relaunch"}' | env DEX_SESSION_ID="$SID" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=2 bash "$HOOK" 2>&1)"
RC=$?
set -e
assert_rc "env-activated session proceeds" 2
assert_file_eq "env-activated session reclaims" "$DX_LOOP_DIR/$SID.owner" "claude-relaunch"
rm -f "$DX_LOOP_DIR/$SID".*

# --- case 4: completed review pass never runs the inline phase handoff ---
SID="repo-test-4-main-pass-1-999"
touch "$DX_LOOP_DIR/$SID.active"
printf '%s\n' "inline" > "$DX_LOOP_DIR/$SID.handoff-mode"
printf '%s\n' "3" > "$DX_STATE_DIR/$SID.phase"
printf '%s\n' "3:PHASE_3_COMPLETE:$ROOT/prompts/phase-audits/3-review.md:1" > "$DX_LOOP_DIR/$SID.config"
printf '%s\n' "CLEAN" > "$DX_LOOP_DIR/$SID.review-result"
write_review_context "$SID"
write_review_evidence "$SID" CLEAN "$REVIEW_SCOPE_FINGERPRINT"
printf '%s\n' "0123456789abcdef" > "$DX_LOOP_DIR/$SID.findings"
touch "$DX_LOOP_DIR/$SID.complete"
set +e
OUT="$(printf '{"session_id":"claude-wave"}' | env DEX_SESSION_ID="$SID" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=3 DEX_REVIEW_PASS_ACTIVE=1 DEX_REVIEW_PROFILE=light DEX_REVIEW_SCOPE_FINGERPRINT="$REVIEW_SCOPE_FINGERPRINT" bash "$HOOK" 2>&1)"
RC=$?
set -e
assert_rc "review pass allowed to stop" 0
assert_out_contains "review pass gets plain loop-complete stop" "Dex loop complete"
assert_out_lacks "review pass did not trigger phase handoff" "Phase Handoff"
assert_file_eq "phase state not advanced by review pass" "$DX_STATE_DIR/$SID.phase" "3"
# The launching wrapper harvests the pass findings hash into the parent
# session stuck-loop history after the wave exits, so the hook must leave it.
assert_file_eq "findings hash preserved for wrapper harvest" "$DX_LOOP_DIR/$SID.findings" "0123456789abcdef"
if [[ -f "$DX_LOOP_DIR/$SID.complete" ]]; then report "completion receipt preserved for wrapper harvest" 0; else report "completion receipt preserved for wrapper harvest" 1; fi
rm -f "$DX_LOOP_DIR/$SID".* "$DX_STATE_DIR/$SID".*

# --- case 5: review pass with invalid result is held open ---
SID="repo-test-5-main-pass-2-999"
touch "$DX_LOOP_DIR/$SID.active"
printf '%s\n' "3:PHASE_3_COMPLETE:$ROOT/prompts/phase-audits/3-review.md:1" > "$DX_LOOP_DIR/$SID.config"
printf '%s\n' "not-a-result" > "$DX_LOOP_DIR/$SID.review-result"
touch "$DX_LOOP_DIR/$SID.complete"
set +e
OUT="$(printf '{"session_id":"claude-wave2"}' | env DEX_SESSION_ID="$SID" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=3 DEX_REVIEW_PASS_ACTIVE=1 bash "$HOOK" 2>&1)"
RC=$?
set -e
assert_rc "invalid result blocks review pass stop" 2
assert_out_contains "invalid result message shown" "result signal missing or invalid"
rm -f "$DX_LOOP_DIR/$SID".*

# --- case 6: a review pass cannot complete without a substantive context pack ---
SID="repo-test-6-main-pass-3-999"
touch "$DX_LOOP_DIR/$SID.active"
printf '%s\n' "3:PHASE_3_COMPLETE:$ROOT/prompts/phase-audits/3-review.md:1" > "$DX_LOOP_DIR/$SID.config"
printf '%s\n' "CLEAN" > "$DX_LOOP_DIR/$SID.review-result"
printf '%s\n' "   " > "$DX_LOOP_DIR/$SID.review-context"
printf '%s\n' "0123456789abcdef" > "$DX_LOOP_DIR/$SID.findings"
touch "$DX_LOOP_DIR/$SID.complete"
set +e
OUT="$(printf '{"session_id":"claude-wave3"}' | env DEX_SESSION_ID="$SID" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=3 DEX_REVIEW_PASS_ACTIVE=1 bash "$HOOK" 2>&1)"
RC=$?
set -e
assert_rc "empty context pack blocks review pass stop" 2
assert_out_contains "empty context pack message shown" "context pack missing or empty"
rm -f "$DX_LOOP_DIR/$SID".*

# --- case 7: a review pass must write exactly one valid findings hash ---
SID="repo-test-7-main-pass-4-999"
touch "$DX_LOOP_DIR/$SID.active"
printf '%s\n' "3:PHASE_3_COMPLETE:$ROOT/prompts/phase-audits/3-review.md:1" > "$DX_LOOP_DIR/$SID.config"
printf '%s\n' "CLEAN" > "$DX_LOOP_DIR/$SID.review-result"
write_review_context "$SID"
write_review_evidence "$SID" CLEAN "$REVIEW_SCOPE_FINGERPRINT"
printf '%s\n%s\n' "0123456789abcdef" "fedcba9876543210" > "$DX_LOOP_DIR/$SID.findings"
touch "$DX_LOOP_DIR/$SID.complete"
set +e
OUT="$(printf '{"session_id":"claude-wave4"}' | env DEX_SESSION_ID="$SID" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=3 DEX_REVIEW_PASS_ACTIVE=1 DEX_REVIEW_PROFILE=light DEX_REVIEW_SCOPE_FINGERPRINT="$REVIEW_SCOPE_FINGERPRINT" bash "$HOOK" 2>&1)"
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
  OUT="$(printf '{"session_id":"claude-limit"}' | env DEX_SESSION_ID="$SID" "$LIMIT_NAME=abc" bash "$HOOK" 2>&1)"
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
OUT="$(printf '{"session_id":"claude-limit"}' | env DEX_SESSION_ID="$SID" DEX_LOOP_MAX_ITERATIONS=9999999999999999 bash "$HOOK" 2>&1)"
RC=$?
set -e
assert_rc "oversized loop limit blocks cleanly" 2
assert_out_contains "oversized loop limit names the invalid setting" "must be a non-negative decimal with at most 15 digits"
rm -f "$DX_LOOP_DIR/$SID".*

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
  touch "$DX_LOOP_DIR/$SID.active"
  printf '%s\n' "3:PHASE_3_COMPLETE:$ROOT/prompts/phase-audits/3-review.md:1" > "$DX_LOOP_DIR/$SID.config"
  printf '%s\n' "$review_result" > "$DX_LOOP_DIR/$SID.review-result"
  write_review_context "$SID"
  write_review_evidence "$SID" "$review_result" "$REVIEW_SCOPE_FINGERPRINT"
  printf '%s\n' "0123456789abcdef" > "$DX_LOOP_DIR/$SID.findings"
  touch "$DX_LOOP_DIR/$SID.complete"
  set +e
  OUT="$(printf '{\"session_id\":\"claude-wave-alias-%s\"}' "$case_number" | env DEX_SESSION_ID="$SID" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=3 DEX_REVIEW_PASS_ACTIVE=1 DEX_REVIEW_PROFILE=light DEX_REVIEW_SCOPE_FINGERPRINT="$REVIEW_SCOPE_FINGERPRINT" bash "$HOOK" 2>&1)"
  RC=$?
  set -e
  assert_rc "review result '$review_result' is accepted" 0
  assert_out_contains "review result '$review_result' exits the pass" "Dex loop complete"
  rm -f "$DX_LOOP_DIR/$SID".*
done

# FINDINGS_FIXED and FINDINGS must report at least one finding.
SID="repo-test-6-zero-main-pass"
touch "$DX_LOOP_DIR/$SID.active"
printf '%s\n' "3:PHASE_3_COMPLETE:$ROOT/prompts/phase-audits/3-review.md:1" > "$DX_LOOP_DIR/$SID.config"
printf '%s\n' "FINDINGS_FIXED:0" > "$DX_LOOP_DIR/$SID.review-result"
touch "$DX_LOOP_DIR/$SID.complete"
set +e
OUT="$(printf '{\"session_id\":\"claude-wave-zero\"}' | env DEX_SESSION_ID="$SID" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=3 DEX_REVIEW_PASS_ACTIVE=1 bash "$HOOK" 2>&1)"
RC=$?
set -e
assert_rc "zero-finding result is rejected" 2
assert_out_contains "zero-finding result shows validation message" "result signal missing or invalid"
rm -f "$DX_LOOP_DIR/$SID".*

# --- case 6b: Phase 1 preserves approved criteria before implementation ---
SID="repo-test-6b-main"
touch "$DX_LOOP_DIR/$SID.active" "$DX_LOOP_DIR/$SID.phase-1.ready" "$DX_LOOP_DIR/$SID.complete"
printf '%s\n' "inline" > "$DX_LOOP_DIR/$SID.handoff-mode"
printf '%s\n' "1" > "$DX_STATE_DIR/$SID.phase"
printf '%s\n' "1:PHASE_1_COMPLETE:$ROOT/prompts/phase-audits/1-plan.md:1" > "$DX_LOOP_DIR/$SID.config"
set +e
OUT="$(cd "$REVIEW_REPO" && printf '{"session_id":"claude-phase-1-criteria"}' | env DEX_SESSION_ID="$SID" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=1 DEX_PHASE_HANDOFF=inline bash "$HOOK" 2>&1)"
RC=$?
set -e
assert_rc "Phase 1 without approved criteria is blocked" 2
assert_out_contains "missing Phase 1 criteria message shown" "approved review criteria missing"
assert_file_eq "missing Phase 1 criteria leaves phase active" "$DX_STATE_DIR/$SID.phase" "1"

write_review_criteria "$SID"
touch "$DX_LOOP_DIR/$SID.complete"
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
touch "$DX_LOOP_DIR/$SID.phase-2.ready" "$DX_LOOP_DIR/$SID.complete"
printf '%s\n' "2:PHASE_2_COMPLETE:$ROOT/prompts/phase-audits/2-implement.md:1" > "$DX_LOOP_DIR/$SID.config"
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
touch "$DX_LOOP_DIR/$SID.active" "$DX_LOOP_DIR/$SID.phase-2.ready" "$DX_LOOP_DIR/$SID.complete"
printf '%s\n' "inline" > "$DX_LOOP_DIR/$SID.handoff-mode"
printf '%s\n' "2" > "$DX_STATE_DIR/$SID.phase"
printf '%s\n' "2:PHASE_2_COMPLETE:$ROOT/prompts/phase-audits/2-implement.md:1" > "$DX_LOOP_DIR/$SID.config"
set +e
OUT="$(cd "$REVIEW_REPO" && printf '{"session_id":"claude-phase-2-selection"}' | env DEX_SESSION_ID="$SID" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=2 DEX_PHASE_HANDOFF=inline bash "$HOOK" 2>&1)"
RC=$?
set -e
assert_rc "Phase 2 without approved criteria is blocked" 2
assert_out_contains "missing Phase 2 criteria message shown" "approved review criteria missing"
assert_file_eq "missing Phase 2 criteria leaves phase active" "$DX_STATE_DIR/$SID.phase" "2"

write_review_criteria "$SID"
dx_review_approve_criteria "$SID" initial "$(dx_review_criteria_hash "$(dx_review_criteria_file "$SID")")" >/dev/null
touch "$DX_LOOP_DIR/$SID.complete"
set +e
OUT="$(cd "$REVIEW_REPO" && printf '{"session_id":"claude-phase-2-selection"}' | env DEX_SESSION_ID="$SID" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=2 DEX_PHASE_HANDOFF=inline bash "$HOOK" 2>&1)"
RC=$?
set -e
assert_rc "Phase 2 without a risk selection is blocked" 2
assert_out_contains "missing Phase 2 selection message shown" "review risk selection missing or stale"
assert_file_eq "missing Phase 2 selection leaves phase active" "$DX_STATE_DIR/$SID.phase" "2"

printf '%s\n' "candidate change" >> "$REVIEW_REPO/README.md"
dx_review_write_selection "$SID" normal lifecycle-agent bounded-production-change "$REVIEW_REPO"
touch "$DX_LOOP_DIR/$SID.complete"
set +e
OUT="$(cd "$REVIEW_REPO" && printf '{"session_id":"claude-phase-2-selection"}' | env DEX_SESSION_ID="$SID" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=2 DEX_PHASE_HANDOFF=inline bash "$HOOK" 2>&1)"
RC=$?
set -e
assert_rc "current Phase 2 risk selection reaches handoff" 2
assert_out_contains "Phase 2 selection emits Phase 3 handoff" "Phase Handoff: Phase 2 complete"
assert_file_eq "Phase 2 selection advances to Phase 3" "$DX_STATE_DIR/$SID.phase" "3"
rm -f "$DX_LOOP_DIR/$SID".* "$DX_STATE_DIR/$SID".*

# --- case 8: a bare Phase 3 completion marker cannot bypass dxreviewloop ---
SID="repo-test-8-main"
touch "$DX_LOOP_DIR/$SID.active"
printf '%s\n' "inline" > "$DX_LOOP_DIR/$SID.handoff-mode"
printf '%s\n' "3" > "$DX_STATE_DIR/$SID.phase"
printf '%s\n' "3:PHASE_3_COMPLETE:$ROOT/prompts/phase-audits/3-review-loop.md:1" > "$DX_LOOP_DIR/$SID.config"
touch "$DX_LOOP_DIR/$SID.complete"
set +e
OUT="$(cd "$REVIEW_REPO" && printf '{\"session_id\":\"claude-phase-3-bypass\"}' | env DEX_SESSION_ID="$SID" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=3 DEX_PHASE_HANDOFF=inline bash "$HOOK" 2>&1)"
RC=$?
set -e
assert_rc "bare Phase 3 completion is blocked" 2
assert_out_contains "missing receipt message shown" "review receipt missing or stale"
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
printf '%s\n' "3:PHASE_3_COMPLETE:$ROOT/prompts/phase-audits/3-review-loop.md:1" > "$DX_LOOP_DIR/$SID.config"
write_review_criteria "$SID"
dx_review_approve_criteria "$SID" initial "$(dx_review_criteria_hash "$(dx_review_criteria_file "$SID")")" >/dev/null
dx_review_write_selection "$SID" normal lifecycle-agent bounded-production-change "$REVIEW_REPO"
RECEIPT_FINGERPRINT=$(dx_review_scope_fingerprint "$REVIEW_REPO")
if dx_review_write_receipt "$SID" normal 6 6 "$REVIEW_REPO"; then
  report "receipt cannot be minted without clean-pass ledger" 1
else
  report "receipt cannot be minted without clean-pass ledger" 0
fi
for ledger_iteration in 1 2 3 4 5 6; do
  dx_review_ledger_append "$SID" "$ledger_iteration" "phase-clean-${ledger_iteration}" "$RECEIPT_FINGERPRINT" "$(printf '%016x' "$ledger_iteration")"
done
dx_review_write_receipt "$SID" normal 6 6 "$REVIEW_REPO"
touch "$DX_LOOP_DIR/$SID.complete"
set +e
OUT="$(cd "$REVIEW_REPO" && printf '{\"session_id\":\"claude-phase-3-receipt\"}' | env DEX_SESSION_ID="$SID" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=3 DEX_PHASE_HANDOFF=inline bash "$HOOK" 2>&1)"
RC=$?
set -e
assert_rc "valid Phase 3 receipt reaches the handoff" 2
assert_out_contains "valid receipt emits Phase 4 handoff" "Phase Handoff: Phase 3 complete"
assert_file_eq "valid receipt advances to Phase 4" "$DX_STATE_DIR/$SID.phase" "4"
rm -f "$DX_LOOP_DIR/$SID".* "$DX_STATE_DIR/$SID".*

printf 'phase-loop-ownership-test: %d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
