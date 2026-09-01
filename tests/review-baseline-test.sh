#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-review-baseline-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

export DEX_DIR="$ROOT"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_STATE_DIR="$TMP_DIR/state"
mkdir -p "$DX_LOOP_DIR" "$DX_STATE_DIR"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"

SESSION_ID="review-baseline-test"
BASELINE_FILE="$(dx_review_baseline_file "$SESSION_ID")"
METRICS_FILE="$(dx_review_metrics_file "$SESSION_ID")"
SCOPE="$(printf scope | dx_review_sha256_stdin)"
WORKING="$(printf working | dx_review_sha256_stdin)"
CRITERIA="standalone"
POLICY="$(dx_review_policy_binding 1 2 3)"

write_baseline() {
  local scope="$1" working="$2" status="$3"
  printf '%s\n' "{\"version\":1,\"scope_fingerprint\":\"${scope}\",\"working_fingerprint\":\"${working}\",\"criteria_binding\":\"${CRITERIA}\",\"policy_binding\":\"${POLICY}\",\"commands\":[{\"name\":\"full test suite\",\"command\":\"bash tests/run-all.sh\",\"status\":\"${status}\",\"duration_seconds\":42}]}" > "$BASELINE_FILE"
}

write_baseline "$SCOPE" "$WORKING" pass
dx_review_baseline_valid "$BASELINE_FILE" "$SCOPE" "$WORKING" "$CRITERIA" "$POLICY" \
  || fail "valid scope-bound baseline was rejected"
BASELINE_HASH="$(dx_review_baseline_hash "$BASELINE_FILE")"
[[ "$BASELINE_HASH" =~ ^[a-f0-9]{64}$ ]] || assert_at $LINENO
assert_eq $'1\t42' "$(dx_review_baseline_summary "$BASELINE_FILE")" \
  "baseline summary reports command count and duration"

CHANGED_WORKING="$(printf changed | dx_review_sha256_stdin)"
if dx_review_baseline_valid "$BASELINE_FILE" "$SCOPE" "$CHANGED_WORKING" "$CRITERIA" "$POLICY"; then
  fail "baseline survived a working-tree fingerprint change"
fi

write_baseline "$SCOPE" "$WORKING" fail
if dx_review_baseline_valid "$BASELINE_FILE" "$SCOPE" "$WORKING" "$CRITERIA" "$POLICY"; then
  fail "failed full-suite result was reusable"
fi

write_baseline "$SCOPE" "$WORKING" pass
ln -s "$BASELINE_FILE" "$TMP_DIR/baseline-link"
if dx_review_baseline_valid "$TMP_DIR/baseline-link" "$SCOPE" "$WORKING" "$CRITERIA" "$POLICY"; then
  fail "symlinked baseline was accepted"
fi

printf '%s\n' '{"version":1,"context_seconds":3,"checks_seconds":42,"scout_seconds":7,"verifier_seconds":2}' > "$METRICS_FILE"
dx_review_metrics_valid "$METRICS_FILE" \
  || fail "valid review stage metrics were rejected"
assert_eq $'3\t42\t7\t2' "$(dx_review_metrics_summary "$METRICS_FILE")" \
  "stage metrics summary preserves each duration"

dx_cleanup_session "$SESSION_ID"
[[ ! -e "$BASELINE_FILE" ]] || fail "session cleanup retained the deterministic baseline"
[[ ! -e "$METRICS_FILE" ]] || fail "session cleanup retained review metrics"

printf '%s\n' "review-baseline-test passed"
