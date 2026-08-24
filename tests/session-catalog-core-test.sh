#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-session-catalog-core.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR"

# shellcheck source=lib/session.sh
source "$ROOT/lib/session.sh"
# shellcheck source=lib/session-runtime.sh
source "$ROOT/lib/session-runtime.sh"
# shellcheck source=lib/session-catalog.sh
source "$ROOT/lib/session-catalog.sh"
# shellcheck source=lib/review-loop.sh
source "$ROOT/lib/review-loop.sh"

new_repo() {
  local repo_dir="$1"
  mkdir -p "$repo_dir"
  git -C "$repo_dir" init -q
  git -C "$repo_dir" config user.email dex@example.test
  git -C "$repo_dir" config user.name "Dex Test"
  printf 'base\n' > "$repo_dir/file.txt"
  git -C "$repo_dir" add file.txt
  git -C "$repo_dir" commit -q -m "test: initialize repo"
  git -C "$repo_dir" branch -m main
}

json_field() {
  local json_input="$1" field_name="$2"
  python3 - "$field_name" "$json_input" <<'PY'
import json
import sys
value = json.loads(sys.argv[2]).get(sys.argv[1])
if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("")
elif isinstance(value, (dict, list)):
    print(json.dumps(value, sort_keys=True, separators=(",", ":")))
else:
    print(value)
PY
}

REPO_A="$TMP_DIR/owner-a/project"
REPO_B="$TMP_DIR/owner-b/project"
new_repo "$REPO_A"
new_repo "$REPO_B"
mkdir -p "$REPO_A/.dex/worktrees"
git -C "$REPO_A" worktree add -q "$REPO_A/.dex/worktrees/ticket-101" -b worktree-ticket-101 main
git -C "$REPO_A" worktree add -q "$REPO_A/.dex/worktrees/task-same-ticket" -b worktree-task-same-ticket main

SID_A="$(cd "$REPO_A" && dx_session_id ticket-101)"
SID_A2="$(cd "$REPO_A" && dx_session_id task-same-ticket)"
SID_B="$(cd "$REPO_B" && dx_session_id ticket-202)"
SID_RUNTIME_ONLY="$(cd "$REPO_A" && dx_scoped_session_id worktree-runtime-only)"
SID_EXTERNAL="$(cd "$REPO_A" && dx_scoped_session_id worktree-external)"
SID_ALIAS="$(cd "$REPO_A" && dx_scoped_session_id branch-provider-alias)"
SID_LEGIT_PASS="$(cd "$REPO_A" && dx_scoped_session_id worktree-legit-pass-1-2-3)"
CHILD_A="${SID_A}-pass-20260824T101112Z_123_deadbeef"

dx_meta_write "$SID_A" \
  "ticket_number=101" \
  "wt_name=ticket-101" \
  "wt_dir=$REPO_A/.dex/worktrees/ticket-101" \
  "workspace_mode=worktree"
printf '3\n' > "$(dx_state_file "$SID_A")"
printf 'run_test_a\n' > "$DX_STATE_DIR/${SID_A}.run-id"
printf 'paused\n' > "$(dx_paused_file "$SID_A")"
printf 'engine=codex\nsession=%s\n' "$SID_A" > "$(dx_provider_state_file "$SID_A")"

dx_meta_write "$SID_A2" \
  "ticket_number=101" \
  "wt_name=task-same-ticket" \
  "wt_dir=$REPO_A/.dex/worktrees/task-same-ticket" \
  "workspace_mode=worktree"
printf '2\n' > "$(dx_state_file "$SID_A2")"
touch -t 200001010000 "$(dx_state_file "$SID_A2")"

dx_meta_write "$SID_LEGIT_PASS" \
  "ticket_number=legit-pass" \
  "wt_name=legit-pass-1-2-3" \
  "wt_dir=$REPO_A" \
  "workspace_mode=in-place"
printf '2\n' > "$(dx_state_file "$SID_LEGIT_PASS")"

printf 'engine=codex\nsession=%s\n' "$SID_A" > "$(dx_provider_state_file "$SID_ALIAS")"

dx_meta_write "$SID_B" \
  "ticket_number=202" \
  "wt_name=ticket-202" \
  "wt_dir=$REPO_B/.dex/worktrees/ticket-202" \
  "workspace_mode=worktree"
printf '4\n' > "$(dx_state_file "$SID_B")"

