#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ROOT/scripts/maintenance-state.py"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-maintenance-state-test.XXXXXX")"

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

ARTIFACT_ROOT="$TEST_DIR/artifacts/maintenance"
PUBLISH_RUN_ID="maintain-20260807T120000Z-aaaaaaaa-u-12345678"
RESPONSE_RUN_ID="maintain-20260807T120001Z-bbbbbbbb-u-87654321"
PUBLISH_REPORT="$ARTIFACT_ROOT/$PUBLISH_RUN_ID/report.md"
RESPONSE_REPORT="$ARTIFACT_ROOT/$RESPONSE_RUN_ID/report.md"
mkdir -p "$(dirname "$PUBLISH_REPORT")" "$(dirname "$RESPONSE_REPORT")"
printf '# Publish report\n' > "$PUBLISH_REPORT"
printf '# Response report\n' > "$RESPONSE_REPORT"

assert_contains() {
  local needle="$1" file="$2"
  if ! grep -Fq "$needle" "$file"; then
    printf 'missing expected text: %s\n' "$needle" >&2
    cat "$file" >&2
    exit 1
  fi
}

hash_file() {
  python3 - "$1" <<'PY'
import hashlib
import sys
from pathlib import Path

print(hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest())
PY
}

expect_failure() {
  local label="$1"
  shift
  if "$@" > "$TEST_DIR/failure.out" 2>&1; then
    printf 'expected failure: %s\n' "$label" >&2
    exit 1
  fi
  assert_contains "maintenance state error:" "$TEST_DIR/failure.out"
}

REPORT_IO_RUN_ID="maintain-20260807T115959Z-report-u-12345678"
REPORT_IO_DIR="$ARTIFACT_ROOT/$REPORT_IO_RUN_ID"
REPORT_IO_FILE="$REPORT_IO_DIR/report.md"
REPORT_IO_INPUT="$TEST_DIR/report-input"
mkdir -p "$REPORT_IO_DIR"
printf '# Safe report\n' > "$REPORT_IO_INPUT"
python3 "$TOOL" report-io \
  --mode create \
  --report "$REPORT_IO_FILE" \
  --artifact-root "$ARTIFACT_ROOT" \
  --input "$REPORT_IO_INPUT"
printf '\nStatus: complete\n' > "$REPORT_IO_INPUT"
python3 "$TOOL" report-io \
  --mode append \
  --report "$REPORT_IO_FILE" \
  --artifact-root "$ARTIFACT_ROOT" \
  --input "$REPORT_IO_INPUT"
assert_contains "Status: complete" "$REPORT_IO_FILE"
expect_failure "existing report replacement" python3 "$TOOL" report-io \
  --mode create \
  --report "$REPORT_IO_FILE" \
  --artifact-root "$ARTIFACT_ROOT" \
  --input "$REPORT_IO_INPUT"

printf 'report victim\n' > "$TEST_DIR/report-victim"
rm -f "$REPORT_IO_FILE"
ln -s "$TEST_DIR/report-victim" "$REPORT_IO_FILE"
expect_failure "linked report append" python3 "$TOOL" report-io \
  --mode append \
  --report "$REPORT_IO_FILE" \
  --artifact-root "$ARTIFACT_ROOT" \
  --input "$REPORT_IO_INPUT"
[[ "$(cat "$TEST_DIR/report-victim")" == "report victim" ]]

rm -f "$REPORT_IO_FILE"
printf 'single report\n' > "$REPORT_IO_FILE"
ln "$REPORT_IO_FILE" "$TEST_DIR/report-hardlink"
expect_failure "hard-linked report append" python3 "$TOOL" report-io \
  --mode append \
  --report "$REPORT_IO_FILE" \
  --artifact-root "$ARTIFACT_ROOT" \
  --input "$REPORT_IO_INPUT"
[[ "$(cat "$REPORT_IO_FILE")" == "single report" ]]

