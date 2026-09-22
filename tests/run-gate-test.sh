#!/usr/bin/env bash
set -euo pipefail

# `dx run-gate` is host-wide admission for heavy work, and the three claims that
# matter are the ones an agent will rely on: the queue is first-come, the wait
# is visible, and a cancelled gate leaves nothing running.
#
# The pool mechanics and the `## Resources` reader are asserted here too,
# because run-gate is the only caller of either and a contract nobody reads is
# not a contract.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-run-gate-test.XXXXXX")"

cleanup() {
  local stray
  if [[ -d "$TMP_DIR" ]]; then
    while IFS= read -r stray; do
      [[ "$stray" =~ ^[0-9]+$ ]] || continue
      kill -KILL "$stray" 2>/dev/null || true
    done < <(find "$TMP_DIR" -type f -name '*.pid' -exec cat {} \; 2>/dev/null \
      || true)
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_REVIEW_CAPACITY_DIR="$TMP_DIR/capacity"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
export DX_TOOL_DIR="$TMP_DIR/tools"
export DX_RUN_ROOT="$TMP_DIR/runs"
# One heavy slot, so two waiters have to queue rather than both being admitted.
export DEX_MAX_ACTIVE_HEAVY=1
# A heartbeat every second, so the wait is observable inside a test.
export DEX_GATE_HEARTBEAT_SECONDS=1
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR" "$DX_RUN_ROOT"

REPO="$TMP_DIR/repo"
mkdir -p "$REPO/.dex"
git init -q "$REPO"
git -C "$REPO" config user.email "dex@example.com"
git -C "$REPO" config user.name "Dex Test"
printf 'project\n' > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" -c commit.gpgsign=false commit -q -m "init"
cat > "$REPO/.dex/dex.md" <<'CONTRACT'
# Fake project

## Quality Gates
| Check | Command | Scope |
|-------|---------|-------|
| Test | `run-suite` | everything |

## Resources

```yaml
parallelism_env: [PARALLEL_WORKERS, SECOND_WORKERS]
heavy_commands:
  - run-suite
  - "sh -c"
targeted_tests: "run-suite {files}"
```

## Project Structure
Flat.
CONTRACT

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

REPO_HEAD="$(git -C "$REPO" rev-parse HEAD)"

wait_for_file() {
  local file="$1" label="$2" attempt=0
  while [[ ! -s "$file" && $attempt -lt 400 ]]; do
    /bin/sleep 0.05
    attempt=$((attempt + 1))
  done
  [[ -s "$file" ]] || fail "$label: $file was never written"
}

wait_for_text() {
  local needle="$1" file="$2" label="$3" attempt=0
  while ! grep -Fq -- "$needle" "$file" 2>/dev/null; do
    attempt=$((attempt + 1))
    [[ $attempt -lt 600 ]] || {
      printf 'output so far:\n' >&2
      cat "$file" >&2 2>/dev/null || true
      fail "$label: never saw '$needle'"
    }
    /bin/sleep 0.05
  done
}

assert_gone() {
  local pid="$1" label="$2" attempt=0
  while kill -0 "$pid" 2>/dev/null && [[ $attempt -lt 400 ]]; do
    /bin/sleep 0.05
    attempt=$((attempt + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    fail "$label: process $pid was not stopped"
  fi
}

run_gate() {
  local output_file="$1"
  shift
  set +e
  ( cd "$REPO" && bash "$ROOT/bin/run-gate.sh" "$@" ) > "$output_file" 2>&1
  GATE_STATUS=$?
  set -e
}

# ── The `## Resources` project contract ────────────────────────────────────
CONTRACT_RC=0
CONTRACT_OUT="$TMP_DIR/contract.out"
dx_project_contract_values "$REPO" Resources parallelism_env > "$CONTRACT_OUT"
assert_eq "PARALLEL_WORKERS
SECOND_WORKERS" "$(cat "$CONTRACT_OUT")" "inline list, one name per line"
assert_eq "run-suite
sh -c" "$(dx_project_contract_values "$REPO" Resources heavy_commands)" \
  "block list, quoted item unquoted"
assert_eq "run-suite {files}" \
  "$(dx_project_contract_values "$REPO" Resources targeted_tests)" \
  "quoted scalar keeps its braces"
CONTRACT_RC=0
dx_project_contract_values "$REPO" Resources no_such_key >/dev/null 2>&1 \
  || CONTRACT_RC=$?
assert_eq "1" "$CONTRACT_RC" "an absent key reads as 'nothing declared'"
CONTRACT_RC=0
dx_project_contract_values "$REPO" "Worktree Hooks" parallelism_env \
  >/dev/null 2>&1 || CONTRACT_RC=$?
assert_eq "1" "$CONTRACT_RC" "an absent section reads as 'nothing declared'"
CONTRACT_RC=0
dx_project_contract_values "$TMP_DIR/nowhere" Resources parallelism_env \
  >/dev/null 2>&1 || CONTRACT_RC=$?
assert_eq "1" "$CONTRACT_RC" "a repository with no .dex/dex.md declares nothing"
CONTRACT_RC=0
dx_project_contract_values "$REPO" Resources >/dev/null 2>&1 || CONTRACT_RC=$?
assert_eq "2" "$CONTRACT_RC" "a missing argument is rejected"

# The contract Dex itself tells `dx init` to write. This is the regression test
# for the one that mattered: the template comments every key, `# ` read as a
# markdown heading ended the section mid-block, the fence was then
# unterminated, and all three keys came back "nothing declared" — silently,
# because only a malformed *block* warns. Extracted from the shipped template
# rather than retyped, so changing the template into something unparseable
# fails here.
TEMPLATE_REPO="$TMP_DIR/from-template"
mkdir -p "$TEMPLATE_REPO/.dex"
python3 - "$ROOT/prompts/init-analysis.md" "$TEMPLATE_REPO/.dex/dex.md" <<'TEMPLATE'
import re
import sys
from pathlib import Path

template = Path(sys.argv[1]).read_text(encoding="utf-8")
section = re.search(r"\n## Resources\n(.*?)\n## Project Structure\n", template, re.S)
if section is None:
    raise SystemExit("prompts/init-analysis.md has no '## Resources' template section")
body = section.group(1)
if "\n# " not in body:
    raise SystemExit("the template no longer comments its keys; this test is pointless")
Path(sys.argv[2]).write_text(
    "# Generated project\n\n## Resources\n" + body + "\n## Project Structure\nFlat.\n",
    encoding="utf-8",
)
TEMPLATE
for template_key in parallelism_env heavy_commands targeted_tests; do
  CONTRACT_RC=0
  TEMPLATE_VALUE="$(dx_project_contract_values "$TEMPLATE_REPO" Resources \
    "$template_key" 2>/dev/null)" || CONTRACT_RC=$?
  assert_eq "0" "$CONTRACT_RC" \
    "the shipped template's ${template_key} is readable"
  [[ -n "$TEMPLATE_VALUE" ]] || assert_at $LINENO
done
# A comment inside the block does not leak into the parsed values either.
assert_eq "WORKER_COUNT_VARIABLE" \
  "$(dx_project_contract_values "$TEMPLATE_REPO" Resources parallelism_env)" \
  "a commented template still yields only its values"
# And the section after the fenced block is still bounded correctly.
CONTRACT_RC=0
dx_project_contract_values "$TEMPLATE_REPO" "Project Structure" parallelism_env \
  >/dev/null 2>&1 || CONTRACT_RC=$?
assert_eq "1" "$CONTRACT_RC" "the fenced block does not swallow the next section"

# A nested block is not the flat mapping the contract covers, and saying so is
# better than half-understanding it.
NESTED_REPO="$TMP_DIR/nested"
mkdir -p "$NESTED_REPO/.dex"
cat > "$NESTED_REPO/.dex/dex.md" <<'NESTED'
# Nested

## Resources

```yaml
runners:
  jest:
    workers: 4
```
NESTED
CONTRACT_RC=0
dx_project_contract_values "$NESTED_REPO" Resources runners \
  >/dev/null 2>"$TMP_DIR/nested.err" || CONTRACT_RC=$?
assert_eq "2" "$CONTRACT_RC" "a nested block is reported, not guessed at"
assert_contains "not a flat mapping" "$TMP_DIR/nested.err"

# ── Named capacity pools ───────────────────────────────────────────────────
assert_eq "$DX_REVIEW_CAPACITY_DIR" "$(dx_capacity_pool_root waves)" \
  "the waves pool keeps the original root, so every existing caller is unchanged"
assert_eq "$DX_REVIEW_CAPACITY_DIR/checks" "$(dx_capacity_pool_root checks)" \
  "the checks pool is where bin/review-check.sh has always put it"
assert_eq "$DX_REVIEW_CAPACITY_DIR/heavy" "$(dx_capacity_pool_root heavy)" \
  "the heavy pool is its own directory"
POOL_RC=0
dx_capacity_pool_root nonsense >/dev/null 2>&1 || POOL_RC=$?
assert_eq "2" "$POOL_RC" "an unknown pool name is rejected"
assert_eq "1" "$(dx_capacity_pool_limit heavy)" \
  "DEX_MAX_ACTIVE_HEAVY sets the heavy limit"
assert_eq "3" "$(DEX_REVIEW_MAX_ACTIVE_WAVES=3 dx_capacity_pool_limit waves)" \
  "the waves limit still comes from its own variable"
assert_eq "0" "$(dx_capacity_pool_live_count heavy)" \
  "an empty heavy pool holds nothing"

# The pool wrapper must not leak its selector: a later waves-pool caller has to
# keep seeing the root the caller configured.
dx_capacity_pool_wait heavy session-pool pool-probe
assert_eq "1" "$(dx_capacity_pool_live_count heavy)" "the lease is visible"
assert_eq "$DX_REVIEW_CAPACITY_DIR" "$(dx_review_capacity_root)" \
  "the pool wrapper restored DX_REVIEW_CAPACITY_DIR"
IFS=$'\t' read -r POOL_AHEAD POOL_OLDEST <<EOF
$(dx_capacity_pool_queue_status heavy pool-probe)
EOF
assert_eq "1" "$POOL_AHEAD" "the holder counts itself as running"
[[ "$POOL_OLDEST" =~ ^[0-9]+$ ]] || assert_at $LINENO
dx_capacity_pool_release heavy pool-probe
assert_eq "0" "$(dx_capacity_pool_live_count heavy)" "the lease was released"

# ── Argument handling, the way every user-facing bin/ script does it ───────
run_gate "$TMP_DIR/help.out" --help
assert_eq "0" "$GATE_STATUS" "dx run-gate --help status"
assert_contains "Usage: dx run-gate" "$TMP_DIR/help.out"
run_gate "$TMP_DIR/badopt.out" --nonsense true
assert_eq "2" "$GATE_STATUS" "an unknown option fails"
assert_contains "Unknown run-gate option: --nonsense" "$TMP_DIR/badopt.out"
run_gate "$TMP_DIR/nocmd.out"
assert_eq "2" "$GATE_STATUS" "no command fails"
assert_contains "needs a command to run" "$TMP_DIR/nocmd.out"
run_gate "$TMP_DIR/badtimeout.out" --timeout later -- true
assert_eq "2" "$GATE_STATUS" "a non-numeric timeout fails"
run_gate "$TMP_DIR/badname.out" --name "../escape" -- true
assert_eq "2" "$GATE_STATUS" "a gate name that is not a filename fails"

# ── One gate: the result, the log, the receipt, the child's environment ────
# The session owns the gate: attaching the token here is what dx.sh does around
# a phase, and the gate's own child has to inherit both halves of it.
GATE_SESSION="gate-session"
(
  dx_session_process_token_attach "$GATE_SESSION"
  export DEX_SESSION_ID="$GATE_SESSION"
  cd "$REPO"
  exec bash "$ROOT/bin/run-gate.sh" --name suite -- sh -c '
    printf "workers=%s second=%s\n" "$PARALLEL_WORKERS" "$SECOND_WORKERS"
    printf "token=%s\n" "${DX_SESSION_PROCESS_TOKEN:-none}"
    if [ -r /dev/fd/8 ]; then printf "fd8=open\n"; else printf "fd8=closed\n"; fi
    printf "timeout_token=%s\n" "${DX_TIMEOUT_PROCESS_TOKEN:-none}"
    exit 3'
) > "$TMP_DIR/suite.out" 2>&1 && SUITE_STATUS=0 || SUITE_STATUS=$?
assert_eq "3" "$SUITE_STATUS" "run-gate returns the command's own exit status"
assert_contains "declared heavy in .dex/dex.md" "$TMP_DIR/suite.out"
GATE_JOBS="$(DEX_SESSION_ID="$GATE_SESSION" dx_host_test_jobs_effective)"
assert_contains "workers=${GATE_JOBS} second=${GATE_JOBS}" "$TMP_DIR/suite.out"
assert_contains "fd8=open" "$TMP_DIR/suite.out"
assert_not_contains "token=none" "$TMP_DIR/suite.out"
# fd 9 belongs to the per-command timeout supervisor, and the two descriptors
# must stay separate or a timed gate takes the session's processes with it.
assert_not_contains "timeout_token=none" "$TMP_DIR/suite.out"

GATE_LOG="$(dx_session_tmp_dir "$GATE_SESSION")/gates/1.log"
[[ -f "$GATE_LOG" ]] || assert_at $LINENO
assert_contains "fd8=open" "$GATE_LOG"
assert_contains "$GATE_LOG" "$TMP_DIR/suite.out"

GATE_RECEIPT="$(dx_gate_receipt_dir "$GATE_SESSION")/suite.json"
[[ -f "$GATE_RECEIPT" ]] || assert_at $LINENO
assert_eq "600" "$(dx_path_mode "$GATE_RECEIPT")" "a receipt is private"
RECEIPT_FIELDS="$(python3 - "$GATE_RECEIPT" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    receipt = json.load(handle)
print(receipt["gate"])
print(receipt["exit_code"])
print(receipt["checkout_fingerprint"])
print(receipt["priority_wrapper"])
print(receipt["stable"])
print(" ".join(receipt["parallelism_env"]))
PY
)"
IFS=$'\n' read -r -d '' RECEIPT_GATE RECEIPT_EXIT RECEIPT_HEAD RECEIPT_WRAPPER \
  RECEIPT_STABLE RECEIPT_PARALLELISM <<EOF || true
$RECEIPT_FIELDS
EOF
assert_eq "suite" "$RECEIPT_GATE" "the receipt names its gate"
assert_eq "3" "$RECEIPT_EXIT" "a failing gate is recorded, not discarded"
assert_eq "$REPO_HEAD" "$RECEIPT_HEAD" "the checkout fingerprint is HEAD"
assert_eq "True" "$RECEIPT_STABLE" "an unchanged tree records a stable result"
assert_eq "PARALLEL_WORKERS SECOND_WORKERS" "$RECEIPT_PARALLELISM" \
  "the receipt records which declared variables were set"
# The wrapper recorded has to be the one this host can actually run, not a
# constant: a Linux box must not report nice+taskpolicy and vice versa.
assert_eq "$(dx_host_priority_wrapper)" "$RECEIPT_WRAPPER" \
  "the receipt records the priority wrapper that was used"
case "$RECEIPT_WRAPPER" in
  nice|none|nice+taskpolicy|nice+ionice|systemd-run) ;;
  *) fail "unknown priority wrapper recorded: $RECEIPT_WRAPPER" ;;