printf '{}\n' > "$(dx_review_state_file "$CHILD_A")"
printf '3\n' > "$(dx_state_file "$CHILD_A")"
__dx_review_write_child_provenance "$SID_A" "$CHILD_A" pass

TOKEN="$(dx_session_runtime_start "$SID_A" codex "$REPO_A/.dex/worktrees/ticket-101" "$$")"
[[ -n "$TOKEN" ]] || assert_at $LINENO
RUNTIME_ONLY_TOKEN="$(dx_session_runtime_start "$SID_RUNTIME_ONLY" claude "$REPO_A" "$$")"
EXTERNAL_TOKEN="$(dx_session_runtime_start "$SID_EXTERNAL" claude "$REPO_B" "$$")"
[[ -n "$RUNTIME_ONLY_TOKEN" && -n "$EXTERNAL_TOKEN" ]] || assert_at $LINENO

RECORDS_FILE="$TMP_DIR/records.jsonl"
dx_session_catalog_records --repo "$REPO_A" > "$RECORDS_FILE"
assert_eq "4" "$(wc -l < "$RECORDS_FILE" | tr -d '[:space:]')" "top-level record count"
assert_not_contains "$SID_B" "$RECORDS_FILE"
assert_not_contains "$SID_EXTERNAL" "$RECORDS_FILE"
assert_not_contains "$SID_ALIAS" "$RECORDS_FILE"
assert_not_contains "$CHILD_A" "$RECORDS_FILE"
assert_contains "$SID_LEGIT_PASS" "$RECORDS_FILE"
assert_not_contains "$TOKEN" "$RECORDS_FILE"
assert_not_contains "$RUNTIME_ONLY_TOKEN" "$RECORDS_FILE"

RECORD_A="$(dx_session_catalog_record "$SID_A" --repo "$REPO_A")"
assert_eq "$SID_A" "$(json_field "$RECORD_A" session_id)" "record session id"
assert_eq "101" "$(json_field "$RECORD_A" ticket)" "record ticket"
assert_eq "ticket-101" "$(json_field "$RECORD_A" workspace_name)" "record workspace name"
assert_eq "3" "$(json_field "$RECORD_A" phase)" "record phase"
assert_eq "live" "$(json_field "$RECORD_A" runtime_health)" "record runtime health"
assert_eq "running" "$(json_field "$RECORD_A" runtime_status)" "record runtime status"
assert_eq "codex" "$(json_field "$RECORD_A" provider)" "record provider"
assert_eq "false" "$(json_field "$RECORD_A" is_child)" "parent classification"
assert_contains '"meta"' <(printf '%s\n' "$RECORD_A")
assert_contains '"phase"' <(printf '%s\n' "$RECORD_A")
assert_contains '"run-id"' <(printf '%s\n' "$RECORD_A")
assert_contains '"runtime"' <(printf '%s\n' "$RECORD_A")

RECORD_A2="$(dx_session_catalog_record "$SID_A2" --repo "$REPO_A")"
assert_eq "legacy-unverifiable" "$(json_field "$RECORD_A2" runtime_health)" "legacy health"
assert_eq "unknown" "$(json_field "$RECORD_A2" lifecycle_state)" \
  "old timestamps do not imply staleness"
RUNTIME_ONLY_RECORD="$(dx_session_catalog_record "$SID_RUNTIME_ONLY" --repo "$REPO_A")"
assert_eq "$REPO_A" "$(json_field "$RUNTIME_ONLY_RECORD" workspace)" "runtime-only workspace"
assert_eq "live" "$(json_field "$RUNTIME_ONLY_RECORD" runtime_health)" "runtime-only health"
LEGIT_PASS_RECORD="$(dx_session_catalog_record "$SID_LEGIT_PASS" --repo "$REPO_A")"
assert_eq "false" "$(json_field "$LEGIT_PASS_RECORD" is_child)" \
  "valid lifecycle with a child-shaped name"

SELECTED="$(dx_session_catalog_select "session:$SID_A" --repo "$REPO_A")"
assert_eq "$SID_A" "$(json_field "$SELECTED" session_id)" "session selector"
SELECTED="$(dx_session_catalog_select "$SID_A" --repo "$REPO_A")"
assert_eq "$SID_A" "$(json_field "$SELECTED" session_id)" "unqualified session selector"
SELECTED="$(dx_session_catalog_select 'workspace:ticket-101' --repo "$REPO_A")"
assert_eq "$SID_A" "$(json_field "$SELECTED" session_id)" "workspace-name selector"
SELECTED="$(dx_session_catalog_select "workspace:$REPO_A/.dex/worktrees/ticket-101" --repo "$REPO_A")"
assert_eq "$SID_A" "$(json_field "$SELECTED" session_id)" "workspace-path selector"