LINKED_REPORT_RUN_ID="maintain-20260807T115958Z-linked-u-12345678"
mkdir -p "$TEST_DIR/external-report-dir"
ln -s "$TEST_DIR/external-report-dir" "$ARTIFACT_ROOT/$LINKED_REPORT_RUN_ID"
expect_failure "linked report directory" python3 "$TOOL" report-io \
  --mode create \
  --report "$ARTIFACT_ROOT/$LINKED_REPORT_RUN_ID/report.md" \
  --artifact-root "$ARTIFACT_ROOT" \
  --input "$REPORT_IO_INPUT"
[[ ! -e "$TEST_DIR/external-report-dir/report.md" ]]

PUBLISH_META="$TEST_DIR/publish-metadata.tsv"
PUBLISH_PATCH="$TEST_DIR/publish.patch"
cat > "$PUBLISH_META" <<EOF
repo_root	$TEST_DIR/repo
branch	dex/maintain/$PUBLISH_RUN_ID
mode	propose
run_id	$PUBLISH_RUN_ID
base_sha	aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
printf 'diff --git a/docs/a.md b/docs/a.md\n' > "$PUBLISH_PATCH"

PUBLISH_STATE="$ARTIFACT_ROOT/publish-state.tsv"
python3 "$TOOL" seal \
  --kind publish \
  --state "$PUBLISH_STATE" \
  --metadata "$PUBLISH_META" \
  --patch "$PUBLISH_PATCH" \
  --report "$PUBLISH_REPORT" \
  --artifact-root "$ARTIFACT_ROOT"

python3 "$TOOL" verify --kind publish --state "$PUBLISH_STATE" > "$TEST_DIR/publish-verified.tsv"
PUBLISH_REPORT_REAL=$(python3 -c 'import pathlib, sys; print(pathlib.Path(sys.argv[1]).resolve())' "$PUBLISH_REPORT")
PUBLISH_PATCH_REAL=$(python3 -c 'import pathlib, sys; print(pathlib.Path(sys.argv[1]).resolve())' "$PUBLISH_STATE.patch")
assert_contains $'format_version\t1' "$TEST_DIR/publish-verified.tsv"
assert_contains $'report_file_rel\t'"$PUBLISH_RUN_ID/report.md" "$TEST_DIR/publish-verified.tsv"
assert_contains $'patch_file\tpublish-state.tsv.patch' "$TEST_DIR/publish-verified.tsv"
assert_contains $'report_file\t'"$PUBLISH_REPORT_REAL" "$TEST_DIR/publish-verified.tsv"
assert_contains $'patch_file_resolved\t'"$PUBLISH_PATCH_REAL" "$TEST_DIR/publish-verified.tsv"

state_before=$(hash_file "$PUBLISH_STATE")
patch_before=$(hash_file "$PUBLISH_STATE.patch")
expect_failure "existing bundle overwrite" python3 "$TOOL" seal \
  --kind publish \
  --state "$PUBLISH_STATE" \
  --metadata "$PUBLISH_META" \
  --patch "$PUBLISH_PATCH" \
  --report "$PUBLISH_REPORT" \
  --artifact-root "$ARTIFACT_ROOT"
[[ "$(hash_file "$PUBLISH_STATE")" == "$state_before" ]]
[[ "$(hash_file "$PUBLISH_STATE.patch")" == "$patch_before" ]]

printf 'victim bytes\n' > "$TEST_DIR/victim"
ln -s "$TEST_DIR/victim" "$ARTIFACT_ROOT/linked-patch-state.tsv.patch"
expect_failure "linked patch target" python3 "$TOOL" seal \
  --kind publish \
  --state "$ARTIFACT_ROOT/linked-patch-state.tsv" \
  --metadata "$PUBLISH_META" \
  --patch "$PUBLISH_PATCH" \
  --report "$PUBLISH_REPORT" \
  --artifact-root "$ARTIFACT_ROOT"
[[ "$(cat "$TEST_DIR/victim")" == "victim bytes" ]]
[[ ! -e "$ARTIFACT_ROOT/linked-patch-state.tsv" ]]

