#!/usr/bin/env bash
set -euo pipefail

# The two commands that see the whole host rather than one checkout:
# `dxclean` / `dxclean --apply`, and `dx doctor`.
#
# The interesting property of both is restraint. `dxclean` without a flag must
# name every leftover and remove none of them, `dxclean --apply` must remove
# exactly the list it just printed and nothing beside it — not a live
# session's temp root, not the gate receipts of a session that still exists —
# and `dx doctor` must answer the whole question without writing anything at
# all. So the fixtures here include the things that must survive, and the
# assertions are a before/after diff of the state directory rather than a
# check that the named paths are gone.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
# Physical path: the browser-profile fixture is compared as a string against
# what dxclean prints, and a symlinked /var would make those two spellings of
# the same directory disagree.
TMP_DIR="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/dex-host-cleanup.XXXXXX")" && pwd -P)"

cleanup() {
  local stray
  if [[ -d "$TMP_DIR" ]]; then
    while IFS= read -r stray; do
      [[ "$stray" =~ ^[0-9]+$ ]] || continue
      kill -KILL "$stray" 2>/dev/null || true
    done < <(find "$TMP_DIR" -type f -name '*.pid' -exec cat {} \; 2>/dev/null || true)
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
export DX_TOOL_DIR="$TMP_DIR/tools"
export DX_RUN_ROOT="$TMP_DIR/runs"
export DEXCODE_SYNC=0
export GIT_AUTHOR_NAME=dex GIT_AUTHOR_EMAIL=dex@example.test
export GIT_COMMITTER_NAME=dex GIT_COMMITTER_EMAIL=dex@example.test
# bin/doctor.sh prefers CLAUDE_CONFIG_DIR over $HOME/.claude, so a machine
# that exports it would point the Claude-record count at the real one.
unset CLAUDE_CONFIG_DIR
mkdir -p "$HOME/.claude/sessions" "$DX_STATE_DIR" "$DX_LOOP_DIR" "$DX_RUN_ROOT"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

wait_for_file() {
  local file="$1" label="$2" attempt=0
  while [[ ! -s "$file" && $attempt -lt 200 ]]; do
    /bin/sleep 0.05
    attempt=$((attempt + 1))
  done
  [[ -s "$file" ]] || fail "$label: $file was never written"
}

assert_gone() {
  local pid="$1" label="$2" attempt=0
  while kill -0 "$pid" 2>/dev/null && [[ $attempt -lt 200 ]]; do
    /bin/sleep 0.05
    attempt=$((attempt + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    fail "$label: process $pid was not stopped"
  fi
}

# tree_listing <file> <dir...> — every path under those directories, with a
# checksum for each file, so "nothing changed" can be asserted as one diff.
tree_listing() {
  local out="$1" entry
  shift
  : > "$out"
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    if [[ -f "$entry" ]]; then
      printf '%s\t%s\n' "$entry" "$(cksum < "$entry" 2>/dev/null || printf 'unreadable')" >> "$out"
    else
      printf '%s\tdir\n' "$entry" >> "$out"
    fi
  done < <(find "$@" 2>/dev/null | LC_ALL=C sort)
}

run_zsh() {
  local out="$1"
  shift
  set +e
  zsh -fc "
    source \"\$DEX_DIR/dx.sh\"
    cd \"\$FIXTURE_REPO\"
    $*
  " > "$out" 2>&1
  DX_ZSH_STATUS=$?
  set -e
}

run_doctor() {
  local out="$1"
  shift
  set +e
  bash "$ROOT/bin/doctor.sh" "$@" > "$out" 2> "$out.err"
  DX_DOCTOR_STATUS=$?
  set -e
}

# ─── The project ────────────────────────────────────────────────────────────
# A repository that declares what a worktree of it costs beyond disk: a probe
# that reports two leftover resources, and the teardown Dex is expected to run
# for each of them.
export FIXTURE_REPO="$TMP_DIR/app"
export MARKER_FILE="$TMP_DIR/before-remove.log"
: > "$MARKER_FILE"
mkdir -p "$FIXTURE_REPO/.dex/worktrees"
git -C "$FIXTURE_REPO" init -q -b main
git -C "$FIXTURE_REPO" config user.email dex@example.test
git -C "$FIXTURE_REPO" config user.name "Dex Test"
printf 'base\n' > "$FIXTURE_REPO/file.txt"
git -C "$FIXTURE_REPO" add file.txt
git -C "$FIXTURE_REPO" commit -q -m "test: initialize repo"
# A live worktree, and a probe that reports it three ways — as a bare name, as
# an absolute path, and in a different case. A probe of the ordinary shape
# lists every resource it can see, including the one belonging to the worktree
# someone is working in, so this is the shape that makes "--apply drops a
# running session's database" possible if Dex does not check.
LIVE_WORKTREE_NAME="ticket-142"
LIVE_WORKTREE_DIR="$FIXTURE_REPO/.dex/worktrees/$LIVE_WORKTREE_NAME"
git -C "$FIXTURE_REPO" worktree add -q --detach "$LIVE_WORKTREE_DIR" main
# Uncommitted work, so dxclean's own stale-worktree pass skips it: this is a
# worktree somebody is in the middle of, which is exactly the one whose
# database must not be dropped.
printf 'work in progress\n' > "$LIVE_WORKTREE_DIR/wip.txt"
cat > "$FIXTURE_REPO/.dex/dex.md" <<'DEXMD'
# Dex — fixture

## Worktree Hooks

```yaml
before_remove: printf "%s\n" "torn down $DX_WORKTREE_NAME" >> "$MARKER_FILE"
orphan_resources: printf "%s\n" app_dev_task_spike app_dev_task_probe ticket-142 $DX_REPO_ROOT/.dex/worktrees/ticket-142 TICKET-142
```
DEXMD

# ─── Fixture 1: a session that is gone ──────────────────────────────────────
# Its holder PID is not among the processes carrying its token, which is what
# `dx ps` calls gone. Nothing reaps a session removed by `dx sessions forget`
# or `dx_cleanup_session`, so this is the shape those leave behind.
GONE_SESSION="host-cleanup-gone"
GONE_DIR="$(dx_session_process_dir "$GONE_SESSION")"
GONE_TMP="$(dx_session_tmp_dir "$GONE_SESSION")"
GONE_PROFILE="$GONE_TMP/browser-playwright"
mkdir -p "$GONE_PROFILE"
printf 'dxs-1-host-cleanup-fixture-token\n' > "$(dx_session_process_token_file "$GONE_SESSION")"
# A PID that has already exited: started and reaped here, so it is a real PID
# this host once used rather than a number guessed to be free.
/bin/sleep 0 &
DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null || true
printf '%s\n' "$DEAD_PID" > "$(dx_session_process_holder_file "$GONE_SESSION")"

# ─── Fixture 2: the browser profile that session minted ─────────────────────
printf '%s\n' "$GONE_PROFILE" > "$GONE_TMP/browser-profiles.txt"

# ─── Fixture 3: gate receipts, one stale and one that must survive ──────────
STALE_RECEIPTS_SESSION="host-cleanup-forgotten"
STALE_RECEIPTS_DIR="$(dx_gate_receipt_dir "$STALE_RECEIPTS_SESSION")"
mkdir -p "$STALE_RECEIPTS_DIR"
printf '{"gate":"bin-verify","exit_code":0}\n' > "$STALE_RECEIPTS_DIR/bin-verify.json"

KEPT_RECEIPTS_SESSION="host-cleanup-remembered"
KEPT_RECEIPTS_DIR="$(dx_gate_receipt_dir "$KEPT_RECEIPTS_SESSION")"
mkdir -p "$KEPT_RECEIPTS_DIR"
printf '{"gate":"bin-verify","exit_code":0}\n' > "$KEPT_RECEIPTS_DIR/bin-verify.json"
# The trace that makes it a session Dex still remembers.
printf '3\n' > "$(dx_state_file "$KEPT_RECEIPTS_SESSION")"

# ─── Fixture 4: sessions with real token-carrying processes ─────────────────
# The provider attaches the session token on fd 8 and leaves a detached child
# carrying it, which is what makes a reap something other than a no-op.
PROVIDER="$TMP_DIR/provider.sh"
cat > "$PROVIDER" <<'PROVIDER'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$DEX_DIR/lib/common.sh"
provider_session="$1"
report_dir="$2"
report_prefix="$3"
(
  dx_session_process_token_attach "$provider_session"
  nohup /bin/sleep 300 > /dev/null 2>&1 &
  printf '%s\n' "$!" > "$report_dir/$report_prefix-detached.pid"
  disown 2>/dev/null || true
  /bin/sleep 300
) &
printf '%s\n' "$!" > "$report_dir/$report_prefix-holder.pid"
PROVIDER
chmod +x "$PROVIDER"

# 4a. A live session, which nothing here may touch — including the browser
# profile it minted, which is the negative for the profile category.
LIVE_SESSION="host-cleanup-live"
bash "$PROVIDER" "$LIVE_SESSION" "$TMP_DIR" live
wait_for_file "$TMP_DIR/live-holder.pid" "fake provider"
wait_for_file "$TMP_DIR/live-detached.pid" "fake provider child"
LIVE_HOLDER_PID="$(cat "$TMP_DIR/live-holder.pid")"
LIVE_DETACHED_PID="$(cat "$TMP_DIR/live-detached.pid")"
LIVE_DIR="$(dx_session_process_dir "$LIVE_SESSION")"
wait_for_file "$LIVE_DIR/token" "live session token"
LIVE_PROFILE="$(dx_session_tmp_dir "$LIVE_SESSION")/browser-playwright"
mkdir -p "$LIVE_PROFILE"
printf '%s\n' "$LIVE_PROFILE" > "$(dx_session_tmp_dir "$LIVE_SESSION")/browser-profiles.txt"

# 4b. A session that died with a child still carrying its token: the case the
# whole process category exists for. Killing the holder is what a crashed or
# killed session looks like — the token file is still there, but nothing
# carrying it is the session any more.
REAP_SESSION="host-cleanup-reap"
bash "$PROVIDER" "$REAP_SESSION" "$TMP_DIR" reap
wait_for_file "$TMP_DIR/reap-holder.pid" "reapable provider"
wait_for_file "$TMP_DIR/reap-detached.pid" "reapable provider child"
REAP_HOLDER_PID="$(cat "$TMP_DIR/reap-holder.pid")"
REAP_DETACHED_PID="$(cat "$TMP_DIR/reap-detached.pid")"
REAP_DIR="$(dx_session_process_dir "$REAP_SESSION")"
wait_for_file "$REAP_DIR/token" "reapable session token"
kill -KILL "$REAP_HOLDER_PID" 2>/dev/null || true
REAP_WAIT=0
while kill -0 "$REAP_HOLDER_PID" 2>/dev/null && [[ $REAP_WAIT -lt 200 ]]; do
  /bin/sleep 0.05
  REAP_WAIT=$((REAP_WAIT + 1))
done
if kill -0 "$REAP_HOLDER_PID" 2>/dev/null; then
  fail "the reapable session's holder would not die"
fi
kill -0 "$REAP_DETACHED_PID" 2>/dev/null || fail "the reapable session's child exited before the test could use it"

# ─── Fixture 5: Claude Code's own session records ───────────────────────────
# One record for a process that is running and one for a record that names no
# process at all — the shape a crashed write leaves. A recycled PID would make
# a "dead PID" fixture flake on a host that forks as much as this one.
printf '{"pid":%s,"name":"live"}\n' "$LIVE_HOLDER_PID" > "$HOME/.claude/sessions/$LIVE_HOLDER_PID.json"
printf '{"pid":0,"name":"stale"}\n' > "$HOME/.claude/sessions/0.json"

# ─── dx doctor: reports everything, changes nothing ─────────────────────────
run_doctor "$TMP_DIR/doctor-help.out" --help
assert_eq "0" "$DX_DOCTOR_STATUS" "dx doctor --help status"
assert_contains "Usage: dx doctor" "$TMP_DIR/doctor-help.out"

run_doctor "$TMP_DIR/doctor-unknown.out" --not-an-option
[[ "$DX_DOCTOR_STATUS" -ne 0 ]] || assert_at $LINENO
assert_contains "Unknown doctor option: --not-an-option" "$TMP_DIR/doctor-unknown.out.err"
# A rejected invocation says so on stderr and prints no report on stdout.
[[ ! -s "$TMP_DIR/doctor-unknown.out" ]] || assert_at $LINENO

tree_listing "$TMP_DIR/before-doctor.tree" "$DX_LOOP_DIR" "$DX_STATE_DIR" "$HOME"
DOCTOR_START=$(date +%s)
run_doctor "$TMP_DIR/doctor.out"
DOCTOR_ELAPSED=$(( $(date +%s) - DOCTOR_START ))
assert_eq "0" "$DX_DOCTOR_STATUS" "dx doctor status"
tree_listing "$TMP_DIR/after-doctor.tree" "$DX_LOOP_DIR" "$DX_STATE_DIR" "$HOME"
if ! diff "$TMP_DIR/before-doctor.tree" "$TMP_DIR/after-doctor.tree" > "$TMP_DIR/doctor.diff"; then
  cat "$TMP_DIR/doctor.diff" >&2
  fail "dx doctor modified state while reporting on it"
fi

# Every section a human is promised, in one screen.
assert_contains "Dex — doctor" "$TMP_DIR/doctor.out"
assert_contains "Sessions:" "$TMP_DIR/doctor.out"
assert_contains "Pools:" "$TMP_DIR/doctor.out"
assert_contains "Orphans:" "$TMP_DIR/doctor.out"
assert_contains "Host:" "$TMP_DIR/doctor.out"
assert_contains "Trees:" "$TMP_DIR/doctor.out"
assert_contains "$LIVE_SESSION" "$TMP_DIR/doctor.out"
assert_contains "session(s) whose process token is dead" "$TMP_DIR/doctor.out"
assert_contains "heavy" "$TMP_DIR/doctor.out"
assert_contains "waves" "$TMP_DIR/doctor.out"
assert_contains "checks" "$TMP_DIR/doctor.out"
assert_contains "test job(s) per session" "$TMP_DIR/doctor.out"
# Claude Code's own records are counted when the directory is there.
assert_contains "1 of 2 Claude Code session record(s) still running" "$TMP_DIR/doctor.out"
# Ten lines or so, not a listing.
DOCTOR_LINES=$(wc -l < "$TMP_DIR/doctor.out" | tr -d '[:space:]')
[[ "$DOCTOR_LINES" -le 20 ]] || fail "dx doctor printed $DOCTOR_LINES lines"
# Not a wall-clock assertion about the two-second budget — a shared CI box can
# be arbitrarily slow — only that it is a summary and not a scan of the host.
[[ "$DOCTOR_ELAPSED" -lt 30 ]] || fail "dx doctor took ${DOCTOR_ELAPSED}s"

# ─── dxclean argument handling ──────────────────────────────────────────────
if ! command -v zsh > /dev/null 2>&1; then
  printf 'skip: zsh is not installed, so dxclean is not exercised\n'
  printf 'host cleanup tests passed\n'
  exit 0
fi

run_zsh "$TMP_DIR/clean-help.out" 'dxclean --help'
assert_eq "0" "$DX_ZSH_STATUS" "dxclean --help status"
assert_contains "Usage: dxclean [--apply]" "$TMP_DIR/clean-help.out"
assert_contains "--apply" "$TMP_DIR/clean-help.out"

run_zsh "$TMP_DIR/clean-unknown.out" 'dxclean --not-an-option'
[[ "$DX_ZSH_STATUS" -ne 0 ]] || assert_at $LINENO
assert_contains "Unknown dxclean option: --not-an-option" "$TMP_DIR/clean-unknown.out"

# ─── dxclean: names every leftover, removes none of them ────────────────────
tree_listing "$TMP_DIR/before-report.tree" "$DX_LOOP_DIR" "$DX_STATE_DIR"
run_zsh "$TMP_DIR/clean-report.out" 'dxclean'
assert_eq "0" "$DX_ZSH_STATUS" "dxclean status"
assert_contains "Host leftovers:" "$TMP_DIR/clean-report.out"
assert_contains "session temp root  $GONE_SESSION" "$TMP_DIR/clean-report.out"
assert_contains "browser profile    $GONE_PROFILE" "$TMP_DIR/clean-report.out"
assert_contains "gate receipts      $STALE_RECEIPTS_SESSION" "$TMP_DIR/clean-report.out"
assert_contains "project resource   app_dev_task_spike" "$TMP_DIR/clean-report.out"
assert_contains "project resource   app_dev_task_probe" "$TMP_DIR/clean-report.out"
assert_contains "session temp root  $REAP_SESSION" "$TMP_DIR/clean-report.out"
# The orphaned processes come from `dx ps`, so its listing is what a human
# reads before deciding to act, and it names the process that is about to be
# stopped.
assert_contains "orphan processes ('dx ps' also lists the live sessions it leaves alone):" "$TMP_DIR/clean-report.out"
assert_contains "Dex — session processes" "$TMP_DIR/clean-report.out"
assert_contains "$REAP_DETACHED_PID" "$TMP_DIR/clean-report.out"
assert_contains "Re-run as 'dxclean --apply'" "$TMP_DIR/clean-report.out"
# A session Dex still remembers keeps its receipts, however old they are.
assert_not_contains "gate receipts      $KEPT_RECEIPTS_SESSION" "$TMP_DIR/clean-report.out"
# A live session's browser profile is not a leftover.
assert_not_contains "browser profile    $LIVE_PROFILE" "$TMP_DIR/clean-report.out"

# A live worktree is never an orphan, however the probe spells it: bare name,
# absolute path, or a different case. Each is named and each is held back.
assert_contains "live worktree      $LIVE_WORKTREE_NAME  reported, but Dex still has this worktree — not touched" "$TMP_DIR/clean-report.out"
assert_contains "live worktree      $LIVE_WORKTREE_DIR  reported, but Dex still has this worktree — not touched" "$TMP_DIR/clean-report.out"
assert_contains "live worktree      TICKET-142  reported, but Dex still has this worktree — not touched" "$TMP_DIR/clean-report.out"
assert_not_contains "project resource   $LIVE_WORKTREE_NAME" "$TMP_DIR/clean-report.out"
assert_not_contains "project resource   $LIVE_WORKTREE_DIR" "$TMP_DIR/clean-report.out"
assert_not_contains "project resource   TICKET-142" "$TMP_DIR/clean-report.out"

tree_listing "$TMP_DIR/after-report.tree" "$DX_LOOP_DIR" "$DX_STATE_DIR"
if ! diff "$TMP_DIR/before-report.tree" "$TMP_DIR/after-report.tree" > "$TMP_DIR/report.diff"; then
  cat "$TMP_DIR/report.diff" >&2
  fail "dxclean removed something without --apply"
fi
assert_eq "0" "$(wc -l < "$MARKER_FILE" | tr -d '[:space:]')" "before_remove runs in the report"
kill -0 "$LIVE_HOLDER_PID" 2>/dev/null || fail "the dxclean report stopped a live session"

# ─── dxclean --apply: removes exactly that list ─────────────────────────────
run_zsh "$TMP_DIR/clean-apply.out" 'dxclean --apply'
assert_eq "0" "$DX_ZSH_STATUS" "dxclean --apply status"
assert_contains "Removing browser profile: $GONE_PROFILE" "$TMP_DIR/clean-apply.out"
assert_contains "Stopping orphaned processes and removing their session temp roots" "$TMP_DIR/clean-apply.out"
assert_contains "Removing gate receipts of a session that no longer exists: $STALE_RECEIPTS_SESSION" "$TMP_DIR/clean-apply.out"
assert_contains "Tearing down the resource this project reported: app_dev_task_spike" "$TMP_DIR/clean-apply.out"
assert_contains "Tearing down the resource this project reported: app_dev_task_probe" "$TMP_DIR/clean-apply.out"
# The process category actually stops a process, and the count printed is the
# one dx ps reported doing — not the one the report predicted.
assert_contains "reaped pid=$REAP_DETACHED_PID" "$TMP_DIR/clean-apply.out"
assert_contains "Stopped 1 process(es); removed 2 of 2 reported session temp root(s)." "$TMP_DIR/clean-apply.out"
assert_gone "$REAP_DETACHED_PID" "the orphaned session's child"

assert_no_file "$GONE_DIR"
assert_no_file "$REAP_DIR"
assert_no_file "$STALE_RECEIPTS_DIR"
assert_dir "$KEPT_RECEIPTS_DIR"
assert_dir "$LIVE_DIR"
assert_dir "$LIVE_PROFILE"
assert_dir "$LIVE_WORKTREE_DIR"
kill -0 "$LIVE_HOLDER_PID" 2>/dev/null || fail "dxclean --apply stopped a live session"
kill -0 "$LIVE_DETACHED_PID" 2>/dev/null || fail "dxclean --apply stopped a live session's child"
# The project's own teardown ran once per reported resource, with the line
# the probe printed — and never for the live worktree, in any spelling.
assert_contains "torn down app_dev_task_spike" "$MARKER_FILE"
assert_contains "torn down app_dev_task_probe" "$MARKER_FILE"
assert_not_contains "torn down $LIVE_WORKTREE_NAME" "$MARKER_FILE"
assert_not_contains "torn down $LIVE_WORKTREE_DIR" "$MARKER_FILE"
assert_not_contains "torn down TICKET-142" "$MARKER_FILE"
assert_eq "2" "$(wc -l < "$MARKER_FILE" | tr -d '[:space:]')" "before_remove invocations"

# Nothing beyond the three directories it named was removed.
tree_listing "$TMP_DIR/after-apply.tree" "$DX_LOOP_DIR" "$DX_STATE_DIR"
cut -f1 "$TMP_DIR/after-report.tree" | LC_ALL=C sort > "$TMP_DIR/before.paths"
cut -f1 "$TMP_DIR/after-apply.tree" | LC_ALL=C sort > "$TMP_DIR/after.paths"
comm -23 "$TMP_DIR/before.paths" "$TMP_DIR/after.paths" > "$TMP_DIR/removed.paths"
grep -v -e "^${GONE_DIR}\$" -e "^${GONE_DIR}/" \
  -e "^${REAP_DIR}\$" -e "^${REAP_DIR}/" \
  -e "^${STALE_RECEIPTS_DIR}\$" -e "^${STALE_RECEIPTS_DIR}/" \
  "$TMP_DIR/removed.paths" > "$TMP_DIR/unexpected.paths" || true
if [[ -s "$TMP_DIR/unexpected.paths" ]]; then
  cat "$TMP_DIR/unexpected.paths" >&2
  fail "dxclean --apply removed more than it reported"
fi
[[ -s "$TMP_DIR/removed.paths" ]] || fail "dxclean --apply removed nothing"

# ─── A second run has nothing left to say ───────────────────────────────────
run_zsh "$TMP_DIR/clean-again.out" 'dxclean'
assert_eq "0" "$DX_ZSH_STATUS" "second dxclean status"
assert_not_contains "session temp root  $GONE_SESSION" "$TMP_DIR/clean-again.out"
assert_not_contains "session temp root  $REAP_SESSION" "$TMP_DIR/clean-again.out"
assert_not_contains "gate receipts      $STALE_RECEIPTS_SESSION" "$TMP_DIR/clean-again.out"

# ─── A probe that crashed is not a clean repository ─────────────────────────
# lib/worktree.sh returns 2 for a probe that failed or was stopped, which is a
# different fact from "declares no probe" and from "reported nothing". Only
# one of the three is reassuring.
BROKEN_REPO="$TMP_DIR/broken"
mkdir -p "$BROKEN_REPO/.dex/worktrees"
git -C "$BROKEN_REPO" init -q -b main
git -C "$BROKEN_REPO" config user.email dex@example.test
git -C "$BROKEN_REPO" config user.name "Dex Test"
printf 'base\n' > "$BROKEN_REPO/file.txt"
git -C "$BROKEN_REPO" add file.txt
git -C "$BROKEN_REPO" commit -q -m "test: initialize repo"
cat > "$BROKEN_REPO/.dex/dex.md" <<'DEXMD'
# Dex — fixture

## Worktree Hooks

```yaml
orphan_resources: exit 9
```
DEXMD
export BROKEN_REPO
set +e
zsh -fc '
  source "$DEX_DIR/dx.sh"
  cd "$BROKEN_REPO"
  dxclean
' > "$TMP_DIR/clean-broken.out" 2>&1
set -e
assert_contains "the orphan_resources probe failed; Dex cannot tell whether this project is clean" \
  "$TMP_DIR/clean-broken.out"
assert_not_contains "Nothing to clean." "$TMP_DIR/clean-broken.out"

printf 'host cleanup tests passed\n'