if dx_session_catalog_select ticket:101 --repo "$REPO_A" >/dev/null 2>&1; then
  fail "ticket selector accepted an ambiguous match"
else
  assert_eq "2" "$?" "ambiguous selector result"
fi
if dx_session_catalog_select ticket:202 --repo "$REPO_A" >/dev/null 2>&1; then
  fail "catalog matched another repository"
else
  assert_eq "1" "$?" "cross-repo selector result"
fi
if dx_session_catalog_select 'session:../bad' --repo "$REPO_A" >/dev/null 2>&1; then
  fail "catalog accepted an invalid session selector"
else
  assert_eq "3" "$?" "invalid selector result"
fi

dx_session_catalog_records --repo "$REPO_A/.dex/worktrees/ticket-101" > "$TMP_DIR/worktree-records.jsonl"
assert_eq "4" "$(wc -l < "$TMP_DIR/worktree-records.jsonl" | tr -d '[:space:]')" "worktree-scoped count"
assert_contains "$SID_A" "$TMP_DIR/worktree-records.jsonl"

dx_session_catalog_records --repo "$REPO_A" --include-children > "$TMP_DIR/with-children.jsonl"
assert_eq "5" "$(wc -l < "$TMP_DIR/with-children.jsonl" | tr -d '[:space:]')" "child-inclusive count"
assert_contains "$CHILD_A" "$TMP_DIR/with-children.jsonl"
CHILD_RECORD="$(dx_session_catalog_record "$CHILD_A" --repo "$REPO_A")"
assert_eq "true" "$(json_field "$CHILD_RECORD" is_child)" "child classification"
assert_eq "pass" "$(json_field "$CHILD_RECORD" child_kind)" "child kind"
assert_eq "$SID_A" "$(json_field "$CHILD_RECORD" parent_session_id)" "child parent"
if dx_session_catalog_record "$(cd "$REPO_A" && dx_scoped_session_id worktree-missing)" \
  --repo "$REPO_A" >/dev/null 2>&1; then
  fail "catalog record lookup accepted a missing session"
else
  assert_eq "1" "$?" "missing record result"
fi

if dx_session_catalog_select "session:$CHILD_A" --repo "$REPO_A" >/dev/null 2>&1; then
  fail "default selector exposed a review child"
else
  assert_eq "1" "$?" "hidden-child selector result"
fi
SELECTED="$(dx_session_catalog_select "session:$CHILD_A" --repo "$REPO_A" --include-children)"
assert_eq "$CHILD_A" "$(json_field "$SELECTED" session_id)" "explicit child selector"

# A child-shaped name and shared review artifacts are not provenance by themselves.
MISSING_META_CHILD="${SID_A}-pass-1-2-3"
CORRUPT_META_CHILD="${SID_A}-assessment-4-5-6"
printf '{}\n' > "$(dx_review_state_file "$MISSING_META_CHILD")"
printf '3\n' > "$(dx_state_file "$MISSING_META_CHILD")"
printf '{}\n' > "$(dx_review_state_file "$CORRUPT_META_CHILD")"
printf '3\n' > "$(dx_state_file "$CORRUPT_META_CHILD")"
printf 'session_role=review-child\nparent_session_id=%s\n' "$SID_A" \
  > "$DX_STATE_DIR/${CORRUPT_META_CHILD}.meta"
dx_session_catalog_records --repo "$REPO_A" > "$TMP_DIR/conservative-children.jsonl"
assert_contains "$MISSING_META_CHILD" "$TMP_DIR/conservative-children.jsonl"
assert_contains "$CORRUPT_META_CHILD" "$TMP_DIR/conservative-children.jsonl"
MISSING_META_RECORD="$(dx_session_catalog_record "$MISSING_META_CHILD" --repo "$REPO_A")"
CORRUPT_META_RECORD="$(dx_session_catalog_record "$CORRUPT_META_CHILD" --repo "$REPO_A")"
assert_eq "false" "$(json_field "$MISSING_META_RECORD" is_child)" \
  "missing child provenance stays top-level"
assert_eq "missing" "$(json_field "$MISSING_META_RECORD" metadata_health)" \
  "missing child metadata health"
assert_eq "false" "$(json_field "$CORRUPT_META_RECORD" is_child)" \
  "corrupt child provenance stays top-level"