ln -s "$TEST_DIR/victim" "$ARTIFACT_ROOT/linked-state.tsv"
expect_failure "linked state target" python3 "$TOOL" seal \
  --kind publish \
  --state "$ARTIFACT_ROOT/linked-state.tsv" \
  --metadata "$PUBLISH_META" \
  --patch "$PUBLISH_PATCH" \
  --report "$PUBLISH_REPORT" \
  --artifact-root "$ARTIFACT_ROOT"
[[ "$(cat "$TEST_DIR/victim")" == "victim bytes" ]]
[[ ! -e "$ARTIFACT_ROOT/linked-state.tsv.patch" ]]

printf 'tampered\n' >> "$PUBLISH_STATE.patch"
expect_failure "tampered patch receipt" python3 "$TOOL" verify --kind publish --state "$PUBLISH_STATE"

cp "$PUBLISH_STATE" "$ARTIFACT_ROOT/traversal-state.tsv"
cp "$PUBLISH_PATCH" "$ARTIFACT_ROOT/traversal-state.tsv.patch"
python3 - "$ARTIFACT_ROOT/traversal-state.tsv" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
text = text.replace("report_file_rel\t", "report_file_rel\t../", 1)
text = text.replace("patch_file\tpublish-state.tsv.patch", "patch_file\ttraversal-state.tsv.patch", 1)
path.write_text(text, encoding="utf-8")
PY
expect_failure "traversing report member" python3 "$TOOL" verify --kind publish --state "$ARTIFACT_ROOT/traversal-state.tsv"

SYMLINK_RUN_ID="maintain-20260807T120002Z-cccccccc-u-11111111"
SYMLINK_META="$TEST_DIR/symlink-metadata.tsv"
cat > "$SYMLINK_META" <<EOF
repo_root	$TEST_DIR/repo
branch	dex/maintain/$SYMLINK_RUN_ID
mode	propose
run_id	$SYMLINK_RUN_ID
base_sha	cccccccccccccccccccccccccccccccccccccccc
EOF
mkdir -p "$ARTIFACT_ROOT/$SYMLINK_RUN_ID"
ln -s "$TEST_DIR/victim" "$ARTIFACT_ROOT/$SYMLINK_RUN_ID/report.md"
expect_failure "linked report" python3 "$TOOL" seal \
  --kind publish \
  --state "$ARTIFACT_ROOT/symlink-report-state.tsv" \
  --metadata "$SYMLINK_META" \
  --patch "$PUBLISH_PATCH" \
  --report "$ARTIFACT_ROOT/$SYMLINK_RUN_ID/report.md" \
  --artifact-root "$ARTIFACT_ROOT"

expect_failure "state outside artifact root" python3 "$TOOL" seal \
  --kind publish \
  --state "$TEST_DIR/outside-state.tsv" \
  --metadata "$PUBLISH_META" \
  --patch "$PUBLISH_PATCH" \
  --report "$PUBLISH_REPORT" \
  --artifact-root "$ARTIFACT_ROOT"

OVERSIZED_PATCH="$TEST_DIR/oversized.patch"
python3 - "$OVERSIZED_PATCH" <<'PY'
import sys

with open(sys.argv[1], "wb") as handle:
    handle.truncate(67_108_865)
PY
expect_failure "oversized patch" python3 "$TOOL" seal \
  --kind publish \
  --state "$ARTIFACT_ROOT/oversized-state.tsv" \
  --metadata "$PUBLISH_META" \
  --patch "$OVERSIZED_PATCH" \
  --report "$PUBLISH_REPORT" \
  --artifact-root "$ARTIFACT_ROOT"

