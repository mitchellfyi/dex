#!/usr/bin/env bash
set -euo pipefail

# Host etiquette: what every phase is told about sharing the machine, and the
# advisory that catches the one command that ignores it.
#
# Two surfaces, one rule. The prompts say heavy work queues through
# `dx run-gate`, that the session owns what it starts, and that a phase does
# not end with a process still in flight. The guard says the same thing at the
# moment an agent is about to run a command the project itself called heavy.
#
# Both fail silently when they rot: a renamed heading leaves a phase prompt
# pointing at nothing, and a detector that stops reading the contract simply
# never fires again. Text and behaviour assertions are the only mechanical
# check there is, so they live here.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-host-etiquette.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# shellcheck disable=SC1091
source "$ROOT/tests/helpers.sh"

# ─── The completion criterion, in every phase that can leave work running ───

CRITERION='No session-owned background process in flight, per `dx ps`'

for audit in \
  prompts/phase-audits/3-review.md \
  prompts/phase-audits/3-review-loop.md \
  prompts/phase-audits/4-verify.md \
  prompts/phase-audits/5-pr.md \
  prompts/phase-audits/6-complete.md; do
  assert_contains "$CRITERION" "$ROOT/$audit"
done

# Phase 6 runs a watcher across its own cycles, so it gets the one carve-out —
# and the carve-out is conditional, not an exemption.
assert_contains "except the PR" "$ROOT/prompts/phase-audits/6-complete.md"
assert_contains "watcher loop, which must itself be session-owned" \
  "$ROOT/prompts/phase-audits/6-complete.md"
# No other phase may grant itself one.
for audit in \
  prompts/phase-audits/3-review.md \
  prompts/phase-audits/3-review-loop.md \
  prompts/phase-audits/4-verify.md \
  prompts/phase-audits/5-pr.md; do
  assert_not_contains "which must itself be session-owned" "$ROOT/$audit"
done

# ─── Resource Discipline: the shared fragment, and who points at it ─────────

GUARDRAILS="$ROOT/prompts/guardrails.md"
assert_contains '## Resource Discipline' "$GUARDRAILS"
# 1. You are one of several, and the numbers that say how many.
assert_contains 'You are one of several Dex sessions' "$GUARDRAILS"
for host_var in \
  'DX_HOST_ACTIVE_SESSIONS' \
  'DX_HOST_ACTIVE_HEAVY' \
  'DX_HOST_LOAD1' \
  'DX_TEST_JOBS'; do
  assert_contains "$host_var" "$GUARDRAILS"
done
assert_contains 'expect to queue' "$GUARDRAILS"
# 2. Which rung of the ladder this run is on.
assert_contains 'say which rung you are on' "$GUARDRAILS"
assert_contains 'name the rung in the transcript when you run tests' "$GUARDRAILS"
# 3. Heavy work takes the lease, and waiting for it is the correct outcome.
assert_contains 'Heavy work goes through `dx run-gate`' "$GUARDRAILS"
assert_contains 'Waiting is correct' "$GUARDRAILS"
assert_contains 'running it outside the lease slows everyone' "$GUARDRAILS"
# The pool has no re-entrancy: a gate inside a gate waits for its own parent,
# which on a host whose heavy limit is 1 never returns.
assert_contains 'lease per unit of work: a gate inside a gate queues behind its own parent' \
  "$GUARDRAILS"
# 4. The wait is for CPU-light work, not for a polling loop.
assert_contains 'Use the wait; never poll' "$GUARDRAILS"
assert_contains 'Never sit in a tool-call loop' "$GUARDRAILS"
# 5. Own what you start: dx ps, the phase boundary, ports, DX_SESSION_TMP.
assert_contains 'Own what you start' "$GUARDRAILS"
assert_contains '`dx ps` lists what this session owns' "$GUARDRAILS"
assert_contains 'must survive that, say so' "$GUARDRAILS"
assert_contains 'in the transcript and why' "$GUARDRAILS"
assert_contains 'Reuse a port this session already owns' "$GUARDRAILS"
assert_contains 'DX_SESSION_TMP' "$GUARDRAILS"
# 6. Hand the tree over in the state the next agent needs.
assert_contains 'Leave the tree the way the next agent needs it' "$GUARDRAILS"
# 7. A saturated host is a reason to stop adding, not to fan out.
assert_contains 'When the host is saturated' "$GUARDRAILS"
assert_contains 'until `dx run-gate` reports capacity' "$GUARDRAILS"
assert_contains 'compensate by splitting into more parallel subagents' "$GUARDRAILS"