esac
if [[ "$(uname -s)" == "Darwin" && "$RECEIPT_WRAPPER" != nice+taskpolicy ]]; then
  fail "macOS has taskpolicy; the gate ran under $RECEIPT_WRAPPER"
fi

REPO_WORKING="$(cd "$REPO" && dx_review_working_fingerprint "$REPO")"
LOOKUP_OUT="$TMP_DIR/lookup.out"
dx_gate_receipt_lookup "$GATE_SESSION" "$REPO_HEAD" "$REPO_WORKING" \
  > "$LOOKUP_OUT"
assert_contains "$(printf '%s\t%s\t%s' "$GATE_SESSION" suite 3)" "$LOOKUP_OUT"
dx_gate_receipt_lookup - "$REPO_HEAD" "$REPO_WORKING" suite > "$LOOKUP_OUT"
assert_contains "suite" "$LOOKUP_OUT"
LOOKUP_RC=0
dx_gate_receipt_lookup "$GATE_SESSION" "$REPO_HEAD" "$REPO_WORKING" other \
  >/dev/null 2>&1 || LOOKUP_RC=$?
assert_eq "1" "$LOOKUP_RC" "a gate that never ran has no receipt"
LOOKUP_RC=0
dx_gate_receipt_lookup "$GATE_SESSION" "$REPO_HEAD" changed-tree \
  >/dev/null 2>&1 || LOOKUP_RC=$?
