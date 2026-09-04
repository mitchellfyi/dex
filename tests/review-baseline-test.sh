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

WRITTEN_FILE="$TMP_DIR/written-baseline.json"
dx_review_baseline_write "$WRITTEN_FILE" "$SCOPE" "$WORKING" \
  "$CRITERIA" "$POLICY" "full test suite" "bash tests/run-all.sh" 42
dx_review_baseline_valid "$WRITTEN_FILE" "$SCOPE" "$WORKING" \
  "$CRITERIA" "$POLICY" || fail "baseline writer produced invalid evidence"
if dx_review_baseline_write "$WRITTEN_FILE" "$SCOPE" "$WORKING" \
  "$CRITERIA" "$POLICY" "full test suite" "bash tests/run-all.sh" invalid; then
  fail "baseline writer accepted an invalid duration"
fi

PUBLISH_REPO="$TMP_DIR/publish-repo"
PUBLISH_SESSION="review-baseline-publish"
git init -q -b main "$PUBLISH_REPO"
git -C "$PUBLISH_REPO" config user.name "Dex Test"
git -C "$PUBLISH_REPO" config user.email "dex-test@example.com"
printf '%s\n' "baseline fixture" > "$PUBLISH_REPO/app.txt"
git -C "$PUBLISH_REPO" add app.txt
git -C "$PUBLISH_REPO" commit -qm "test: initialize baseline fixture"
dx_review_baseline_publish "$PUBLISH_SESSION" "$PUBLISH_REPO" \
  "full test suite" "bash tests/run-all.sh" 17
PUBLISHED_FILE="$(dx_review_baseline_file "$PUBLISH_SESSION")"
PUBLISHED_SCOPE="$(dx_review_scope_fingerprint "$PUBLISH_REPO")"
PUBLISHED_WORKING="$(dx_review_working_fingerprint "$PUBLISH_REPO")"
dx_review_baseline_valid "$PUBLISHED_FILE" "$PUBLISHED_SCOPE" \
  "$PUBLISHED_WORKING" standalone "$POLICY" \
  || fail "published implementation baseline was not reusable"

printf '%s\n' '{"version":1,"context_seconds":3,"checks_seconds":42,"scout_seconds":7,"verifier_seconds":2}' > "$METRICS_FILE"
dx_review_metrics_valid "$METRICS_FILE" \
  || fail "valid review stage metrics were rejected"
assert_eq $'3\t42\t7\t2' "$(dx_review_metrics_summary "$METRICS_FILE")" \
  "stage metrics summary preserves each duration"

dx_review_metrics_start "$METRICS_FILE"
for review_stage in context checks scout verifier fixes; do
  dx_review_metrics_mark "$METRICS_FILE" "$review_stage"
done
dx_review_metrics_finish "$METRICS_FILE"
dx_review_metrics_valid "$METRICS_FILE" \
  || fail "wrapper-clock review stage metrics were rejected"
METRICS_DETAIL="$(dx_review_metrics_detailed_summary "$METRICS_FILE")"
IFS=$'\t' read -r METRIC_CONTEXT METRIC_CHECKS METRIC_SCOUT METRIC_VERIFIER \
  METRIC_FIXES METRIC_COMPLETE METRIC_SOURCE <<EOF
$METRICS_DETAIL
EOF
for METRIC_VALUE in "$METRIC_CONTEXT" "$METRIC_CHECKS" "$METRIC_SCOUT" \
    "$METRIC_VERIFIER" "$METRIC_FIXES"; do
  [[ "$METRIC_VALUE" =~ ^[0-9]+$ ]] \
    || fail "wrapper-clock stage metrics contained a non-integer duration"
done
[[ "$METRIC_COMPLETE" == "true" && "$METRIC_SOURCE" == "wrapper-clock" ]] \
  || fail "wrapper-clock stage metrics lost their completeness or source"
if dx_review_metrics_mark "$METRICS_FILE" checks; then
  fail "finished wrapper-clock metrics accepted another stage"
fi

dx_cleanup_session "$SESSION_ID"
[[ ! -e "$BASELINE_FILE" ]] || fail "session cleanup retained the deterministic baseline"
[[ ! -e "$METRICS_FILE" ]] || fail "session cleanup retained review metrics"
dx_cleanup_session "$PUBLISH_SESSION"
[[ ! -e "$PUBLISHED_FILE" ]] || fail "session cleanup retained the published baseline"

printf '%s\n' "review-baseline-test passed"