# Every phase prompt and skill in the lifecycle names the section, or names
# the file that holds it. Either reaches the same text; neither one being
# present means the phase was never told.
for consumer in \
  prompts/phase-audits/0-setup.md \
  prompts/phase-audits/1-plan.md \
  prompts/phase-audits/2-implement.md \
  prompts/phase-audits/3-review.md \
  prompts/phase-audits/3-review-loop.md \
  prompts/phase-audits/4-verify.md \
  prompts/phase-audits/5-pr.md \
  prompts/phase-audits/6-complete.md \
  prompts/workflows/dximplement.md \
  prompts/workflows/dxplan.md \
  prompts/ui-proof.md \
  skills/dxverify/SKILL.md; do
  grep -Fq -e 'Resource Discipline' -e 'prompts/guardrails.md' "$ROOT/$consumer" \
    || fail "$consumer does not reach Resource Discipline"
done

# Every numbered phase audit, so a new one cannot quietly ship without it.
for audit in "$ROOT"/prompts/phase-audits/[0-9]*.md; do
  grep -Fq -e 'Resource Discipline' -e 'prompts/guardrails.md' "$audit" \
    || fail "${audit##*/} does not reach Resource Discipline"
done

# ─── Ports, and the gates that go through the lease ─────────────────────────

IMPLEMENT="$ROOT/prompts/workflows/dximplement.md"
assert_contains 'Reuse the port your session owns' "$IMPLEMENT"
assert_contains 'report it, do not fight it' "$IMPLEMENT"
# A dev server is a session-owned process, not a gate: `dx run-gate` runs in
# the foreground and would hold the host's lease for the server's whole life.
assert_contains 'directly, not under `dx run-gate`' "$IMPLEMENT"
assert_not_contains 'runs it, through `dx run-gate' "$IMPLEMENT"
assert_not_contains 'a build or a dev server goes' "$GUARDRAILS"
assert_contains 'a dev server starts directly and is session-owned' "$GUARDRAILS"
# The advice it replaces told an agent to walk up the port range, which is how
# a host ends up with six dev servers nobody can attribute.
assert_not_contains 'another port' "$IMPLEMENT"
assert_contains '`dx run-gate <command>`' "$IMPLEMENT"

UI_PROOF="$ROOT/prompts/ui-proof.md"
assert_contains 'dx run-gate' "$UI_PROOF"
# `dx` is a zsh function, so nothing on PATH resolves it under the gate's
# priority prefix; the capture is run through its bash entry point.
assert_contains 'dx run-gate -- bash "$DEX_DIR/bin/ui-capture.sh" capture' "$UI_PROOF"
assert_not_contains 'dx run-gate -- dx ' "$UI_PROOF"
# The capture holds the proof's one lease, so the server it drives must not
# take a second — nothing would ever release the first.
assert_contains 'Start it directly, not under' "$UI_PROOF"
# Item 5's worktree helpers own the baseline checkout; the capture routing
# must not have replaced them.
assert_contains 'dx worktree add-baseline' "$UI_PROOF"
assert_contains 'dx worktree remove-baseline' "$UI_PROOF"

assert_contains 'dx run-gate' "$ROOT/skills/dxverify/SKILL.md"
assert_contains 'dx run-gate' "$ROOT/prompts/phase-audits/4-verify.md"

# ─── The advisory's message reaches the reader in the right order ──────────

GUARD_BODY="$ROOT/hooks/guards/detached-processes.md"
# Most firings are a foreground declared command, for which every sentence
# about detachment is false. The opening must not assert detachment, and the
# heavy-command paragraph must come before the detachment half.
assert_contains 'This is either a command this project declared heavy' "$GUARD_BODY"
assert_contains 'run it through `dx run-gate` so it queues and is owned' "$GUARD_BODY"
HEAVY_AT=$(grep -n 'A declared heavy command' "$GUARD_BODY" | cut -d: -f1)
DETACH_AT=$(grep -n 'Work that outlives the command\*\*' "$GUARD_BODY" | cut -d: -f1)
[[ -n "$HEAVY_AT" && -n "$DETACH_AT" && "$HEAVY_AT" -lt "$DETACH_AT" ]] || assert_at $LINENO

# ─── The advisory: a declared heavy command run outside the lease ───────────

export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export HOME="$TMP_DIR/home"
mkdir -p "$HOME" "$DX_STATE_DIR"
CACHE="$DX_STATE_DIR/guard-heavy-commands.json"

REPO="$TMP_DIR/repo"
mkdir -p "$REPO/.dex"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email dex@example.test
git -C "$REPO" config user.name Dex

write_contract() {
  cat > "$REPO/.dex/dex.md"
}

# `verdict <command>` → fires | quiet, from a real hook invocation in $REPO.
# The guard is advisory, so the hook's own exit status is asserted separately.
GUARD_STATUS=0
verdict() {
  local command_text="$1" payload guard_out
  payload=$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' \
    "$command_text")
  GUARD_STATUS=0
  guard_out=$(cd "$REPO" && printf '%s' "$payload" \
    | env DEX_GUARD_EVENT=bash python3 "$ROOT/hooks/guard-handler.py" 2>&1) || GUARD_STATUS=$?
  case "$guard_out" in
    *warn-detached-processes*) printf 'fires\n' ;;
    *) printf 'quiet\n' ;;
  esac
}