assert_eq "1" "$LOOKUP_RC" "a different working tree matches nothing"

# A command the project did not declare heavy still leases; it is told so.
run_gate "$TMP_DIR/undeclared.out" --name undeclared -- true
assert_eq "0" "$GATE_STATUS" "an undeclared command still runs"
assert_contains "not declared heavy" "$TMP_DIR/undeclared.out"

# ── A derived gate name never refuses to run the gate ──────────────────────
# `./bin/verify` is the most ordinary way there is to name a project gate, and
# the first sanitiser stripped a leading `-` but not a leading `.`, so it failed
# argument validation and ran nothing at all. Every other test here passes
# --name, which is how that went unnoticed.
mkdir -p "$REPO/bin"
printf '#!/bin/sh\nprintf "verified\\n"\n' > "$REPO/bin/verify"
chmod +x "$REPO/bin/verify"
printf '#!/bin/sh\nprintf "gradled %%s\\n" "$1"\n' > "$REPO/gradlew"
chmod +x "$REPO/gradlew"
run_gate "$TMP_DIR/derived.out" -- ./bin/verify
assert_eq "0" "$GATE_STATUS" "a command starting with . runs"
assert_contains "verified" "$TMP_DIR/derived.out"
assert_contains "bin-verify: passed" "$TMP_DIR/derived.out"
[[ -f "$(dx_gate_receipt_dir "$(cd "$REPO" && dx_session_id)")/bin-verify.json" ]] \
  || assert_at $LINENO
