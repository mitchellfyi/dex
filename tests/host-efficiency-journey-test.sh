#!/usr/bin/env bash
# One fake project, one session, every host-efficiency surface in sequence:
# the `## Resources` reader, `dx run-gate` admission and its receipts, the
# advisory guard, session ownership through `dx ps`, the worktree hooks and
# audit, the review-tier floor, `dx review stats`, `dx doctor` and `dxclean`.
# The unit tests pin each of these alone; this is the journey an agent's
# session actually takes through them, in one hermetic HOME, so a change that
# keeps every unit green but breaks the hand-off between two of them fails here.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
# Physical path with single separators: hooks report $PWD, git reports
# resolved toplevels, and the runner nests a TMPDIR under a TMPDIR.
TMP_DIR="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/dex-journey.XXXXXX")" && pwd -P)"
export HOME="$TMP_DIR/home" DEX_DIR="$ROOT" DX_STATE_DIR="$TMP_DIR/state" \
  DX_LOOP_DIR="$TMP_DIR/loops" DX_REVIEW_CAPACITY_DIR="$TMP_DIR/capacity" \
  DX_ARTIFACT_DIR="$TMP_DIR/artifacts" DX_TOOL_DIR="$TMP_DIR/tools" DX_RUN_ROOT="$TMP_DIR/runs"
