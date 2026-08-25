#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-session-cleanup.XXXXXX")"

cleanup() {
  chmod -R u+w "$TMP_DIR" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_RUN_ROOT="$TMP_DIR/runs"
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR" "$DX_RUN_ROOT"

# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=tests/review-proof-fixture.sh
source "$ROOT/tests/review-proof-fixture.sh"

new_repo() { # <directory>
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

write_terminal_proof() { # <sid>
  local session_id="$1"
  printf 'version=1\nphase=7\ntransition_token=100-200-300\nauthority=0123456789abcdef0123456789abcdef\n' \
    > "$DX_STATE_DIR/${session_id}.terminal-commit"
  chmod 600 "$DX_STATE_DIR/${session_id}.terminal-commit"
}

make_lifecycle() { # <repo> <suffix> <phase> <runtime-state> <proof:0|1>
  local repo_dir="$1" suffix="$2" phase="$3" runtime_state="$4"
  local with_proof="$5" session_id runtime_token
  session_id="$(cd "$repo_dir" && dx_scoped_session_id "$suffix")"
  dx_meta_write "$session_id" \
    "ticket_number=$suffix" \
    "wt_name=$suffix" \
    "wt_dir=$repo_dir" \
    "workspace_mode=in-place"
  printf '%s\n' "$phase" > "$(dx_state_file "$session_id")"
  chmod 600 "$(dx_state_file "$session_id")"
  [[ "$with_proof" -eq 0 ]] || write_terminal_proof "$session_id"
  runtime_token="$(dx_session_runtime_start \
    "$session_id" codex "$repo_dir" "$$")"
  dx_session_runtime_finish "$session_id" "$runtime_token" \
    "$runtime_state" "$$"
  LAST_SESSION_ID="$session_id"
  LAST_RUNTIME_TOKEN="$runtime_token"
}

run_sessions() { # <repo> <output> <arguments...>
  local repo_dir="$1" output_file="$2"
  shift 2
  if (cd "$repo_dir" && bash "$ROOT/bin/sessions.sh" "$@") \
      > "$output_file" 2>&1; then
    COMMAND_RESULT=0
  else
    COMMAND_RESULT=$?
  fi
}

state_fingerprint() {
  python3 - "$DX_STATE_DIR" "$DX_LOOP_DIR" <<'PY'
import hashlib
import os
import stat
import sys


for root in sys.argv[1:]:
    if not os.path.isdir(root):
        continue
    for directory, names, files in os.walk(root, followlinks=False):
        for name in sorted(names + files):
            target = os.path.join(directory, name)
            metadata = os.lstat(target)
            digest = "-"
            if stat.S_ISREG(metadata.st_mode):
                with open(target, "rb") as source:
                    digest = hashlib.sha256(source.read()).hexdigest()
            print(
                "\t".join(
                    (
                        os.path.relpath(target, root),
                        str(metadata.st_dev),
                        str(metadata.st_ino),
                        str(metadata.st_mode),
                        str(metadata.st_nlink),
                        str(metadata.st_size),
                        str(metadata.st_mtime_ns),
                        digest,
                    )
                )
            )
PY
}

catalog_field() { # <repo> <sid> <field>
  local repo_dir="$1" session_id="$2" field_name="$3" record
  record="$(dx_session_catalog_record "$session_id" --repo "$repo_dir")"
  python3 - "$field_name" "$record" <<'PY'
import json
import sys


value = json.loads(sys.argv[2])[sys.argv[1]]
if isinstance(value, list):
    print(",".join(value))
else:
    print(value)
PY
}

REPO="$TMP_DIR/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email dex@example.test
git -C "$REPO" config user.name "Dex Test"
printf 'base\n' > "$REPO/file.txt"
git -C "$REPO" add file.txt
git -C "$REPO" commit -q -m "test: initialize repo"
git -C "$REPO" branch -m main

COMPLETED_SID="$(cd "$REPO" && dx_scoped_session_id cleanup-completed)"
dx_meta_write "$COMPLETED_SID" \
  "ticket_number=cleanup-completed" \
  "wt_name=cleanup-completed" \
  "wt_dir=$REPO" \
  "workspace_mode=in-place"
printf '7\n' > "$(dx_state_file "$COMPLETED_SID")"
chmod 600 "$(dx_state_file "$COMPLETED_SID")"
write_terminal_proof "$COMPLETED_SID"
COMPLETED_TOKEN="$(dx_session_runtime_start \
  "$COMPLETED_SID" codex "$REPO" "$$")"
dx_session_runtime_finish "$COMPLETED_SID" "$COMPLETED_TOKEN" completed "$$"

state_fingerprint > "$TMP_DIR/dry-run.before"
run_sessions "$REPO" "$TMP_DIR/dry-run.out" cleanup --dry-run
state_fingerprint > "$TMP_DIR/dry-run.after"
assert_eq "0" "$COMMAND_RESULT" "cleanup dry-run result"
assert_contains "$COMPLETED_SID" "$TMP_DIR/dry-run.out"
cmp -s "$TMP_DIR/dry-run.before" "$TMP_DIR/dry-run.after" \
  || fail "cleanup dry-run changed session inode or mtime state"
assert_file "$(dx_meta_file "$COMPLETED_SID")"
assert_file "$(dx_session_runtime_file "$COMPLETED_SID")"
assert_no_file "$(dx_session_claim_root)"
assert_no_file "$(dx_lifecycle_control_lock_dir "$COMPLETED_SID")"
assert_no_file "$(dx_session_cleanup_journal_file "$COMPLETED_SID")"

dx_session_catalog_records --repo "$REPO" --include-children \
  > "$TMP_DIR/records.jsonl"
python3 - "$TMP_DIR/records.jsonl" "$TMP_DIR/bool-schema.jsonl" <<'PY'
import json
import sys


with open(sys.argv[1], encoding="utf-8") as source:
    record = json.loads(next(source))
record["schema_version"] = True
with open(sys.argv[2], "w", encoding="utf-8") as target:
    target.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")
PY
CLASSIFIER_RESULT=0
__dx_session_management_completed_candidates \
  "$REPO" "$TMP_DIR/bool-schema.jsonl" \
  > "$TMP_DIR/bool-schema.out" 2>&1 || CLASSIFIER_RESULT=$?
assert_eq "3" "$CLASSIFIER_RESULT" "boolean catalog schema rejection"

for REQUIRED_ARTIFACT in phase runtime runtime-lock terminal-commit; do
  python3 - "$TMP_DIR/records.jsonl" \
    "$TMP_DIR/missing-${REQUIRED_ARTIFACT}.jsonl" "$REQUIRED_ARTIFACT" <<'PY'
import json
import sys


with open(sys.argv[1], encoding="utf-8") as source:
    record = json.loads(next(source))
record["artifacts"] = [
    artifact for artifact in record["artifacts"] if artifact != sys.argv[3]
]
with open(sys.argv[2], "w", encoding="utf-8") as target:
    target.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")
PY
  __dx_session_management_completed_candidates \
    "$REPO" "$TMP_DIR/missing-${REQUIRED_ARTIFACT}.jsonl" \
    > "$TMP_DIR/missing-${REQUIRED_ARTIFACT}.out"
  assert_eq "" "$(cat "$TMP_DIR/missing-${REQUIRED_ARTIFACT}.out")" \
    "missing ${REQUIRED_ARTIFACT} candidate rejection"
done

mkdir -p "$(dx_review_proof_dir "$COMPLETED_SID")/1"
ln -s "$TMP_DIR" "$(dx_review_proof_dir "$COMPLETED_SID")/1/unsafe-link"
dx_session_catalog_records --repo "$REPO" --include-children \
  > "$TMP_DIR/nested-unsafe-records.jsonl"
__dx_session_management_completed_candidates \
  "$REPO" "$TMP_DIR/nested-unsafe-records.jsonl" \
  > "$TMP_DIR/nested-unsafe.out"
assert_not_contains "$COMPLETED_SID" "$TMP_DIR/nested-unsafe.out"
rm -f "$(dx_review_proof_dir "$COMPLETED_SID")/1/unsafe-link"
rmdir "$(dx_review_proof_dir "$COMPLETED_SID")/1" \
  "$(dx_review_proof_dir "$COMPLETED_SID")"

# The completed-only classifier ignores every resumable, failed, ambiguous,
# standalone, and cross-repository record. It emits eligible parents in
# session-ID order and treats valid review children as part of their parent.
POLICY_REPO="$TMP_DIR/policy-repo"
OTHER_REPO="$TMP_DIR/other-repo"
new_repo "$POLICY_REPO"
new_repo "$OTHER_REPO"

make_lifecycle "$POLICY_REPO" cleanup-z-eligible 7 completed 1
ELIGIBLE_Z="$LAST_SESSION_ID"
make_lifecycle "$POLICY_REPO" cleanup-a-eligible 7 completed 1
ELIGIBLE_A="$LAST_SESSION_ID"
EXCLUDED_TERMINAL_SIDS=""
for TERMINAL_STATE in paused blocked failed stopped abandoned; do
  make_lifecycle "$POLICY_REPO" "cleanup-${TERMINAL_STATE}" 7 \
    "$TERMINAL_STATE" 1
  EXCLUDED_TERMINAL_SIDS="${EXCLUDED_TERMINAL_SIDS}${LAST_SESSION_ID}
"
done
make_lifecycle "$POLICY_REPO" cleanup-phase-six 6 completed 0
PHASE_SIX_SID="$LAST_SESSION_ID"
make_lifecycle "$POLICY_REPO" cleanup-missing-proof 7 completed 0
MISSING_PROOF_SID="$LAST_SESSION_ID"

RUNTIME_ONLY_SID="$(cd "$POLICY_REPO" && \
  dx_scoped_session_id cleanup-runtime-only)"
RUNTIME_ONLY_TOKEN="$(dx_session_runtime_start \
  "$RUNTIME_ONLY_SID" codex "$POLICY_REPO" "$$")"
dx_session_runtime_finish \
  "$RUNTIME_ONLY_SID" "$RUNTIME_ONLY_TOKEN" completed "$$"

STANDALONE_SID="$(cd "$POLICY_REPO" && \
  dx_scoped_session_id cleanup-standalone-review)"
STANDALONE_TOKEN="$(dx_session_runtime_start \
  "$STANDALONE_SID" codex "$POLICY_REPO" "$$")"
dx_session_runtime_finish "$STANDALONE_SID" "$STANDALONE_TOKEN" completed "$$"
STANDALONE_POLICY="$(dx_review_policy_resolve "$POLICY_REPO" | cut -f4)"
STANDALONE_FINGERPRINT="$(dx_review_scope_fingerprint "$POLICY_REPO")"
STANDALONE_EVIDENCE="$TMP_DIR/standalone-proof/evidence.json"
STANDALONE_CONTEXT="$TMP_DIR/standalone-proof/context.md"
dx_review_write_selection "$STANDALONE_SID" small environment \
  operator-override "$POLICY_REPO" 1 standalone "$STANDALONE_POLICY"
dx_test_write_clean_review_proof "$STANDALONE_SID" cleanup-clean light \
  "$STANDALONE_FINGERPRINT" standalone "$STANDALONE_POLICY" \
  "$STANDALONE_EVIDENCE" "$STANDALONE_CONTEXT"
dx_review_ledger_append "$STANDALONE_SID" 1 cleanup-clean light \
  "$STANDALONE_FINGERPRINT" standalone "$STANDALONE_POLICY" \
  "$STANDALONE_EVIDENCE" "$STANDALONE_CONTEXT"
dx_review_write_receipt "$STANDALONE_SID" small 1 1 "$POLICY_REPO" \
  standalone "$STANDALONE_POLICY"

make_lifecycle "$POLICY_REPO" cleanup-in-progress 7 completed 1
CLEANUP_JOURNAL_SID="$LAST_SESSION_ID"
printf 'dex-cleanup-journal-v1\t%s\n{}\n' "$CLEANUP_JOURNAL_SID" \
  > "$DX_LOOP_DIR/${CLEANUP_JOURNAL_SID}.cleanup-journal"
chmod 600 "$DX_LOOP_DIR/${CLEANUP_JOURNAL_SID}.cleanup-journal"

make_lifecycle "$POLICY_REPO" cleanup-ambiguous-parent 7 completed 1
AMBIGUOUS_PARENT="$LAST_SESSION_ID"
AMBIGUOUS_CHILD="${AMBIGUOUS_PARENT:0:120}-pass-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
dx_meta_write "$AMBIGUOUS_CHILD" \
  "ticket_number=ambiguous-child" \
  "wt_name=ambiguous-child" \
  "wt_dir=$POLICY_REPO" \
  "workspace_mode=in-place"
printf '3\n' > "$(dx_state_file "$AMBIGUOUS_CHILD")"
chmod 600 "$(dx_state_file "$AMBIGUOUS_CHILD")"

make_lifecycle "$POLICY_REPO" cleanup-with-child 7 completed 1
CHILD_PARENT="$LAST_SESSION_ID"
CHILD_SID="${CHILD_PARENT:0:120}-assessment-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
dx_meta_write "$CHILD_SID" \
  "session_role=review-child" \
  "parent_session_id=$CHILD_PARENT" \
  "child_kind=assessment"
printf '3\n' > "$(dx_state_file "$CHILD_SID")"
chmod 600 "$(dx_state_file "$CHILD_SID")"
printf 'child residue\n' > "$(dx_review_state_file "$CHILD_SID")"

ORPHAN_CHILD_SID="$(cd "$POLICY_REPO" && \
  dx_scoped_session_id cleanup-orphan-child)-review-eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
ORPHAN_PARENT_SID="$(cd "$POLICY_REPO" && \
  dx_scoped_session_id cleanup-missing-parent)"
dx_meta_write "$ORPHAN_CHILD_SID" \
  "session_role=review-child" \
  "parent_session_id=$ORPHAN_PARENT_SID" \
  "child_kind=review"
printf '3\n' > "$(dx_state_file "$ORPHAN_CHILD_SID")"
chmod 600 "$(dx_state_file "$ORPHAN_CHILD_SID")"

make_lifecycle "$OTHER_REPO" cleanup-other-repository 7 completed 1
OTHER_REPO_SID="$LAST_SESSION_ID"

assert_eq "completed" \
  "$(catalog_field "$POLICY_REPO" "$RUNTIME_ONLY_SID" lifecycle_state)" \
  "runtime fragment catalog state"
assert_eq "runtime,runtime-lock" \
  "$(catalog_field "$POLICY_REPO" "$RUNTIME_ONLY_SID" artifacts)" \
  "runtime fragment artifact shape"
assert_eq "completed" \
  "$(catalog_field "$POLICY_REPO" "$STANDALONE_SID" lifecycle_state)" \
  "standalone review catalog state"

state_fingerprint > "$TMP_DIR/policy-dry-run.before"
run_sessions "$POLICY_REPO" "$TMP_DIR/policy-dry-run.out" cleanup --dry-run
state_fingerprint > "$TMP_DIR/policy-dry-run.after"
assert_eq "0" "$COMMAND_RESULT" "policy dry-run result"
cmp -s "$TMP_DIR/policy-dry-run.before" "$TMP_DIR/policy-dry-run.after" \
  || fail "policy dry-run changed session inode or mtime state"
assert_contains "$ELIGIBLE_A" "$TMP_DIR/policy-dry-run.out"
assert_contains "$ELIGIBLE_Z" "$TMP_DIR/policy-dry-run.out"
assert_contains "$CHILD_PARENT" "$TMP_DIR/policy-dry-run.out"
assert_not_contains "$CHILD_SID" "$TMP_DIR/policy-dry-run.out"
assert_not_contains "$ORPHAN_CHILD_SID" "$TMP_DIR/policy-dry-run.out"
while IFS= read -r EXCLUDED_TERMINAL_SID; do
  [[ -n "$EXCLUDED_TERMINAL_SID" ]] || continue
  assert_not_contains "$EXCLUDED_TERMINAL_SID" "$TMP_DIR/policy-dry-run.out"
done <<EOF
$EXCLUDED_TERMINAL_SIDS
EOF
assert_not_contains "$PHASE_SIX_SID" "$TMP_DIR/policy-dry-run.out"
assert_not_contains "$MISSING_PROOF_SID" "$TMP_DIR/policy-dry-run.out"
assert_not_contains "$RUNTIME_ONLY_SID" "$TMP_DIR/policy-dry-run.out"
assert_not_contains "$STANDALONE_SID" "$TMP_DIR/policy-dry-run.out"
assert_not_contains "$CLEANUP_JOURNAL_SID" "$TMP_DIR/policy-dry-run.out"
assert_not_contains "$AMBIGUOUS_PARENT" "$TMP_DIR/policy-dry-run.out"
assert_not_contains "$OTHER_REPO_SID" "$TMP_DIR/policy-dry-run.out"
assert_no_file "$(dx_session_claim_root)"
assert_no_file "$(dx_lifecycle_control_lock_dir "$ELIGIBLE_A")"
assert_no_file "$(dx_session_cleanup_journal_file "$ELIGIBLE_A")"
python3 - "$TMP_DIR/policy-dry-run.out" "$ELIGIBLE_A" "$ELIGIBLE_Z" <<'PY'
import sys


with open(sys.argv[1], encoding="utf-8") as source:
    output = source.read()
if output.index(sys.argv[2]) >= output.index(sys.argv[3]):
    raise SystemExit("cleanup dry-run output is not sorted by session ID")
PY

# Mutation removes eligible parents and their validated children, but leaves
# paused state and every checkout untouched.
ACTUAL_REPO="$TMP_DIR/actual-repo"
new_repo "$ACTUAL_REPO"
make_lifecycle "$ACTUAL_REPO" cleanup-actual 7 completed 1
ACTUAL_PARENT="$LAST_SESSION_ID"
ACTUAL_CHILD="${ACTUAL_PARENT:0:120}-pass-cccccccccccccccccccccccccccccccc"
dx_meta_write "$ACTUAL_CHILD" \
  "session_role=review-child" \
  "parent_session_id=$ACTUAL_PARENT" \
  "child_kind=pass"
printf '3\n' > "$(dx_state_file "$ACTUAL_CHILD")"
chmod 600 "$(dx_state_file "$ACTUAL_CHILD")"
make_lifecycle "$ACTUAL_REPO" cleanup-actual-paused 7 paused 1
ACTUAL_PAUSED="$LAST_SESSION_ID"
printf 'dirty\n' >> "$ACTUAL_REPO/file.txt"
ACTUAL_CHECKOUT_BEFORE="$(git -C "$ACTUAL_REPO" status --porcelain=v1)"

run_sessions "$ACTUAL_REPO" "$TMP_DIR/actual.out" cleanup
if [[ "$COMMAND_RESULT" -ne 0 ]]; then
  cat "$TMP_DIR/actual.out" >&2
fi
assert_eq "0" "$COMMAND_RESULT" "completed cleanup result"
assert_contains "Cleanup finished: 1 completed lifecycle session(s) cleaned." \
  "$TMP_DIR/actual.out"
assert_no_file "$(dx_meta_file "$ACTUAL_PARENT")"
assert_no_file "$(dx_session_runtime_file "$ACTUAL_PARENT")"
assert_file "$(dx_session_runtime_file "$ACTUAL_PARENT")-lock"
assert_no_file "$(dx_meta_file "$ACTUAL_CHILD")"
assert_file "$(dx_meta_file "$ACTUAL_PAUSED")"
assert_file "$(dx_session_runtime_file "$ACTUAL_PAUSED")"
assert_eq "$ACTUAL_CHECKOUT_BEFORE" \
  "$(git -C "$ACTUAL_REPO" status --porcelain=v1)" \
  "cleanup preserves checkout state"

# Contention on one candidate does not stop later candidates. The command
# reports a partial failure without printing the private claim token.
PARTIAL_REPO="$TMP_DIR/partial-repo"
new_repo "$PARTIAL_REPO"
make_lifecycle "$PARTIAL_REPO" cleanup-a-contended 7 completed 1
CONTENDED_SID="$LAST_SESSION_ID"
CONTENDED_RUNTIME_TOKEN="$LAST_RUNTIME_TOKEN"
make_lifecycle "$PARTIAL_REPO" cleanup-z-continues 7 completed 1
CONTINUED_SID="$LAST_SESSION_ID"
CONTINUED_RUNTIME_TOKEN="$LAST_RUNTIME_TOKEN"
CORRUPT_SECRET="DO_NOT_PRINT_THIS_CLEANUP_RUNTIME_SECRET"
CORRUPT_SID="$(cd "$PARTIAL_REPO" && \
  dx_scoped_session_id cleanup-corrupt-runtime)"
dx_meta_write "$CORRUPT_SID" \
  "ticket_number=cleanup-corrupt-runtime" \
  "wt_name=cleanup-corrupt-runtime" \
  "wt_dir=$PARTIAL_REPO" \
  "workspace_mode=in-place"
printf '7\n' > "$(dx_state_file "$CORRUPT_SID")"
chmod 600 "$(dx_state_file "$CORRUPT_SID")"
printf '{"token":"%s"\n' "$CORRUPT_SECRET" \
  > "$(dx_session_runtime_file "$CORRUPT_SID")"
chmod 600 "$(dx_session_runtime_file "$CORRUPT_SID")"
dx_session_claim_acquire "$CONTENDED_SID" cleanup
PRIVATE_CLAIM_TOKEN="$DX_SESSION_CLAIM_TOKEN"
if (
  cd "$PARTIAL_REPO"
  DEX_SESSION_CLAIM_ATTEMPTS=1 bash "$ROOT/bin/sessions.sh" cleanup
) > "$TMP_DIR/partial.out" 2>&1; then
  COMMAND_RESULT=0
else
  COMMAND_RESULT=$?
fi
dx_session_claim_release_checked "$CONTENDED_SID"
assert_eq "1" "$COMMAND_RESULT" "partial cleanup result"
assert_contains "1 session(s) cleaned and 1 not cleaned" "$TMP_DIR/partial.out"
assert_contains "$CONTENDED_SID" "$TMP_DIR/partial.out"
assert_contains "$CONTINUED_SID" "$TMP_DIR/partial.out"
assert_not_contains "$PRIVATE_CLAIM_TOKEN" "$TMP_DIR/partial.out"
assert_not_contains "$CONTENDED_RUNTIME_TOKEN" "$TMP_DIR/partial.out"
assert_not_contains "$CONTINUED_RUNTIME_TOKEN" "$TMP_DIR/partial.out"
assert_not_contains "$CORRUPT_SECRET" "$TMP_DIR/partial.out"
assert_not_contains '"token"' "$TMP_DIR/partial.out"
assert_file "$(dx_meta_file "$CONTENDED_SID")"
assert_no_file "$(dx_meta_file "$CONTINUED_SID")"

printf '%s\n' "session cleanup tests passed"