run_gate "$TMP_DIR/derived-args.out" -- ./gradlew test
assert_eq "0" "$GATE_STATUS" "a dot-prefixed command with arguments runs"
assert_contains "gradled test" "$TMP_DIR/derived-args.out"
assert_contains "gradlew-test: passed" "$TMP_DIR/derived-args.out"
# A command that sanitises to nothing usable still runs, under a plain name,
# rather than being refused for a name the caller never chose.
run_gate "$TMP_DIR/derived-bare.out" -- ../../////
assert_not_contains "must start alphanumeric" "$TMP_DIR/derived-bare.out"
[[ -f "$(dx_gate_receipt_dir "$(cd "$REPO" && dx_session_id)")/gate.json" ]] \
  || assert_at $LINENO
# Two different commands must not land on one receipt.
[[ "$(dx_gate_receipt_slot bin-verify)" != "$(dx_gate_receipt_slot gradlew-test)" ]] \
  || assert_at $LINENO

# ── A repository that declared nothing behaves exactly as before ───────────
# The `## Resources` section is an optimisation, never a prerequisite: with it
# absent the only thing that changes is that the command took a lease.
BARE_REPO="$TMP_DIR/bare"
mkdir -p "$BARE_REPO"
git init -q "$BARE_REPO"
git -C "$BARE_REPO" config user.email "dex@example.com"
git -C "$BARE_REPO" config user.name "Dex Test"
git -C "$BARE_REPO" -c commit.gpgsign=false commit -q --allow-empty -m init
BARE_OUT="$TMP_DIR/bare.out"
set +e
(
  cd "$BARE_REPO"
  DEX_SESSION_ID=session-bare exec bash "$ROOT/bin/run-gate.sh" --name bare \
    -- sh -c 'printf "declared=%s\n" "${PARALLEL_WORKERS:-none}"'
) > "$BARE_OUT" 2>&1
BARE_STATUS=$?
set -e
assert_eq "0" "$BARE_STATUS" "a repository with no contract still runs its gate"
assert_contains "declared=none" "$BARE_OUT"
assert_not_contains "not declared heavy" "$BARE_OUT"
assert_not_contains "declared heavy in" "$BARE_OUT"
assert_contains "waiting for heavy capacity" "$BARE_OUT"
[[ -f "$(dx_gate_receipt_dir session-bare)/bare.json" ]] || assert_at $LINENO

