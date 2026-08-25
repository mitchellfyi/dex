#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-session-catalog-core.XXXXXX")"

cleanup() {
  chmod -R u+w "$TMP_DIR" 2>/dev/null || true
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
CHILD_A="$(__dx_review_child_session_id \
  "$SID_A" pass 20260824T101112Z_123_deadbeef)"
LONG_PARENT="$(cd "$REPO_A" && dx_session_repo_key)-$(printf 'p%.0s' {1..140})"
LONG_CHILD="$(__dx_review_child_session_id \
  "$LONG_PARENT" assessment 20260824T121314Z_456_feedface)"

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

dx_meta_write "$LONG_PARENT" \
  "ticket_number=long-parent" \
  "wt_name=long-parent" \
  "wt_dir=$REPO_A" \
  "workspace_mode=in-place"
printf '3\n' > "$(dx_state_file "$LONG_PARENT")"
printf '{}\n' > "$(dx_review_state_file "$LONG_CHILD")"
printf '3\n' > "$(dx_state_file "$LONG_CHILD")"
touch "$DX_LOOP_DIR/${LONG_CHILD}.active"
printf 'version=1\nsession_id=%s\nmode=child\npurpose=review-assessment\nphase=assessment\ngeneration=%s\nissued_at=1787598000\n' \
  "$LONG_CHILD" 0123456789abcdef0123456789abcdef \
  > "$DX_LOOP_DIR/${LONG_CHILD}.completion-expectation"
chmod 600 "$DX_LOOP_DIR/${LONG_CHILD}.completion-expectation"
__dx_review_write_child_provenance "$LONG_PARENT" "$LONG_CHILD" assessment

TOKEN="$(dx_session_runtime_start "$SID_A" codex "$REPO_A/.dex/worktrees/ticket-101" "$$")"
[[ -n "$TOKEN" ]] || assert_at $LINENO
RUNTIME_ONLY_TOKEN="$(dx_session_runtime_start "$SID_RUNTIME_ONLY" claude "$REPO_A" "$$")"
EXTERNAL_TOKEN="$(dx_session_runtime_start "$SID_EXTERNAL" claude "$REPO_B" "$$")"
[[ -n "$RUNTIME_ONLY_TOKEN" && -n "$EXTERNAL_TOKEN" ]] || assert_at $LINENO

RECORDS_FILE="$TMP_DIR/records.jsonl"
dx_session_catalog_records --repo "$REPO_A" > "$RECORDS_FILE"
assert_eq "6" "$(wc -l < "$RECORDS_FILE" | tr -d '[:space:]')" "top-level record count"
assert_not_contains "$SID_B" "$RECORDS_FILE"
assert_not_contains "$SID_EXTERNAL" "$RECORDS_FILE"
assert_contains "$SID_ALIAS" "$RECORDS_FILE"
assert_not_contains "$CHILD_A" "$RECORDS_FILE"
assert_not_contains "$LONG_CHILD" "$RECORDS_FILE"
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
PROVIDER_ONLY_RECORD="$(dx_session_catalog_record "$SID_ALIAS" --repo "$REPO_A")"
assert_eq "" "$(json_field "$PROVIDER_ONLY_RECORD" provider)" \
  "mismatched provider residue stays untrusted"
assert_eq '["provider"]' "$(json_field "$PROVIDER_ONLY_RECORD" artifacts)" \
  "provider-only residue remains visible"
LEGIT_PASS_RECORD="$(dx_session_catalog_record "$SID_LEGIT_PASS" --repo "$REPO_A")"
assert_eq "false" "$(json_field "$LEGIT_PASS_RECORD" is_child)" \
  "valid lifecycle with a child-shaped name"

assert_catalog_record_missing() {
  local session_id="$1" assertion_name="$2"
  if dx_session_catalog_record "$session_id" --repo "$REPO_A" >/dev/null 2>&1; then
    fail "$assertion_name"
  else
    assert_eq "1" "$?" "$assertion_name"
  fi
}

assert_unsafe_lock_visible() {
  local session_id="$1" family="$2" assertion_name="$3" record
  record="$(dx_session_catalog_record "$session_id" --repo "$REPO_A")"
  assert_eq "[\"${family}\"]" "$(json_field "$record" unsafe_artifacts)" \
    "$assertion_name"
}

SAFE_COMPLETION_SID="$(cd "$REPO_A" && dx_scoped_session_id completion-lock-tombstone)"
SAFE_COMPLETION_LOCK="$DX_LOOP_DIR/${SAFE_COMPLETION_SID}.completion-lock"
: > "$SAFE_COMPLETION_LOCK"
chmod 600 "$SAFE_COMPLETION_LOCK"
assert_catalog_record_missing "$SAFE_COMPLETION_SID" \
  "safe completion lock tombstone stays hidden"
rm -f "$SAFE_COMPLETION_LOCK"

SAFE_RUNTIME_SID="$(cd "$REPO_A" && dx_scoped_session_id runtime-lock-tombstone)"
SAFE_RUNTIME_TOKEN="$(dx_session_runtime_start "$SAFE_RUNTIME_SID" codex "$REPO_A" "$$")"
[[ -n "$SAFE_RUNTIME_TOKEN" ]] || assert_at $LINENO
SAFE_RUNTIME_FILE="$(dx_session_runtime_file "$SAFE_RUNTIME_SID")"
SAFE_RUNTIME_LOCK="${SAFE_RUNTIME_FILE}-lock"
rm -f "$SAFE_RUNTIME_FILE"
assert_catalog_record_missing "$SAFE_RUNTIME_SID" \
  "safe runtime lock tombstone stays hidden"
rm -f "$SAFE_RUNTIME_LOCK"

COMPLETION_SYMLINK_SID="$(cd "$REPO_A" && dx_scoped_session_id completion-lock-symlink)"
COMPLETION_SYMLINK_TARGET="$TMP_DIR/completion-lock-symlink-target"
: > "$COMPLETION_SYMLINK_TARGET"
chmod 600 "$COMPLETION_SYMLINK_TARGET"
ln -s "$COMPLETION_SYMLINK_TARGET" \
  "$DX_LOOP_DIR/${COMPLETION_SYMLINK_SID}.completion-lock"
assert_unsafe_lock_visible "$COMPLETION_SYMLINK_SID" completion-lock \
  "completion lock symlink remains visible"
rm -f "$DX_LOOP_DIR/${COMPLETION_SYMLINK_SID}.completion-lock" \
  "$COMPLETION_SYMLINK_TARGET"

COMPLETION_HARDLINK_SID="$(cd "$REPO_A" && dx_scoped_session_id completion-lock-hardlink)"
COMPLETION_HARDLINK_TARGET="$TMP_DIR/completion-lock-hardlink-target"
: > "$COMPLETION_HARDLINK_TARGET"
chmod 600 "$COMPLETION_HARDLINK_TARGET"
ln "$COMPLETION_HARDLINK_TARGET" \
  "$DX_LOOP_DIR/${COMPLETION_HARDLINK_SID}.completion-lock"
assert_unsafe_lock_visible "$COMPLETION_HARDLINK_SID" completion-lock \
  "completion lock hardlink remains visible"
rm -f "$DX_LOOP_DIR/${COMPLETION_HARDLINK_SID}.completion-lock" \
  "$COMPLETION_HARDLINK_TARGET"

COMPLETION_MODE_SID="$(cd "$REPO_A" && dx_scoped_session_id completion-lock-mode)"
COMPLETION_MODE_LOCK="$DX_LOOP_DIR/${COMPLETION_MODE_SID}.completion-lock"
: > "$COMPLETION_MODE_LOCK"
chmod 644 "$COMPLETION_MODE_LOCK"
assert_unsafe_lock_visible "$COMPLETION_MODE_SID" completion-lock \
  "completion lock with wrong mode remains visible"
rm -f "$COMPLETION_MODE_LOCK"

RUNTIME_LOCK_PAYLOAD='dex-runtime-lock-v1 0123456789abcdef0123456789abcdef'
RUNTIME_MALFORMED_SID="$(cd "$REPO_A" && dx_scoped_session_id runtime-lock-malformed)"
RUNTIME_MALFORMED_LOCK="$DX_STATE_DIR/${RUNTIME_MALFORMED_SID}.runtime-lock"
printf 'malformed\n' > "$RUNTIME_MALFORMED_LOCK"
chmod 600 "$RUNTIME_MALFORMED_LOCK"
assert_unsafe_lock_visible "$RUNTIME_MALFORMED_SID" runtime-lock \
  "malformed runtime lock remains visible"
rm -f "$RUNTIME_MALFORMED_LOCK"

RUNTIME_SYMLINK_SID="$(cd "$REPO_A" && dx_scoped_session_id runtime-lock-symlink)"
RUNTIME_SYMLINK_TARGET="$TMP_DIR/runtime-lock-symlink-target"
printf '%s\n' "$RUNTIME_LOCK_PAYLOAD" > "$RUNTIME_SYMLINK_TARGET"
chmod 600 "$RUNTIME_SYMLINK_TARGET"
ln -s "$RUNTIME_SYMLINK_TARGET" "$DX_STATE_DIR/${RUNTIME_SYMLINK_SID}.runtime-lock"
assert_unsafe_lock_visible "$RUNTIME_SYMLINK_SID" runtime-lock \
  "runtime lock symlink remains visible"
rm -f "$DX_STATE_DIR/${RUNTIME_SYMLINK_SID}.runtime-lock" "$RUNTIME_SYMLINK_TARGET"

RUNTIME_HARDLINK_SID="$(cd "$REPO_A" && dx_scoped_session_id runtime-lock-hardlink)"
RUNTIME_HARDLINK_TARGET="$TMP_DIR/runtime-lock-hardlink-target"
printf '%s\n' "$RUNTIME_LOCK_PAYLOAD" > "$RUNTIME_HARDLINK_TARGET"
chmod 600 "$RUNTIME_HARDLINK_TARGET"
ln "$RUNTIME_HARDLINK_TARGET" "$DX_STATE_DIR/${RUNTIME_HARDLINK_SID}.runtime-lock"
assert_unsafe_lock_visible "$RUNTIME_HARDLINK_SID" runtime-lock \
  "runtime lock hardlink remains visible"
rm -f "$DX_STATE_DIR/${RUNTIME_HARDLINK_SID}.runtime-lock" "$RUNTIME_HARDLINK_TARGET"

RUNTIME_MODE_SID="$(cd "$REPO_A" && dx_scoped_session_id runtime-lock-mode)"
RUNTIME_MODE_LOCK="$DX_STATE_DIR/${RUNTIME_MODE_SID}.runtime-lock"
printf '%s\n' "$RUNTIME_LOCK_PAYLOAD" > "$RUNTIME_MODE_LOCK"
chmod 644 "$RUNTIME_MODE_LOCK"
assert_unsafe_lock_visible "$RUNTIME_MODE_SID" runtime-lock \
  "runtime lock with wrong mode remains visible"
rm -f "$RUNTIME_MODE_LOCK"

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
assert_eq "6" "$(wc -l < "$TMP_DIR/worktree-records.jsonl" | tr -d '[:space:]')" "worktree-scoped count"
assert_contains "$SID_A" "$TMP_DIR/worktree-records.jsonl"

dx_session_catalog_records --repo "$REPO_A" --include-children > "$TMP_DIR/with-children.jsonl"
assert_eq "8" "$(wc -l < "$TMP_DIR/with-children.jsonl" | tr -d '[:space:]')" "child-inclusive count"
assert_contains "$CHILD_A" "$TMP_DIR/with-children.jsonl"
CHILD_RECORD="$(dx_session_catalog_record "$CHILD_A" --repo "$REPO_A")"
assert_eq "true" "$(json_field "$CHILD_RECORD" is_child)" "child classification"
assert_eq "pass" "$(json_field "$CHILD_RECORD" child_kind)" "child kind"
assert_eq "$SID_A" "$(json_field "$CHILD_RECORD" parent_session_id)" "child parent"
LONG_CHILD_RECORD="$(dx_session_catalog_record "$LONG_CHILD" --repo "$REPO_A")"
assert_eq "true" "$(json_field "$LONG_CHILD_RECORD" is_child)" \
  "bounded assessment child classification"
assert_eq "assessment" "$(json_field "$LONG_CHILD_RECORD" child_kind)" \
  "bounded assessment child kind"
assert_eq "$LONG_PARENT" "$(json_field "$LONG_CHILD_RECORD" parent_session_id)" \
  "bounded assessment child keeps full parent linkage"
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

# Phase 7 is only completed after its exact terminal transaction is present.
new_terminal_session() {
  local suffix="$1" terminal_session
  terminal_session="$(cd "$REPO_A" && dx_scoped_session_id "worktree-${suffix}")"
  dx_meta_write "$terminal_session" \
    "ticket_number=${suffix}" \
    "wt_name=${suffix}" \
    "wt_dir=$REPO_A" \
    "workspace_mode=in-place"
  printf '7\n' > "$(dx_state_file "$terminal_session")"
  printf '%s\n' "$terminal_session"
}

write_terminal_proof() {
  local terminal_session="$1" transition_token="${2:-100-200-300}"
  local authority="${3:-0123456789abcdef0123456789abcdef}"
  printf 'version=1\nphase=7\ntransition_token=%s\nauthority=%s\n' \
    "$transition_token" "$authority" \
    > "$DX_STATE_DIR/${terminal_session}.terminal-commit"
  chmod 600 "$DX_STATE_DIR/${terminal_session}.terminal-commit"
}

TERMINAL_VALID_SID="$(new_terminal_session terminal-valid)"
write_terminal_proof "$TERMINAL_VALID_SID"
TERMINAL_VALID_RECORD="$(dx_session_catalog_record "$TERMINAL_VALID_SID" --repo "$REPO_A")"
assert_eq "completed" "$(json_field "$TERMINAL_VALID_RECORD" lifecycle_state)" \
  "valid terminal proof classification"
assert_contains '"terminal-commit"' <(printf '%s\n' "$TERMINAL_VALID_RECORD")

for terminal_busy_suffix in busy busy-cancel busy-quiesced; do
  terminal_busy_path="$DX_LOOP_DIR/${TERMINAL_VALID_SID}.phase-3.${terminal_busy_suffix}"
  mkdir "$terminal_busy_path"
  TERMINAL_BUSY_RECORD="$(dx_session_catalog_record \
    "$TERMINAL_VALID_SID" --repo "$REPO_A")"
  assert_eq "unknown" \
    "$(json_field "$TERMINAL_BUSY_RECORD" lifecycle_state)" \
    "terminal proof rejects Phase 3 ${terminal_busy_suffix} residue"
  rmdir "$terminal_busy_path"
done

TERMINAL_MISSING_SID="$(new_terminal_session terminal-missing)"
TERMINAL_MISSING_RECORD="$(dx_session_catalog_record "$TERMINAL_MISSING_SID" --repo "$REPO_A")"
assert_eq "unknown" "$(json_field "$TERMINAL_MISSING_RECORD" lifecycle_state)" \
  "missing terminal proof classification"

TERMINAL_UNSAFE_SID="$(new_terminal_session terminal-unsafe)"
write_terminal_proof "$TERMINAL_UNSAFE_SID"
chmod 644 "$DX_STATE_DIR/${TERMINAL_UNSAFE_SID}.terminal-commit"
TERMINAL_UNSAFE_RECORD="$(dx_session_catalog_record "$TERMINAL_UNSAFE_SID" --repo "$REPO_A")"
assert_eq "unknown" "$(json_field "$TERMINAL_UNSAFE_RECORD" lifecycle_state)" \
  "unsafe terminal proof classification"

TERMINAL_WRONG_SID="$(new_terminal_session terminal-wrong-token)"
write_terminal_proof "$TERMINAL_WRONG_SID" wrong-token
TERMINAL_WRONG_RECORD="$(dx_session_catalog_record "$TERMINAL_WRONG_SID" --repo "$REPO_A")"
assert_eq "unknown" "$(json_field "$TERMINAL_WRONG_RECORD" lifecycle_state)" \
  "wrong terminal token classification"

TERMINAL_RUNTIME_SID="$(new_terminal_session terminal-runtime-stale)"
TERMINAL_RUNTIME_TOKEN="$(dx_session_runtime_start \
  "$TERMINAL_RUNTIME_SID" codex "$REPO_A" "$$")"
dx_session_runtime_finish "$TERMINAL_RUNTIME_SID" "$TERMINAL_RUNTIME_TOKEN" \
  completed "$$"
TERMINAL_RUNTIME_RECORD="$(dx_session_catalog_record "$TERMINAL_RUNTIME_SID" --repo "$REPO_A")"
assert_eq "completed" "$(json_field "$TERMINAL_RUNTIME_RECORD" runtime_status)" \
  "stale completed runtime fixture"
assert_eq "unknown" "$(json_field "$TERMINAL_RUNTIME_RECORD" lifecycle_state)" \
  "runtime completion requires terminal proof"

# Terminal artifacts identify a lifecycle even if its phase file is missing or
# unsafe. They cannot fall through to the runtime-only standalone completion
# rule and turn an incomplete terminal transaction green.
TERMINAL_PHASELESS_SID="$(new_terminal_session terminal-phaseless)"
write_terminal_proof "$TERMINAL_PHASELESS_SID"
TERMINAL_PHASELESS_TOKEN="$(dx_session_runtime_start \
  "$TERMINAL_PHASELESS_SID" codex "$REPO_A" "$$")"
dx_session_runtime_finish "$TERMINAL_PHASELESS_SID" \
  "$TERMINAL_PHASELESS_TOKEN" completed "$$"
rm -f "$(dx_state_file "$TERMINAL_PHASELESS_SID")"
TERMINAL_PHASELESS_RECORD="$(dx_session_catalog_record \
  "$TERMINAL_PHASELESS_SID" --repo "$REPO_A")"
assert_eq "unknown" \
  "$(json_field "$TERMINAL_PHASELESS_RECORD" lifecycle_state)" \
  "terminal artifact with missing phase blocks runtime completion"

TERMINAL_UNSAFE_PHASE_SID="$(new_terminal_session terminal-unsafe-phase)"
write_terminal_proof "$TERMINAL_UNSAFE_PHASE_SID"
TERMINAL_UNSAFE_PHASE_TOKEN="$(dx_session_runtime_start \
  "$TERMINAL_UNSAFE_PHASE_SID" codex "$REPO_A" "$$")"
dx_session_runtime_finish "$TERMINAL_UNSAFE_PHASE_SID" \
  "$TERMINAL_UNSAFE_PHASE_TOKEN" completed "$$"
chmod 0666 "$(dx_state_file "$TERMINAL_UNSAFE_PHASE_SID")"
TERMINAL_UNSAFE_PHASE_RECORD="$(dx_session_catalog_record \
  "$TERMINAL_UNSAFE_PHASE_SID" --repo "$REPO_A")"
assert_eq "unknown" \
  "$(json_field "$TERMINAL_UNSAFE_PHASE_RECORD" lifecycle_state)" \
  "terminal artifact with unsafe phase blocks runtime completion"

TERMINAL_HUMAN_ONLY_SID="$(new_terminal_session terminal-human-only)"
TERMINAL_HUMAN_ONLY_TOKEN="$(dx_session_runtime_start \
  "$TERMINAL_HUMAN_ONLY_SID" codex "$REPO_A" "$$")"
dx_session_runtime_finish "$TERMINAL_HUMAN_ONLY_SID" \
  "$TERMINAL_HUMAN_ONLY_TOKEN" completed "$$"
rm -f "$(dx_state_file "$TERMINAL_HUMAN_ONLY_SID")"
printf 'human-complete\n' \
  > "$DX_STATE_DIR/${TERMINAL_HUMAN_ONLY_SID}.human-complete"
chmod 600 "$DX_STATE_DIR/${TERMINAL_HUMAN_ONLY_SID}.human-complete"
TERMINAL_HUMAN_ONLY_RECORD="$(dx_session_catalog_record \
  "$TERMINAL_HUMAN_ONLY_SID" --repo "$REPO_A")"
assert_eq "unknown" \
  "$(json_field "$TERMINAL_HUMAN_ONLY_RECORD" lifecycle_state)" \
  "human terminal artifact cannot authorize runtime completion"

# Standalone review runtime completion is not enough by itself. The catalog
# requires the unrevoked clean receipt and rejects any durable brake.
STANDALONE_REVIEW_SID="$(cd "$REPO_A" && dx_scoped_session_id standalone-review-runtime)"
dx_meta_write "$STANDALONE_REVIEW_SID" \
  "ticket_number=standalone-review" \
  "wt_name=standalone-review" \
  "wt_dir=$REPO_A" \
  "workspace_mode=in-place"
STANDALONE_REVIEW_TOKEN="$(dx_session_runtime_start \
  "$STANDALONE_REVIEW_SID" claude "$REPO_A" "$$")"
dx_session_runtime_finish "$STANDALONE_REVIEW_SID" \
  "$STANDALONE_REVIEW_TOKEN" completed "$$"
STANDALONE_REVIEW_POLICY="$(DEX_DIR="$ROOT" DX_STATE_DIR="$DX_STATE_DIR" \
  DX_LOOP_DIR="$DX_LOOP_DIR" bash -c \
  'source "$DEX_DIR/lib/common.sh"; dx_review_policy_resolve "$1" | cut -f4' \
  _ "$REPO_A")"
DEX_DIR="$ROOT" DX_STATE_DIR="$DX_STATE_DIR" DX_LOOP_DIR="$DX_LOOP_DIR" \
  bash -c '
    source "$DEX_DIR/lib/common.sh"
    source "$DEX_DIR/tests/review-proof-fixture.sh"
    session_id="$1"
    repo_dir="$2"
    policy_binding="$3"
    fingerprint=$(dx_review_scope_fingerprint "$repo_dir") || exit 91
    evidence_file="$4/evidence.json"
    context_file="$4/context.md"
    dx_review_write_selection "$session_id" small environment \
      operator-override "$repo_dir" 1 standalone "$policy_binding" || exit 92
    dx_test_write_clean_review_proof "$session_id" catalog-clean light \
      "$fingerprint" standalone "$policy_binding" "$evidence_file" \
      "$context_file" || exit 93
    dx_review_ledger_append "$session_id" 1 catalog-clean light \
      "$fingerprint" standalone "$policy_binding" "$evidence_file" \
      "$context_file" || exit 94
  ' _ "$STANDALONE_REVIEW_SID" "$REPO_A" "$STANDALONE_REVIEW_POLICY" \
    "$TMP_DIR/standalone-review-proof"
STANDALONE_REVIEW_RECORD="$(dx_session_catalog_record \
  "$STANDALONE_REVIEW_SID" --repo "$REPO_A")"
assert_eq "unknown" "$(json_field "$STANDALONE_REVIEW_RECORD" lifecycle_state)" \
  "standalone runtime needs review receipt"
DEX_DIR="$ROOT" DX_STATE_DIR="$DX_STATE_DIR" DX_LOOP_DIR="$DX_LOOP_DIR" \
  bash -c '
    source "$DEX_DIR/lib/common.sh"
    dx_review_write_receipt "$1" small 1 1 "$2" standalone "$3"
  ' _ "$STANDALONE_REVIEW_SID" "$REPO_A" "$STANDALONE_REVIEW_POLICY"
DEX_DIR="$ROOT" DX_STATE_DIR="$DX_STATE_DIR" DX_LOOP_DIR="$DX_LOOP_DIR" \
  bash -c '
    source "$DEX_DIR/lib/common.sh"
    dx_review_receipt_valid "$1" "$2" standalone "$3"
  ' _ "$STANDALONE_REVIEW_SID" "$REPO_A" "$STANDALONE_REVIEW_POLICY" \
  || fail "standalone clean receipt fixture is invalid"
STANDALONE_REVIEW_RECORD="$(dx_session_catalog_record \
  "$STANDALONE_REVIEW_SID" --repo "$REPO_A")"
assert_eq "completed" "$(json_field "$STANDALONE_REVIEW_RECORD" lifecycle_state)" \
  "standalone clean receipt completes runtime"
chmod u+w "$DX_LOOP_DIR/${STANDALONE_REVIEW_SID}.review-proofs" \
  "$DX_LOOP_DIR/${STANDALONE_REVIEW_SID}.review-proofs/1" \
  "$DX_LOOP_DIR/${STANDALONE_REVIEW_SID}.review-proofs/1/evidence.json"
rm -f "$DX_LOOP_DIR/${STANDALONE_REVIEW_SID}.review-proofs/1/evidence.json"
STANDALONE_REVIEW_RECORD="$(dx_session_catalog_record \
  "$STANDALONE_REVIEW_SID" --repo "$REPO_A")"
assert_eq "unknown" "$(json_field "$STANDALONE_REVIEW_RECORD" lifecycle_state)" \
  "standalone completion reopens retained review proof"
printf 'revoked\n' > "$DX_LOOP_DIR/${STANDALONE_REVIEW_SID}.review-receipt.revoked"
chmod 600 "$DX_LOOP_DIR/${STANDALONE_REVIEW_SID}.review-receipt.revoked"
STANDALONE_REVIEW_RECORD="$(dx_session_catalog_record \
  "$STANDALONE_REVIEW_SID" --repo "$REPO_A")"
assert_eq "unknown" "$(json_field "$STANDALONE_REVIEW_RECORD" lifecycle_state)" \
  "revoked standalone receipt is not complete"
rm -f "$(dx_review_selection_file "$STANDALONE_REVIEW_SID")" \
  "$(dx_review_receipt_file "$STANDALONE_REVIEW_SID")" \
  "$DX_LOOP_DIR/${STANDALONE_REVIEW_SID}.review-receipt.revoked"
printf 'revoked\n' \
  > "$DX_LOOP_DIR/${STANDALONE_REVIEW_SID}.review-selection.revoked"
chmod 600 "$DX_LOOP_DIR/${STANDALONE_REVIEW_SID}.review-selection.revoked"
STANDALONE_REVIEW_RECORD="$(dx_session_catalog_record \
  "$STANDALONE_REVIEW_SID" --repo "$REPO_A")"
assert_eq "unknown" "$(json_field "$STANDALONE_REVIEW_RECORD" lifecycle_state)" \
  "selection revocation alone blocks stale runtime completion"

# A durable cleanup journal is visible as a lifecycle brake even if it is the
# only state left that explains why this session must not resume.
CLEANUP_JOURNAL_SID="$(cd "$REPO_A" && dx_scoped_session_id branch-cleanup-journal)"
dx_meta_write "$CLEANUP_JOURNAL_SID" \
  "ticket_number=cleanup-journal" \
  "wt_name=cleanup-journal" \
  "wt_dir=$REPO_A" \
  "workspace_mode=in-place"
printf 'dex-cleanup-journal-v1\t%s\n{}\n' "$CLEANUP_JOURNAL_SID" \
  > "$DX_LOOP_DIR/${CLEANUP_JOURNAL_SID}.cleanup-journal"
chmod 600 "$DX_LOOP_DIR/${CLEANUP_JOURNAL_SID}.cleanup-journal"
CLEANUP_JOURNAL_RECORD="$(dx_session_catalog_record \
  "$CLEANUP_JOURNAL_SID" --repo "$REPO_A")"
assert_eq "cleanup-in-progress" \
  "$(json_field "$CLEANUP_JOURNAL_RECORD" lifecycle_state)" \
  "cleanup journal lifecycle brake"
assert_contains '"cleanup-journal"' \
  <(printf '%s\n' "$CLEANUP_JOURNAL_RECORD")

if dx_session_catalog_records --repo "$TMP_DIR/not-a-repo" >/dev/null 2>&1; then
  fail "catalog accepted a non-repository"
else
  assert_eq "3" "$?" "invalid repository result"
fi

printf 'session catalog core tests passed\n'