# No contract at all: the detector must contribute nothing, and the shapes the
# guard already knew must still be read.
assert_eq "quiet" "$(verdict 'make build')" "no contract, ordinary command"
assert_eq "quiet" "$(verdict 'git log --oneline -5')" "no contract, git"
assert_eq "fires" "$(verdict 'nohup ./server &')" "no contract, detached launch"

write_contract <<'CONTRACT'
# Fake project

## Resources

```yaml
parallelism_env: [BUILD_WORKERS]
heavy_commands:
  - make build
  - "./gradlew test"
targeted_tests: "make test {files}"
```

## Quality Gates

Nothing here.
CONTRACT

assert_eq "fires" "$(verdict 'make build')" "declared command"
assert_eq "0" "$GUARD_STATUS" "the advisory never denies the tool call"
assert_eq "fires" "$(verdict 'make build --jobs 2')" "declared command with arguments"
assert_eq "fires" "$(verdict './gradlew test')" "declared command written with ./"
assert_eq "fires" "$(verdict 'gradlew test')" "declared ./command written without it"
assert_eq "fires" "$(verdict 'BUILD_WORKERS=2 make build')" "leading assignment"
assert_eq "fires" "$(verdict 'cd sub && make build')" "second segment"
assert_eq "fires" "$(verdict 'git pull; make build')" "after a separator"

# Already under the lease, which is the thing the message asks for.
assert_eq "quiet" "$(verdict 'dx run-gate make build')" "already gated"
assert_eq "quiet" "$(verdict 'dx run-gate -- make build')" "already gated with --"
assert_eq "quiet" "$(verdict 'bash "$DEX_DIR/bin/run-gate.sh" make build')" "gate script"

# Whole words only, and command position only.
assert_eq "quiet" "$(verdict 'make test')" "different subcommand"
assert_eq "quiet" "$(verdict 'makebuild')" "not a word boundary"
assert_eq "quiet" "$(verdict 'echo make build')" "named as an argument"
assert_eq "quiet" "$(verdict 'grep -r "make build" .')" "quoted in an argument"

# A contract with the section but not the key, and a block that is not a flat
# mapping, both read as "this project declared nothing".
write_contract <<'CONTRACT'
## Resources

```yaml
parallelism_env: [BUILD_WORKERS]
targeted_tests: "make test {files}"
```
CONTRACT
assert_eq "quiet" "$(verdict 'make build')" "no heavy_commands key"

write_contract <<'CONTRACT'
## Resources

```yaml
heavy_commands:
  build:
    command: make build
```
CONTRACT
assert_eq "quiet" "$(verdict 'make build')" "malformed block"

write_contract <<'CONTRACT'
## Quality Gates

No Resources section at all.
CONTRACT
assert_eq "quiet" "$(verdict 'make build')" "no Resources section"

# ─── The cache is keyed by the contract's mtime, not by its path alone ──────

write_contract <<'CONTRACT'
## Resources

```yaml
heavy_commands:
  - make build
```
CONTRACT
assert_eq "fires" "$(verdict 'make build')" "cache primed"
assert_file "$CACHE"
CACHE_MODE=$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' \
  "$CACHE")
assert_eq "0o600" "$CACHE_MODE" "cache file mode"
assert_contains "make build" "$CACHE"
# The hook keys on the path git reports, which on macOS resolves /var to
# /private/var; the cache must be asserted against the same spelling.
REPO_REAL="$(cd "$REPO" && git rev-parse --show-toplevel)"
assert_contains "$REPO_REAL/.dex/dex.md" "$CACHE"

# A hit must not re-read the contract: blank the file's content while keeping
# its stamp, and the cached answer still stands.
STAMP=$(python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(s.st_mtime_ns)' \
  "$REPO/.dex/dex.md")
SIZE=$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_size)' "$REPO/.dex/dex.md")
python3 - "$REPO/.dex/dex.md" "$STAMP" "$SIZE" <<'PY'
import os, sys
path, stamp, size = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
# Same byte count, no heavy_commands, same mtime: only a stale cache can still
# answer "fires" here, which is exactly what is being asserted.
with open(path, 'w', encoding='utf-8') as handle:
    handle.write('x' * (size - 1) + '\n')
os.utime(path, ns=(stamp, stamp))
PY
assert_eq "fires" "$(verdict 'make build')" "cached answer survives an unchanged stamp"

# Moving the stamp invalidates it, and the new contract is what answers.
python3 - "$REPO/.dex/dex.md" <<'PY'
import sys
with open(sys.argv[1], 'w', encoding='utf-8') as handle:
    handle.write('## Resources\n\n```yaml\nheavy_commands:\n  - npm run build\n```\n')
PY
assert_eq "quiet" "$(verdict 'make build')" "old command after the contract changed"
assert_eq "fires" "$(verdict 'npm run build')" "new command after the contract changed"
assert_contains "npm run build" "$CACHE"

# One entry per contract path, not one per read.
ENTRIES=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$CACHE")
assert_eq "1" "$ENTRIES" "cache entries"

printf 'host etiquette tests passed\n'