# A malformed section is reported once and then ignored, rather than failing
# the gate the project was trying to run.
NESTED_GIT="$TMP_DIR/nested"
git init -q "$NESTED_GIT"
git -C "$NESTED_GIT" config user.email "dex@example.com"
git -C "$NESTED_GIT" config user.name "Dex Test"
git -C "$NESTED_GIT" -c commit.gpgsign=false commit -q --allow-empty -m init
NESTED_OUT="$TMP_DIR/nested-gate.out"
set +e
(
  cd "$NESTED_GIT"
  DEX_SESSION_ID=session-nested exec bash "$ROOT/bin/run-gate.sh" \
    --name nested -- true
) > "$NESTED_OUT" 2>&1
NESTED_STATUS=$?
set -e
assert_eq "0" "$NESTED_STATUS" "a malformed contract does not fail the gate"
assert_contains "not a flat YAML mapping" "$NESTED_OUT"

# ── Two queued sessions, one slot: first come, first served ────────────────
ORDER="$TMP_DIR/order"
: > "$ORDER"
RELEASE="$TMP_DIR/release"
HOLDER_OUT="$TMP_DIR/holder.out"
(
  cd "$REPO"
  DEX_SESSION_ID=session-holder exec bash "$ROOT/bin/run-gate.sh" \
    --name holder -- sh -c "
      printf 'holder\n' >> '$ORDER'
      while [ ! -f '$RELEASE' ]; do sleep 0.1; done"
) > "$HOLDER_OUT" 2>&1 &
HOLDER_PID=$!
wait_for_text holder "$ORDER" "holder gate"

