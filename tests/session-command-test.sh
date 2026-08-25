#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-session-command.XXXXXX")"
TEST_PIDS=""

cleanup() {
  local child_pid
  for child_pid in $TEST_PIDS; do
    kill "$child_pid" 2>/dev/null || true
    wait "$child_pid" 2>/dev/null || true
  done
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_SESSION_RUNTIME_PROC_ROOT="$TMP_DIR/proc"
export DX_SESSION_RUNTIME_PS_BIN="$TMP_DIR/no-ps"
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR" \
  "$DX_SESSION_RUNTIME_PROC_ROOT/sys/kernel/random"
printf '%s\n' '01234567-89ab-cdef-0123-456789abcdef' \
  > "$DX_SESSION_RUNTIME_PROC_ROOT/sys/kernel/random/boot_id"

# shellcheck source=lib/session.sh
source "$ROOT/lib/session.sh"
# shellcheck source=lib/session-runtime.sh
source "$ROOT/lib/session-runtime.sh"

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

start_fixture_process() {
  local process_output="$1"
  sleep 60 > "$process_output" 2>&1 &
  FIXTURE_PID=$!
  TEST_PIDS="${TEST_PIDS} ${FIXTURE_PID}"
}

write_proc_identity() {
  local process_pid="$1" start_ticks="$2" process_state="${3:-S}"
  mkdir -p "$DX_SESSION_RUNTIME_PROC_ROOT/$process_pid"
  printf '%s\n' \
    "$process_pid (dex sessions fixture) $process_state 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 $start_ticks 20" \
    > "$DX_SESSION_RUNTIME_PROC_ROOT/$process_pid/stat"
}

write_session() {
  local repo_dir="$1" session_id="$2" ticket="$3" workspace_name="$4" phase="$5"
  local phase_file
  dx_meta_write "$session_id" \
    "ticket_number=$ticket" \
    "wt_name=$workspace_name" \
    "wt_dir=$repo_dir" \
    "workspace_mode=in-place"
  phase_file=$(dx_state_file "$session_id")
  printf '%s\n' "$phase" > "$phase_file"
  chmod 600 "$phase_file"
}

run_sessions() {
  local working_dir="$1" output_file="$2"
  shift 2
  if (cd "$working_dir" && bash "$ROOT/bin/sessions.sh" "$@") \
    > "$output_file" 2>&1; then
    COMMAND_RESULT=0
  else
    COMMAND_RESULT=$?
  fi
}

state_snapshot() {
  find "$DX_STATE_DIR" "$DX_LOOP_DIR" -type f -exec cksum {} \; 2>/dev/null \
    | LC_ALL=C sort
}

REPO_A="$TMP_DIR/repos/alpha"
REPO_B="$TMP_DIR/repos/bravo"
REPO_EMPTY="$TMP_DIR/repos/empty"
new_repo "$REPO_A"
new_repo "$REPO_B"
new_repo "$REPO_EMPTY"

SID_LIVE="$(cd "$REPO_A" && dx_scoped_session_id branch-live)"
SID_DUPLICATE="$(cd "$REPO_A" && dx_scoped_session_id branch-duplicate)"
SID_DEAD="$(cd "$REPO_A" && dx_scoped_session_id branch-dead)"
SID_UNVERIFIABLE="$(cd "$REPO_A" && dx_scoped_session_id branch-unverifiable)"
SID_CORRUPT="$(cd "$REPO_A" && dx_scoped_session_id branch-corrupt)"
SID_UNSAFE="$(cd "$REPO_A" && dx_scoped_session_id branch-unsafe)"
SID_PROVIDER_CORRUPT="$(cd "$REPO_A" && dx_scoped_session_id branch-provider-corrupt)"
SID_PROVIDER_DUPLICATE="$(cd "$REPO_A" && dx_scoped_session_id branch-provider-duplicate)"
SID_PROVIDER_MISMATCH="$(cd "$REPO_A" && dx_scoped_session_id branch-provider-mismatch)"
SID_LEGACY="$(cd "$REPO_A" && dx_scoped_session_id branch-legacy)"
SID_B="$(cd "$REPO_B" && dx_scoped_session_id branch-bravo)"
CHILD_SID="${SID_LIVE}-pass-20260824T101112Z_123_deadbeef"

write_session "$REPO_A" "$SID_LIVE" 101 live 2
write_session "$REPO_A" "$SID_DUPLICATE" 101 duplicate 1
write_session "$REPO_A" "$SID_DEAD" 202 dead 3
write_session "$REPO_A" "$SID_UNVERIFIABLE" 303 unverifiable 4
write_session "$REPO_A" "$SID_CORRUPT" 404 corrupt 5
write_session "$REPO_A" "$SID_UNSAFE" 405 unsafe 5
write_session "$REPO_A" "$SID_PROVIDER_CORRUPT" 406 provider-corrupt 5
write_session "$REPO_A" "$SID_PROVIDER_DUPLICATE" 407 provider-duplicate 5
write_session "$REPO_A" "$SID_PROVIDER_MISMATCH" 408 provider-mismatch 5
write_session "$REPO_A" "$SID_LEGACY" 505 legacy 2
write_session "$REPO_B" "$SID_B" 606 bravo 1

dx_meta_write "$CHILD_SID" \
  "session_role=review-child" \
  "parent_session_id=$SID_LIVE" \
  "child_kind=pass"
printf '3\n' > "$(dx_state_file "$CHILD_SID")"
chmod 600 "$(dx_state_file "$CHILD_SID")"

start_fixture_process "$TMP_DIR/live-process.out"
LIVE_PID=$FIXTURE_PID
write_proc_identity "$LIVE_PID" 111111
LIVE_TOKEN="$(dx_session_runtime_start "$SID_LIVE" codex "$REPO_A" "$LIVE_PID")"
printf 'engine=codex-plugin\nsession=%s\n' "$SID_LIVE" \
  > "$(dx_provider_state_file "$SID_LIVE")"
PROVIDER_CORRUPT_TOKEN="$(dx_session_runtime_start \
  "$SID_PROVIDER_CORRUPT" codex "$REPO_A" "$LIVE_PID")"
PROVIDER_DUPLICATE_TOKEN="$(dx_session_runtime_start \
  "$SID_PROVIDER_DUPLICATE" codex "$REPO_A" "$LIVE_PID")"
PROVIDER_MISMATCH_TOKEN="$(dx_session_runtime_start \
  "$SID_PROVIDER_MISMATCH" codex "$REPO_A" "$LIVE_PID")"
printf 'this-is-not-provider-state\n' \
  > "$(dx_provider_state_file "$SID_PROVIDER_CORRUPT")"
printf 'engine=codex\nengine=claude\nsession=%s\n' "$SID_PROVIDER_DUPLICATE" \
  > "$(dx_provider_state_file "$SID_PROVIDER_DUPLICATE")"
printf 'engine=claude\nsession=%s\n' "$SID_PROVIDER_MISMATCH" \
  > "$(dx_provider_state_file "$SID_PROVIDER_MISMATCH")"

start_fixture_process "$TMP_DIR/dead-process.out"
DEAD_PID=$FIXTURE_PID
write_proc_identity "$DEAD_PID" 222222
DEAD_TOKEN="$(dx_session_runtime_start "$SID_DEAD" claude "$REPO_A" "$DEAD_PID")"
kill "$DEAD_PID"
wait "$DEAD_PID" 2>/dev/null || true

start_fixture_process "$TMP_DIR/unverifiable-process.out"
UNVERIFIABLE_PID=$FIXTURE_PID
write_proc_identity "$UNVERIFIABLE_PID" 333333
UNVERIFIABLE_TOKEN="$(dx_session_runtime_start \
  "$SID_UNVERIFIABLE" codex "$REPO_A" "$UNVERIFIABLE_PID")"
rm "$DX_SESSION_RUNTIME_PROC_ROOT/$UNVERIFIABLE_PID/stat"

CORRUPT_SECRET='DO_NOT_PRINT_THIS_RUNTIME_SECRET'
printf '{"token":"%s"\n' "$CORRUPT_SECRET" > "$(dx_session_runtime_file "$SID_CORRUPT")"
chmod 600 "$(dx_session_runtime_file "$SID_CORRUPT")"
chmod 666 "$(dx_state_file "$SID_UNSAFE")"

# Age is display data, not evidence that a legacy session is stale.
touch -t 200001010000 "$(dx_state_file "$SID_LEGACY")"

run_sessions "$REPO_A" "$TMP_DIR/help.out" --help
assert_eq "0" "$COMMAND_RESULT" "help result"
assert_contains "Usage: dx sessions <list|show|doctor>" "$TMP_DIR/help.out"
assert_contains "without changing them" "$TMP_DIR/help.out"

run_sessions "$REPO_A" "$TMP_DIR/missing-command.out"
assert_eq "1" "$COMMAND_RESULT" "missing command result"
assert_contains "requires a command" "$TMP_DIR/missing-command.out"
run_sessions "$REPO_A" "$TMP_DIR/unknown-command.out" unknown
assert_eq "1" "$COMMAND_RESULT" "unknown command result"
assert_contains "Unknown dx sessions command: unknown" "$TMP_DIR/unknown-command.out"
run_sessions "$REPO_A" "$TMP_DIR/list-extra.out" list extra
assert_eq "1" "$COMMAND_RESULT" "list extra argument result"
assert_contains "Unknown dx sessions list option: extra" "$TMP_DIR/list-extra.out"
run_sessions "$REPO_A" "$TMP_DIR/list-duplicate.out" list --all --all
assert_eq "1" "$COMMAND_RESULT" "duplicate list option result"
assert_contains "accepts --all once" "$TMP_DIR/list-duplicate.out"
run_sessions "$REPO_A" "$TMP_DIR/show-missing.out" show
assert_eq "1" "$COMMAND_RESULT" "show missing selector result"
assert_contains "requires one selector" "$TMP_DIR/show-missing.out"
run_sessions "$REPO_A" "$TMP_DIR/show-all.out" show "$SID_LIVE" --all
assert_eq "1" "$COMMAND_RESULT" "show all option result"
assert_contains "Unknown dx sessions show option: --all" "$TMP_DIR/show-all.out"
run_sessions "$REPO_A" "$TMP_DIR/doctor-extra.out" doctor one two
assert_eq "1" "$COMMAND_RESULT" "doctor extra selector result"
assert_contains "accepts at most one selector" "$TMP_DIR/doctor-extra.out"

run_sessions "$REPO_A" "$TMP_DIR/list.out" list
assert_eq "0" "$COMMAND_RESULT" "repository list result"
assert_contains "$SID_LIVE" "$TMP_DIR/list.out"
assert_contains "$SID_CORRUPT" "$TMP_DIR/list.out"
assert_not_contains "$SID_B" "$TMP_DIR/list.out"
assert_not_contains "$CHILD_SID" "$TMP_DIR/list.out"

run_sessions "$REPO_A" "$TMP_DIR/list-children.out" list --include-children
assert_eq "0" "$COMMAND_RESULT" "child-inclusive list result"
assert_contains "$CHILD_SID" "$TMP_DIR/list-children.out"

# Global discovery works outside a repository and includes trusted legacy metadata.
run_sessions "$TMP_DIR" "$TMP_DIR/list-all.out" list --all
assert_eq "0" "$COMMAND_RESULT" "global list result"
assert_contains "$SID_LIVE" "$TMP_DIR/list-all.out"
assert_contains "$SID_B" "$TMP_DIR/list-all.out"
assert_not_contains "$CHILD_SID" "$TMP_DIR/list-all.out"
run_sessions "$TMP_DIR" "$TMP_DIR/list-all-children.out" \
  list --all --include-children
assert_eq "0" "$COMMAND_RESULT" "global child-inclusive list result"
assert_contains "$CHILD_SID" "$TMP_DIR/list-all-children.out"

run_sessions "$TMP_DIR" "$TMP_DIR/list-outside-repo.out" list
assert_eq "3" "$COMMAND_RESULT" "repository context result"
assert_contains "use 'dx sessions list --all'" "$TMP_DIR/list-outside-repo.out"
run_sessions "$REPO_EMPTY" "$TMP_DIR/list-empty.out" list
assert_eq "0" "$COMMAND_RESULT" "empty repository list result"
assert_contains "No lifecycle sessions found" "$TMP_DIR/list-empty.out"
run_sessions "$REPO_EMPTY" "$TMP_DIR/doctor-empty.out" doctor
assert_eq "0" "$COMMAND_RESULT" "empty repository doctor result"
assert_contains "No lifecycle sessions found" "$TMP_DIR/doctor-empty.out"

run_sessions "$REPO_A" "$TMP_DIR/show-live.out" show "session:$SID_LIVE"
assert_eq "0" "$COMMAND_RESULT" "show exact session result"
assert_contains "Session: $SID_LIVE" "$TMP_DIR/show-live.out"
assert_contains "Lifecycle state: active" "$TMP_DIR/show-live.out"
assert_contains "Runtime health: live" "$TMP_DIR/show-live.out"
assert_contains "Provider: codex" "$TMP_DIR/show-live.out"

run_sessions "$REPO_A" "$TMP_DIR/show-ambiguous.out" show ticket:101
assert_eq "2" "$COMMAND_RESULT" "ambiguous selector result"
assert_contains "matches 2 sessions" "$TMP_DIR/show-ambiguous.out"
run_sessions "$REPO_A" "$TMP_DIR/show-absent.out" show ticket:999
assert_eq "1" "$COMMAND_RESULT" "missing selector result"
assert_contains "No session matches 'ticket:999'" "$TMP_DIR/show-absent.out"
run_sessions "$REPO_A" "$TMP_DIR/show-invalid.out" show 'session:../bad'
assert_eq "3" "$COMMAND_RESULT" "invalid selector result"
assert_contains "session selector is invalid" "$TMP_DIR/show-invalid.out"

run_sessions "$REPO_A" "$TMP_DIR/show-child-hidden.out" show "session:$CHILD_SID"
assert_eq "1" "$COMMAND_RESULT" "hidden child selector result"
run_sessions "$REPO_A" "$TMP_DIR/show-child.out" show \
  "session:$CHILD_SID" --include-children
assert_eq "0" "$COMMAND_RESULT" "explicit child selector result"
assert_contains "Parent session: $SID_LIVE" "$TMP_DIR/show-child.out"

run_sessions "$REPO_A" "$TMP_DIR/doctor-live.out" doctor "session:$SID_LIVE"
assert_eq "0" "$COMMAND_RESULT" "live doctor result"
assert_contains "Session structure is healthy" "$TMP_DIR/doctor-live.out"
run_sessions "$REPO_A" "$TMP_DIR/doctor-dead.out" doctor "session:$SID_DEAD"
assert_eq "1" "$COMMAND_RESULT" "dead doctor result"
assert_contains "runtime owner stopped while the lease was running" "$TMP_DIR/doctor-dead.out"
run_sessions "$REPO_A" "$TMP_DIR/doctor-unverifiable.out" doctor \
  "session:$SID_UNVERIFIABLE"
assert_eq "1" "$COMMAND_RESULT" "unverifiable doctor result"
assert_contains "runtime owner cannot be verified" "$TMP_DIR/doctor-unverifiable.out"
run_sessions "$REPO_A" "$TMP_DIR/doctor-corrupt.out" doctor "session:$SID_CORRUPT"
assert_eq "1" "$COMMAND_RESULT" "corrupt doctor result"
assert_contains "runtime record is corrupt" "$TMP_DIR/doctor-corrupt.out"
run_sessions "$REPO_A" "$TMP_DIR/doctor-unsafe.out" doctor "session:$SID_UNSAFE"
assert_eq "1" "$COMMAND_RESULT" "unsafe artifact doctor result"
assert_contains "unsafe lifecycle artifacts" "$TMP_DIR/doctor-unsafe.out"
run_sessions "$REPO_A" "$TMP_DIR/doctor-provider-corrupt.out" doctor \
  "session:$SID_PROVIDER_CORRUPT"
assert_eq "1" "$COMMAND_RESULT" "corrupt provider doctor result"
assert_contains "provider state is corrupt" "$TMP_DIR/doctor-provider-corrupt.out"
run_sessions "$REPO_A" "$TMP_DIR/doctor-provider-duplicate.out" doctor \
  "session:$SID_PROVIDER_DUPLICATE"
assert_eq "1" "$COMMAND_RESULT" "duplicate provider doctor result"
assert_contains "provider state is corrupt" "$TMP_DIR/doctor-provider-duplicate.out"
run_sessions "$REPO_A" "$TMP_DIR/doctor-provider-mismatch.out" doctor \
  "session:$SID_PROVIDER_MISMATCH"
assert_eq "1" "$COMMAND_RESULT" "provider mismatch doctor result"
assert_contains "runtime and provider state disagree" \
  "$TMP_DIR/doctor-provider-mismatch.out"
run_sessions "$REPO_A" "$TMP_DIR/doctor-legacy.out" doctor "session:$SID_LEGACY"
assert_eq "1" "$COMMAND_RESULT" "legacy doctor result"
assert_contains "has no verifiable runtime lease" "$TMP_DIR/doctor-legacy.out"
assert_not_contains "stale" "$TMP_DIR/doctor-legacy.out"

run_sessions "$REPO_A" "$TMP_DIR/doctor-all.out" doctor
assert_eq "1" "$COMMAND_RESULT" "repository doctor result"
assert_contains "Session diagnostics found" "$TMP_DIR/doctor-all.out"
assert_contains "$SID_LIVE" "$TMP_DIR/doctor-all.out"
assert_contains "$SID_DEAD" "$TMP_DIR/doctor-all.out"
assert_not_contains "$CHILD_SID" "$TMP_DIR/doctor-all.out"

cat "$TMP_DIR"/*.out > "$TMP_DIR/all-command-output"
assert_not_contains "$LIVE_TOKEN" "$TMP_DIR/all-command-output"
assert_not_contains "$DEAD_TOKEN" "$TMP_DIR/all-command-output"
assert_not_contains "$UNVERIFIABLE_TOKEN" "$TMP_DIR/all-command-output"
assert_not_contains "$PROVIDER_CORRUPT_TOKEN" "$TMP_DIR/all-command-output"
assert_not_contains "$PROVIDER_DUPLICATE_TOKEN" "$TMP_DIR/all-command-output"
assert_not_contains "$PROVIDER_MISMATCH_TOKEN" "$TMP_DIR/all-command-output"
assert_not_contains "$CORRUPT_SECRET" "$TMP_DIR/all-command-output"

state_snapshot > "$TMP_DIR/state-before"
run_sessions "$REPO_A" "$TMP_DIR/read-only-list.out" list --include-children
assert_eq "0" "$COMMAND_RESULT" "read-only list result"
run_sessions "$REPO_A" "$TMP_DIR/read-only-show.out" show "$SID_LIVE"
assert_eq "0" "$COMMAND_RESULT" "read-only show result"
state_snapshot > "$TMP_DIR/state-after"
if ! cmp -s "$TMP_DIR/state-before" "$TMP_DIR/state-after"; then
  fail "dx sessions changed lifecycle state"
fi

printf 'session command tests passed\n'
