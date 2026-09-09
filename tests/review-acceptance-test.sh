#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
python3 "$ROOT/tests/review-acceptance-storage-test.py"
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/dex-review-acceptance.XXXXXX")
cleanup() { chmod -R u+w "$TMP_DIR" 2>/dev/null || true; rm -rf "$TMP_DIR"; }
trap cleanup EXIT
unset DEX_SESSION_ID DEX_REVIEW_CRITERIA_FILE DEX_REVIEW_CRITERIA_BINDING DEX_RUN_ID
export DEX_DIR="$ROOT" DX_LOOP_DIR="$TMP_DIR/loops" DX_STATE_DIR="$TMP_DIR/state"
export DX_RUN_ROOT="$TMP_DIR/runs" DX_ARTIFACT_DIR="$TMP_DIR/artifacts" DX_TOOL_DIR="$TMP_DIR/tools"
mkdir -p "$DX_LOOP_DIR" "$DX_STATE_DIR"
source "$ROOT/lib/common.sh"
source "$ROOT/tests/review-proof-fixture.sh"

REPO="$TMP_DIR/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.name "Dex Test"
git -C "$REPO" config user.email dex@example.test
git -C "$REPO" config core.hooksPath /dev/null
git -C "$REPO" config commit.gpgSign false
printf 'fixture\n' > "$REPO/file.txt"
git -C "$REPO" add file.txt
git -C "$REPO" commit -qm 'test: initialize acceptance fixture'
cd "$REPO"
POLICY=$(dx_review_policy_resolve "$REPO" | cut -f4)

prepare() {
  SID="$1" CHILD="$1-pass" RESULT="${2:-CLEAN}"
  BEFORE=$(dx_review_scope_fingerprint "$REPO")
  GENERATION=$(dx_completion_loop_activate "$CHILD" child review-pass 3)
  dx_test_write_clean_review_proof "$CHILD" "$CHILD" light "$BEFORE" standalone "$POLICY" \
    "$(dx_review_evidence_file "$CHILD")" "$(dx_review_context_file "$CHILD")"
  FINDINGS=$(dx_review_empty_findings_hash)
  CLEAN=1 TOTAL=0 LEDGER_OP=append FINDINGS_OP=keep
  if [[ "$RESULT" == FINDINGS_FIXED:3 ]]; then
    FINDINGS=123456789abcdef0 CLEAN=0 TOTAL=3 LEDGER_OP=reset FINDINGS_OP=append
    printf 'accepted fix\n' >> "$REPO/file.txt"
    python3 - "$(dx_review_evidence_file "$CHILD")" <<'PY'
import json
from pathlib import Path
import sys
target = Path(sys.argv[1])
data = json.loads(target.read_text())
data.update(verified_findings=3, fixes_applied=3)
target.write_text(json.dumps(data))
PY
  fi
  dx_completion_write_receipt "$CHILD" "$GENERATION"
  dx_review_write_state "$SID" small 1 0 0 "$REPO" standalone "$POLICY"
  dx_review_write_selection "$SID" small environment operator-override "$REPO" 1 standalone "$POLICY"
  dx_lifecycle_control_lock_acquire "$SID"
  dx_review_acceptance_begin "$SID" "$REPO" "$CHILD" "$CHILD" "$GENERATION" "$RESULT" \
    "$FINDINGS" light small 1 1 "$CLEAN" "$TOTAL" "$(dx_review_scope_fingerprint "$REPO")" \
    "$(dx_review_working_fingerprint "$REPO")" standalone "$POLICY" environment operator-override \
    "$LEDGER_OP" "$FINDINGS_OP" "$BEFORE" "$(dx_review_scope_descriptor "$REPO")" main \
    "$(git rev-parse HEAD)"
}

# Interrupt every durable boundary, then recover the exact pass without rerunning
# a provider. A complete wave must survive even before the final gate receipt.
for result in CLEAN FINDINGS_FIXED:3; do
  for point in stage seal commit install retirement; do
    prepare "accept-${result%%:*}-${point}" "$result"
    ACCEPT_RC=0
    (
      __dx_review_acceptance_store() {
        local operation="$1" acceptance_session="$2"
        shift 2
        python3 "$DEX_DIR/scripts/review_acceptance.py" "$operation" "$DX_LOOP_DIR" "$acceptance_session" "$@" || return $?
        [[ "$operation" != "$point" ]] || return 71
      }
      if [[ "$point" == retirement ]]; then
        __dx_review_acceptance_retire_child() {
          dx_completion_consume "$1" child review-pass 3 "$2" || return 1
          return 71
        }
      fi
      dx_review_acceptance_finish "$SID" "$REPO" standalone "$POLICY"
    ) || ACCEPT_RC=$?
    [[ "$ACCEPT_RC" -ne 0 ]] || assert_at "$LINENO"
    assert_file "$(dx_review_acceptance_dir "$SID")/record.json"
    dx_review_acceptance_finish "$SID" "$REPO" standalone "$POLICY"
    dx_review_acceptance_finish "$SID" "$REPO" standalone "$POLICY"
    __dx_review_acceptance_store remove "$SID"
    assert_no_file "$(dx_completion_expectation_file "$CHILD")"
    assert_no_file "$(dx_active_file "$CHILD")"
    [[ ! -e "$(dx_review_acceptance_dir "$SID")" ]] || assert_at "$LINENO"
    dx_review_ledger_valid "$SID" "$CLEAN" "$(dx_review_scope_fingerprint "$REPO")" standalone "$POLICY" light || assert_at "$LINENO"
    assert_eq "$CLEAN" "$(cut -f5 "$(dx_review_state_file "$SID")")" 'recovered clean count'
    assert_eq "$TOTAL" "$(dx_review_state_fixed_total "$SID")" 'recovered fix count'
    if [[ "$RESULT" == FINDINGS_FIXED:3 ]]; then
      assert_eq "$FINDINGS" "$(cat "$(dx_findings_file "$SID")")" 'findings applied exactly once'
    fi
    dx_lifecycle_control_lock_release "$SID"
    dx_cleanup_session "$SID"
  done
done

prepare changed-scope
printf 'external edit\n' >> "$REPO/file.txt"
assert_rejected 'changed scope cannot replay a wave' dx_review_acceptance_finish "$SID" "$REPO" standalone "$POLICY"
dx_completion_receipt_valid "$CHILD" child review-pass 3 "$GENERATION" || assert_at "$LINENO"
dx_lifecycle_control_lock_release "$SID"

prepare changed-proof
printf 'changed proof\n' >> "$(dx_review_acceptance_dir "$SID")/context.md"
assert_rejected 'changed retained evidence cannot replay a wave' dx_review_acceptance_finish "$SID" "$REPO" standalone "$POLICY"
dx_completion_receipt_valid "$CHILD" child review-pass 3 "$GENERATION" || assert_at "$LINENO"
dx_lifecycle_control_lock_release "$SID"

printf 'review-acceptance tests passed\n'