FIRST_OUT="$TMP_DIR/first.out"
(
  cd "$REPO"
  DEX_SESSION_ID=session-first exec bash "$ROOT/bin/run-gate.sh" \
    --name first -- sh -c "printf 'first\n' >> '$ORDER'"
) > "$FIRST_OUT" 2>&1 &
FIRST_PID=$!
# The heartbeat is proof the first waiter is in the queue, which is what makes
# the order below a property of the queue rather than of the scheduler.
wait_for_text "queued behind 1, oldest started" "$FIRST_OUT" "first waiter"

SECOND_OUT="$TMP_DIR/second.out"
(
  cd "$REPO"
  DEX_SESSION_ID=session-second exec bash "$ROOT/bin/run-gate.sh" \
    --name second -- sh -c "printf 'second\n' >> '$ORDER'"
) > "$SECOND_OUT" 2>&1 &
SECOND_PID=$!
wait_for_text "queued behind" "$SECOND_OUT" "second waiter"

assert_eq "1" "$(dx_capacity_pool_live_count heavy)" \
  "one heavy slot admits exactly one command"
touch "$RELEASE"
wait "$HOLDER_PID" || fail "the holder gate failed"
wait "$FIRST_PID" || fail "the first waiter failed"
wait "$SECOND_PID" || fail "the second waiter failed"
assert_eq "holder
first
second" "$(cat "$ORDER")" "the heavy queue admits in the order owners joined it"
assert_eq "0" "$(dx_capacity_pool_live_count heavy)" "every lease was released"
# The heartbeat says who is ahead and for how long, and waiting never fails.
assert_contains "queued behind 2" "$SECOND_OUT"
assert_contains "second: passed" "$SECOND_OUT"

# ── Cancelling a running gate leaves nothing behind ───────────────────────
CHILD_PID_FILE="$TMP_DIR/cancelled.pid"
CANCEL_OUT="$TMP_DIR/cancel.out"
(
  cd "$REPO"
  DEX_SESSION_ID=session-cancel exec bash "$ROOT/bin/run-gate.sh" \
    --name cancelled -- sh -c "printf '%s\n' \$\$ > '$CHILD_PID_FILE'; exec sleep 120"
) > "$CANCEL_OUT" 2>&1 &
CANCEL_PID=$!
wait_for_file "$CHILD_PID_FILE" "cancelled gate child"
CHILD_PID="$(cat "$CHILD_PID_FILE")"
[[ "$CHILD_PID" =~ ^[1-9][0-9]*$ ]] || assert_at $LINENO
kill -TERM "$CANCEL_PID"
CANCEL_STATUS=0
wait "$CANCEL_PID" || CANCEL_STATUS=$?
assert_gone "$CHILD_PID" "cancelled gate"
assert_eq "0" "$(dx_capacity_pool_live_count heavy)" \
  "a cancelled gate releases its lease"
[[ "$CANCEL_STATUS" -ne 0 ]] || assert_at $LINENO
# A cancelled command still ended, so its result is recorded rather than lost.
[[ -f "$(dx_gate_receipt_dir session-cancel)/cancelled.json" ]] \
  || assert_at $LINENO

printf 'run-gate tests passed\n'