RESPONSE_META="$TEST_DIR/response-metadata.tsv"
RESPONSE_PATCH="$TEST_DIR/response.patch"
cat > "$RESPONSE_META" <<EOF
repo_root	$TEST_DIR/repo
pr_num	42
run_id	$RESPONSE_RUN_ID
base_sha	bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
expected_branch	dex/maintain/$PUBLISH_RUN_ID
expected_sha	cccccccccccccccccccccccccccccccccccccccc
allowed_categories	docs, tests
trusted_ref	dddddddddddddddddddddddddddddddddddddddd
EOF
printf 'diff --git a/tests/a.sh b/tests/a.sh\n' > "$RESPONSE_PATCH"
RESPONSE_STATE="$ARTIFACT_ROOT/response-state.tsv"
python3 "$TOOL" seal \
  --kind response \
  --state "$RESPONSE_STATE" \
  --metadata "$RESPONSE_META" \
  --patch "$RESPONSE_PATCH" \
  --report "$RESPONSE_REPORT" \
  --artifact-root "$ARTIFACT_ROOT"
python3 "$TOOL" verify --kind response --state "$RESPONSE_STATE" > "$TEST_DIR/response-verified.tsv"
assert_contains $'pr_num\t42' "$TEST_DIR/response-verified.tsv"
assert_contains $'run_id\t'"$RESPONSE_RUN_ID" "$TEST_DIR/response-verified.tsv"
assert_contains $'patch_file\tresponse-state.tsv.patch' "$TEST_DIR/response-verified.tsv"

SHELL_REPO="$TEST_DIR/shell-repo"
git init -q -b main "$SHELL_REPO"
git -C "$SHELL_REPO" config user.name "Dex Test"
git -C "$SHELL_REPO" config user.email "dex-test@example.com"
mkdir -p "$SHELL_REPO/.dex" "$SHELL_REPO/docs"
printf 'base\n' > "$SHELL_REPO/docs/guide.md"
git -C "$SHELL_REPO" add .
git -C "$SHELL_REPO" commit -qm "test: initial state"
SHELL_BASE=$(git -C "$SHELL_REPO" rev-parse HEAD)
printf 'changed\n' > "$SHELL_REPO/docs/guide.md"

(
  export HOME="$TEST_DIR/home"
  export DEX_DIR="$ROOT"
  export DX_ARTIFACT_DIR="$TEST_DIR/artifacts"
  export DX_STATE_DIR="$TEST_DIR/state"
  export DX_LOOP_DIR="$TEST_DIR/loops"
  export DX_TOOL_DIR="$TEST_DIR/tools"
  export DX_RUN_ROOT="$TEST_DIR/runs"
  # shellcheck disable=SC1091
  source "$ROOT/bin/maintain.sh"
  __dx_maintain_write_publish_state \
    "$ARTIFACT_ROOT/shell-publish-state.tsv" \
    "$SHELL_REPO" \
    "$SHELL_REPO" \
    "dex/maintain/$PUBLISH_RUN_ID" \
    "propose" \
    "$PUBLISH_RUN_ID" \
    "$PUBLISH_REPORT" \
    "$SHELL_BASE" \
    "docs"

  shell_report_run_id="maintain-20260807T120003Z-shell-u-22222222"
  shell_report="$ARTIFACT_ROOT/$shell_report_run_id/report.md"
  mkdir -p "$(dirname "$shell_report")"
  __dx_maintain_write_report_header \
    "$shell_report" "run" "$SHELL_REPO" "$shell_report_run_id" "started" "test invocation"
  __dx_maintain_append_report_status "$shell_report" "complete" "shell report append"
  assert_contains "Detail: shell report append" "$shell_report"
  rm -f "$shell_report"
  ln -s "$TEST_DIR/report-victim" "$shell_report"
  if __dx_maintain_append_report_status "$shell_report" "failed" "must not follow" > "$TEST_DIR/shell-linked-report.out" 2>&1; then
    printf 'shell report append followed a linked report\n' >&2
    exit 1
  fi
  assert_contains "Could not update the maintenance report safely" "$TEST_DIR/shell-linked-report.out"
)
python3 "$TOOL" verify --kind publish --state "$ARTIFACT_ROOT/shell-publish-state.tsv" > "$TEST_DIR/shell-verified.tsv"
assert_contains $'base_sha\t'"$SHELL_BASE" "$TEST_DIR/shell-verified.tsv"
[[ "$(cat "$TEST_DIR/report-victim")" == "report victim" ]]

printf 'maintenance state tests passed\n'