assert_eq "corrupt" "$(json_field "$CORRUPT_META_RECORD" metadata_health)" \
  "corrupt child metadata health"

# Missing stable process evidence is uncertainty, not proof that a runner died.
export DX_SESSION_RUNTIME_PROC_ROOT="$TMP_DIR/no-proc"
export DX_SESSION_RUNTIME_PS_BIN="$TMP_DIR/no-ps"
UNVERIFIABLE_RECORD="$(dx_session_catalog_record "$SID_A" --repo "$REPO_A")"
assert_eq "unverifiable" "$(json_field "$UNVERIFIABLE_RECORD" runtime_health)" \
  "catalog process evidence health"
assert_eq "active-unverifiable" "$(json_field "$UNVERIFIABLE_RECORD" lifecycle_state)" \
  "catalog unverifiable lifecycle"
unset DX_SESSION_RUNTIME_PROC_ROOT DX_SESSION_RUNTIME_PS_BIN

# Catalog reads remain valid while heartbeat atomically publishes new snapshots.
(
  catalog_churn_iteration=0
  while [[ "$catalog_churn_iteration" -lt 12 ]]; do
    dx_session_runtime_heartbeat "$SID_A" "$TOKEN" "$$"
    catalog_churn_iteration=$((catalog_churn_iteration + 1))
  done
) &
CATALOG_CHURN_PID=$!
catalog_read_iteration=0
while [[ "$catalog_read_iteration" -lt 18 ]]; do
  CHURN_RECORD="$(dx_session_catalog_record "$SID_A" --repo "$REPO_A")"
  assert_eq "live" "$(json_field "$CHURN_RECORD" runtime_health)" "catalog churn health"
  catalog_read_iteration=$((catalog_read_iteration + 1))
done
wait "$CATALOG_CHURN_PID"

# Large metadata integers are rejected without handing Python an unbounded conversion.
HUGE_SID="$(cd "$REPO_A" && dx_scoped_session_id worktree-huge-metadata)"
HUGE_TIMESTAMP=""
huge_digit=0
while [[ "$huge_digit" -lt 5000 ]]; do
  HUGE_TIMESTAMP="${HUGE_TIMESTAMP}9"
  huge_digit=$((huge_digit + 1))
done
printf 'ticket_number=huge\nwt_name=huge-metadata\nwt_dir=%s\nworkspace_mode=in-place\ncreated_at=%s\n' \
  "$REPO_A" "$HUGE_TIMESTAMP" > "$DX_STATE_DIR/${HUGE_SID}.meta"
HUGE_ERRORS="$TMP_DIR/huge-errors"
HUGE_RECORD="$(dx_session_catalog_record "$HUGE_SID" --repo "$REPO_A" 2> "$HUGE_ERRORS")"
assert_eq "corrupt" "$(json_field "$HUGE_RECORD" metadata_health)" "huge metadata health"
assert_not_contains "Traceback" "$HUGE_ERRORS"

CATALOG_SCHEMA_SID="$(cd "$REPO_A" && dx_scoped_session_id worktree-catalog-schema)"
CATALOG_SCHEMA_FILE="$(dx_session_runtime_file "$CATALOG_SCHEMA_SID")"
CATALOG_SCHEMA_TOKEN="$(dx_session_runtime_start "$CATALOG_SCHEMA_SID" codex "$REPO_A" "$$")"
[[ -n "$CATALOG_SCHEMA_TOKEN" ]] || assert_at $LINENO
python3 - "$CATALOG_SCHEMA_FILE" <<'PY'
import json
import os
import sys
import tempfile

target = sys.argv[1]
with open(target, encoding="utf-8") as source:
    record = json.load(source)
record["schema_version"] = True
descriptor, temporary = tempfile.mkstemp(dir=os.path.dirname(target))
os.fchmod(descriptor, 0o600)
with os.fdopen(descriptor, "w", encoding="utf-8") as output:
    json.dump(record, output, separators=(",", ":"))
    output.write("\n")
os.replace(temporary, target)
PY
CATALOG_SCHEMA_RECORD="$(dx_session_catalog_record "$CATALOG_SCHEMA_SID" --repo "$REPO_A")"
assert_eq "corrupt" "$(json_field "$CATALOG_SCHEMA_RECORD" runtime_health)" \
  "catalog rejects boolean runtime schema"