# One heavy slot, so the second gate has to queue; a heartbeat every second so
# the queue is visible inside the test.
export DEX_MAX_ACTIVE_HEAVY=1 DEX_GATE_HEARTBEAT_SECONDS=1
export GIT_AUTHOR_NAME=dex GIT_AUTHOR_EMAIL=dex@example.test \
  GIT_COMMITTER_NAME=dex GIT_COMMITTER_EMAIL=dex@example.test
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR" "$DX_RUN_ROOT"
ok() { printf 'ok   %s\n' "$1"; }
# expect <label> <status> [detail]: the status of the condition just evaluated,
# captured into a variable first so it cannot be overwritten on the way here.
expect() { if [[ "$2" -eq 0 ]]; then ok "$1"; else fail "$1: ${3:-}"; fi; }
has() { printf '%s' "$1" | grep -q -i -E -- "$2"; }
cleanup() {
  local f
  for f in "$TMP_DIR"/*.pid; do
    [[ -f "$f" ]] && kill -KILL "$(cat "$f")" 2>/dev/null
  done
  pkill -f "$TMP_DIR" 2>/dev/null
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT
# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

# ── the fake project ─────────────────────────────────────────────────────────
REPO="$TMP_DIR/repo"
mkdir -p "$REPO/.dex" "$REPO/bin"
git init -q "$REPO"
printf 'project\n' > "$REPO/README.md"
# The gate reports the parallelism variable the contract names and exits with
# PROBE_EXIT, a name run-gate itself does not use (its own GATE_* variables
# would shadow one of those).
cat > "$REPO/bin/gate" <<'SH'
#!/bin/sh
printf 'workers=%s\n' "${MY_WORKERS:-unset}"
sleep "${PROBE_SLEEP:-0}"
exit "${PROBE_EXIT:-0}"
SH
cat > "$REPO/bin/hooks" <<'SH'
#!/bin/sh
printf '%s name=%s ticket=%s repo=%s path=%s cwd=%s\n' "$1" "$DX_WORKTREE_NAME" "$DX_TICKET" "$DX_REPO_ROOT" "$DX_WORKTREE_PATH" "$PWD" >> "$MARKER_FILE"
SH
chmod +x "$REPO/bin/gate" "$REPO/bin/hooks"
cat > "$REPO/.dex/dex.md" <<'CONTRACT'
# Fake project
## Quality Gates
| Check | Command | Scope |
|-------|---------|-------|
| Gate | `bin/gate` | everything |
## Resources
```yaml
parallelism_env: [MY_WORKERS]
heavy_commands:
  - bin/gate
targeted_tests: "bin/gate {files}"
full_gate: local
review_sensitive_paths: ["billing/**"]
```
## Worktree Hooks
```yaml
after_create: bin/hooks create
before_remove: bin/hooks remove
orphan_resources: printf "%s\n" ticket-1 ticket-9
```
## Project Structure
Flat.
CONTRACT
git -C "$REPO" add -A
git -C "$REPO" -c commit.gpgsign=false commit -q -m init
git -C "$REPO" update-ref refs/remotes/origin/main HEAD
export MARKER_FILE="$TMP_DIR/markers.log"
: > "$MARKER_FILE"

SID=$(dx_session_id)
export DEX_SESSION_ID="$SID"
dx_session_id_valid "$SID"; cond=$?; expect "session id minted and valid" "$cond" "$SID"

# ── 1. the contract reader ───────────────────────────────────────────────────
out=$(cd "$REPO" && python3 "$ROOT/scripts/project-contract.py" .dex/dex.md Resources heavy_commands 2>&1)
[[ "$out" == "bin/gate" ]] || fail "project-contract.py reads heavy_commands: $out"
ok "project-contract.py reads heavy_commands"

# ── 2. run-gate: admission, the parallelism budget, the receipt ─────────────
out=$(cd "$REPO" && bash "$ROOT/bin/run-gate.sh" --name gate -- bin/gate 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && has "$out" 'workers=[0-9]+'
cond=$?; expect "run-gate runs the gate with parallelism_env set (rc=$rc)" "$cond" "$out"
(cd "$REPO" && bash "$ROOT/bin/gate-receipt.sh" gate >/dev/null 2>&1)
cond=$?; expect "gate-receipt reuses the passing receipt for this tree" "$cond"

# ── 3. the receipt follows the tree ─────────────────────────────────────────
printf 'more\n' >> "$REPO/README.md"
(cd "$REPO" && bash "$ROOT/bin/gate-receipt.sh" gate >/dev/null 2>&1); rc=$?
[[ "$rc" -ne 0 ]] || fail "a changed tree invalidates the receipt: rc=$rc"
ok "a changed tree invalidates the receipt (rc=$rc)"
(cd "$REPO" && bash "$ROOT/bin/run-gate.sh" --name gate -- bin/gate >/dev/null 2>&1)
(cd "$REPO" && bash "$ROOT/bin/gate-receipt.sh" gate >/dev/null 2>&1)
cond=$?; expect "re-running the gate restores reuse" "$cond"

# ── 4. a failing gate ────────────────────────────────────────────────────────
out=$(cd "$REPO" && PROBE_EXIT=3 bash "$ROOT/bin/run-gate.sh" --name gate-fail -- bin/gate 2>&1); rc=$?
[[ "$rc" -eq 3 ]] || fail "run-gate passes the command's exit code through: rc=$rc $out"
ok "run-gate passes the command's exit code through (rc=$rc)"
(cd "$REPO" && bash "$ROOT/bin/gate-receipt.sh" gate-fail >/dev/null 2>&1); rc=$?
[[ "$rc" -ne 0 ]] || fail "a recorded failure is not reused: rc=$rc"
ok "a recorded failure is not reused (rc=$rc)"

# ── 5. two gates, one slot ───────────────────────────────────────────────────
(cd "$REPO" && PROBE_SLEEP=4 bash "$ROOT/bin/run-gate.sh" --name slow -- bin/gate > "$TMP_DIR/slow.out" 2>&1) &
slow_pid=$!
printf '%s\n' "$slow_pid" > "$TMP_DIR/slow.pid"
/bin/sleep 1
out=$(cd "$REPO" && bash "$ROOT/bin/run-gate.sh" --name quick -- bin/gate 2>&1); rc=$?
wait "$slow_pid"; slow_rc=$?
rm -f "$TMP_DIR/slow.pid"
[[ "$rc" -eq 0 && "$slow_rc" -eq 0 ]] && has "$out" 'queue|wait'
cond=$?; expect "the second gate queues behind the first and both pass (rc=$rc slow=$slow_rc)" "$cond" "$out"

# ── 6. the advisory guard reads the same contract ───────────────────────────
payload() { python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$1"; }
guard() { (cd "$REPO" && printf '%s' "$(payload "$1")" | DEX_GUARD_EVENT=bash python3 "$ROOT/hooks/guard-handler.py" 2>&1); }
out=$(guard 'bin/gate'); has "$out" 'dx run-gate'
cond=$?; expect "a declared heavy command gets the run-gate nudge" "$cond" "$out"
out=$(guard 'dx run-gate -- bin/gate'); ! has "$out" 'declared heavy'
cond=$?; expect "the same command under run-gate is not nudged" "$cond" "$out"
out=$(guard 'nohup sleep 5 &'); has "$out" 'outlives|detached|orphan'
cond=$?; expect "a detached launch gets the ownership warning" "$cond" "$out"
out=$(guard 'ls -la'); [[ -z "$out" ]] || fail "an ordinary command is silent: $out"
ok "an ordinary command is silent"

# ── 7. ownership: dx ps sees a detached process, then its orphan, then reaps ─
cat > "$TMP_DIR/holder.sh" <<'SH'
#!/usr/bin/env bash
# shellcheck disable=SC1091
source "$DEX_DIR/lib/common.sh"
(
  dx_session_process_token_attach "$1"
  nohup /bin/sleep 300 > /dev/null 2>&1 &
  printf '%s\n' "$!" > "$2/detached.pid"
  disown 2>/dev/null || true
  /bin/sleep 300
) &
printf '%s\n' "$!" > "$2/holder.pid"
SH
bash "$TMP_DIR/holder.sh" "$SID" "$TMP_DIR"
/bin/sleep 1
detached=$(cat "$TMP_DIR/detached.pid"); holder=$(cat "$TMP_DIR/holder.pid")
out=$(bash "$ROOT/bin/ps.sh" 2>&1); has "$out" "(^|[^0-9])$detached([^0-9]|$)"
cond=$?; expect "dx ps lists the detached process under its session" "$cond" "$out"
kill -KILL "$holder" 2>/dev/null; /bin/sleep 1
out=$(bash "$ROOT/bin/ps.sh" 2>&1); has "$out" 'orphan' && has "$out" "(^|[^0-9])$detached([^0-9]|$)"
cond=$?; expect "after the holder dies the process is reported orphaned" "$cond" "$out"
out=$(bash "$ROOT/bin/ps.sh" --reap-orphans 2>&1); /bin/sleep 1
! kill -0 "$detached" 2>/dev/null
cond=$?; expect "--reap-orphans stops it" "$cond" "$out"
rm -f "$TMP_DIR/detached.pid" "$TMP_DIR/holder.pid"

# ── 8. worktree hooks: audit, apply, create, remove ─────────────────────────
git -C "$REPO" worktree add -q "$REPO/.dex/worktrees/ticket-1" -b ticket-1 2>/dev/null
out=$(cd "$REPO" && bash "$ROOT/bin/worktree.sh" audit 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && has "$out" 'ticket-9' && has "$out" 'ticket-1.*(live|still)'
cond=$?; expect "audit lists the reported orphan and holds back the live worktree (rc=$rc)" "$cond" "$out"
out=$(cd "$REPO" && bash "$ROOT/bin/worktree.sh" audit --apply 2>&1); rc=$?
grep -q 'remove name=ticket-9' "$MARKER_FILE" && ! grep -q 'remove name=ticket-1' "$MARKER_FILE" \
  && [[ -d "$REPO/.dex/worktrees/ticket-1" ]]
cond=$?; expect "--apply runs before_remove for ticket-9 only and leaves ticket-1 alone (rc=$rc)" "$cond" "$(cat "$MARKER_FILE")"
dx_worktree_hook_run after_create "$REPO" "$REPO/.dex/worktrees/ticket-1" ticket-1 "T-1" >/dev/null 2>&1
grep -q 'create name=ticket-1 ticket=T-1' "$MARKER_FILE"
cond=$?; expect "after_create receives the worktree name, ticket and paths" "$cond" "$(tail -1 "$MARKER_FILE")"
(cd "$REPO" && dx_wt_remove "$REPO/.dex/worktrees/ticket-1" >/dev/null 2>&1)
grep -q 'remove name=ticket-1' "$MARKER_FILE" && [[ ! -d "$REPO/.dex/worktrees/ticket-1" ]]
cond=$?; expect "dx_wt_remove runs before_remove and removes the worktree" "$cond" "$(tail -1 "$MARKER_FILE")"

# ── 9. the review-tier floor reads the change and the contract ──────────────
git -C "$REPO" checkout -q -b change
git -C "$REPO" -c commit.gpgsign=false commit -q -am "doc tweak"
floor=$(dx_review_scope_minimum_tier "$REPO" 2>&1)
[[ "$(printf '%s' "$floor" | cut -f1)" == trivial ]] || fail "a one-line doc change floors at trivial: $floor"
ok "a one-line doc change floors at trivial"
mkdir -p "$REPO/billing"; printf 'rate=1\n' > "$REPO/billing/rates.txt"
git -C "$REPO" add -A
git -C "$REPO" -c commit.gpgsign=false commit -q -m "touch a declared sensitive path"
floor=$(dx_review_scope_minimum_tier "$REPO" 2>&1)
[[ "$(printf '%s' "$floor" | cut -f1)" == complex ]] && has "$floor" 'declared-sensitive-path'
cond=$?; expect "a declared sensitive path floors at complex" "$cond" "$floor"

# ── 10. review stats over the events journal ────────────────────────────────
mkdir -p "$DX_RUN_ROOT/run_a"
{
  printf '{"run_id":"run_a","type":"review.tier.selected","data":{"tier":"trivial","profile":"light","required_clean":1}}\n'
  printf '{"run_id":"run_a","type":"review.pass.finished","data":{"result_kind":"clean","clean_before":0,"findings":0,"duration_seconds":120}}\n'
  printf '{"run_id":"run_a","type":"review.completed","data":{"tier":"trivial","reason":"clean_gate_reached"}}\n'
} > "$DX_RUN_ROOT/run_a/events.jsonl"
out=$(bash "$ROOT/bin/review.sh" stats --root "$DX_RUN_ROOT" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && has "$out" 'trivial'
cond=$?; expect "dx review stats reports the tier (rc=$rc)" "$cond" "$out"

# ── 11. doctor is read-only ─────────────────────────────────────────────────
out=$(bash "$ROOT/bin/doctor.sh" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && has "$out" 'session'
cond=$?; expect "dx doctor runs and reports sessions (rc=$rc)" "$cond" "$(printf '%s' "$out" | head -5)"

# ── 12. dxclean lists, and without --apply removes nothing ──────────────────
if command -v zsh >/dev/null 2>&1; then
  out=$(cd "$REPO" && zsh -c "source '$ROOT/dx.sh' >/dev/null 2>&1; dxclean" 2>&1); rc=$?
  [[ "$rc" -eq 0 ]] && has "$out" 'Nothing under .Host leftovers. was removed' \
    && has "$out" 'project resource +ticket-9'
  cond=$?; expect "dxclean lists the project's leftovers and removes nothing (rc=$rc)" "$cond" "$(printf '%s' "$out" | head -8)"
else
  printf 'skip dxclean: zsh is not installed on this host\n'
fi

printf 'host efficiency journey tests passed\n'