# Registered external worktrees retain visibility for both new and legacy repo keys.
EXTERNAL_WORKTREE="$TMP_DIR/external/catalog-workspace"
mkdir -p "$(dirname "$EXTERNAL_WORKTREE")"
git -C "$REPO_A" worktree add -q "$EXTERNAL_WORKTREE" -b external-catalog main
EXTERNAL_CURRENT_SID="$(cd "$EXTERNAL_WORKTREE" && dx_session_id)"
dx_meta_write "$EXTERNAL_CURRENT_SID" \
  "ticket_number=external-current" \
  "wt_name=catalog-workspace" \
  "wt_dir=$EXTERNAL_WORKTREE" \
  "workspace_mode=worktree"
EXTERNAL_ROOT="$(cd "$EXTERNAL_WORKTREE" && pwd -P)"
EXTERNAL_LEGACY_HASH="$(printf '%s' "$EXTERNAL_ROOT" | cksum | awk '{print $1}')"
EXTERNAL_LEGACY_SID="repo-catalog-workspace-${EXTERNAL_LEGACY_HASH}-worktree-legacy"
EXTERNAL_LEGACY_PHASE_ONLY="repo-catalog-workspace-${EXTERNAL_LEGACY_HASH}-worktree-phase-only"
dx_meta_write "$EXTERNAL_LEGACY_SID" \
  "ticket_number=external-legacy" \
  "wt_name=legacy" \
  "wt_dir=$EXTERNAL_WORKTREE" \
  "workspace_mode=worktree"
printf '2\n' > "$(dx_state_file "$EXTERNAL_LEGACY_PHASE_ONLY")"
EXTERNAL_CURRENT_RECORD="$(dx_session_catalog_record "$EXTERNAL_CURRENT_SID" --repo "$REPO_A")"
assert_eq "$EXTERNAL_WORKTREE" "$(json_field "$EXTERNAL_CURRENT_RECORD" workspace)" \
  "current external worktree"
EXTERNAL_LEGACY_RECORD="$(dx_session_catalog_record "$EXTERNAL_LEGACY_SID" --repo "$REPO_A")"
assert_eq "external-legacy" "$(json_field "$EXTERNAL_LEGACY_RECORD" ticket)" \
  "legacy external worktree key"
EXTERNAL_FROM_WORKTREE="$(dx_session_catalog_record "$EXTERNAL_LEGACY_SID" --repo "$EXTERNAL_WORKTREE")"
assert_eq "$EXTERNAL_LEGACY_SID" "$(json_field "$EXTERNAL_FROM_WORKTREE" session_id)" \
  "external worktree catalog context"
if dx_session_catalog_record "$EXTERNAL_LEGACY_PHASE_ONLY" --repo "$REPO_A" >/dev/null 2>&1; then
  fail "catalog accepted an unattributed legacy worktree key"
else
  assert_eq "1" "$?" "unattributed legacy key result"
fi

# A standalone repository under a similarly named directory is not a linked worktree.
PARENT_PHASE_ONLY="$(cd "$REPO_A" && dx_scoped_session_id worktree-parent-phase-only)"
printf '2\n' > "$(dx_state_file "$PARENT_PHASE_ONLY")"
NESTED_REPO="$REPO_A/.dex/worktrees/unrelated-repository"
new_repo "$NESTED_REPO"
NESTED_SID="$(cd "$NESTED_REPO" && dx_session_id nested-ticket)"
dx_meta_write "$NESTED_SID" \
  "ticket_number=nested" \
  "wt_name=unrelated-repository" \
  "wt_dir=$NESTED_REPO" \
  "workspace_mode=in-place"
if dx_session_catalog_record "$NESTED_SID" --repo "$REPO_A" >/dev/null 2>&1; then
  fail "parent catalog included a standalone nested repository"
else
  assert_eq "1" "$?" "nested repository isolation result"
fi
NESTED_RECORD="$(dx_session_catalog_record "$NESTED_SID" --repo "$NESTED_REPO")"
assert_eq "nested" "$(json_field "$NESTED_RECORD" ticket)" "nested repository catalog"
dx_session_catalog_records --repo "$NESTED_REPO" > "$TMP_DIR/nested-records.jsonl"
assert_not_contains "$PARENT_PHASE_ONLY" "$TMP_DIR/nested-records.jsonl"

if dx_session_catalog_records --repo "$TMP_DIR/not-a-repo" >/dev/null 2>&1; then
  fail "catalog accepted a non-repository"
else
  assert_eq "3" "$?" "invalid repository result"
fi

printf 'session catalog core tests passed\n'
