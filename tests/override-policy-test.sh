#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-override-policy.XXXXXX")"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_RUN_ROOT="$TMP_DIR/runs"
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

SESSION="repo-override-policy-main"
NOW="$(date +%s)"

assert_eq "900" "$(dx_override_effective "$SESSION" review.pass-timeout 900 3)" \
  "default without an override"

dx_override_set "$SESSION" review.pass-timeout 2400 phase 3 agent \
  "The thorough checks need a longer provider window" 0
assert_eq "2400" "$(dx_override_effective "$SESSION" review.pass-timeout 900 3)" \
  "phase override"
assert_eq "900" "$(dx_override_effective "$SESSION" review.pass-timeout 900 2)" \
  "phase isolation"
dx_override_set "$SESSION" review.clean-passes 2 phase 3 human \
  "Accept two independent clean waves for this unusually expensive scope" 0
REVIEW_WAIVER_BINDING=$(dx_override_binding "$SESSION" review.clean-passes 2 3)
[[ "$REVIEW_WAIVER_BINDING" =~ ^[a-f0-9]{64}$ ]] || assert_at $LINENO
assert_rejected "$LINENO" dx_override_binding "$SESSION" review.clean-passes 3 3

dx_override_set "$SESSION" review.pass-timeout 3600 session - human \
  "Keep review waves roomy for this run" 0
assert_eq "3600" "$(dx_override_effective "$SESSION" review.pass-timeout 900 2)" \
  "session override"
assert_eq "3600" "$(dx_override_effective "$SESSION" review.pass-timeout 900 3)" \
  "newer session override wins"

export DEX_SESSION_ID="$SESSION"
export DEX_LOOP_PHASE=6
dx_override_set "$SESSION" watch.command-timeout 75 session - agent \
  "Repository API calls are slow" 0
dx_override_set "$SESSION" complete.max-cycles 8 phase 6 agent \
  "Give reviewers a longer response window" 0
dx_override_set "$SESSION" complete.wait-minutes 2 phase 6 human \
  "Check the expedited pull request more often" 0
assert_eq "75" "$(dx_watch_command_timeout_seconds "$SESSION")" \
  "watch command accessor"
assert_eq "8" "$(dx_complete_max_cycles "$SESSION")" \
  "completion cycle accessor"
assert_eq "2" "$(dx_complete_wait_minutes "$SESSION")" \
  "completion wait accessor"
dx_override_set "$SESSION" complete.ci-fix-attempts 5 phase 6 agent \
  "Allow another CI repair approach" 0
assert_eq "5" "$(dx_complete_ci_fix_attempts "$SESSION")" \
  "completion CI repair accessor"
dx_override_set "$SESSION" phase.min-audits 4 phase 2 agent \
  "Require more evidence for implementation" 0
assert_eq "4" "$(dx_lifecycle_phase_min_audits 2)" \
  "phase audit accessor"
unset DEX_LOOP_PHASE

export DEX_LOOP_PHASE=2
dx_override_set "$SESSION" failure.attempts-per-strategy 4 phase 2 agent \
  "One extra diagnostic attempt is cheap" 0
dx_override_set "$SESSION" failure.max-strategies 3 phase 2 human \
  "Try the isolated implementation path too" 0
assert_eq "4" "$(dx_failure_attempts_per_strategy "$SESSION")" \
  "failure attempts accessor"
assert_eq "3" "$(dx_failure_max_strategies "$SESSION")" \
  "failure strategies accessor"
unset DEX_LOOP_PHASE

dx_override_set "$SESSION" loop.max-iterations 50 phase 2 agent \
  "The generated migration needs more audit turns" "$((NOW + 60))"
assert_eq "50" "$(dx_override_effective "$SESSION" loop.max-iterations 30 2)" \
  "unexpired override"
dx_override_set "$SESSION" loop.stall-timeout 1 phase 2 agent \
  "Expired fixture" "$((NOW - 1))"
assert_eq "300" "$(dx_override_effective "$SESSION" loop.stall-timeout 300 2)" \
  "expired override"

dx_override_clear "$SESSION" review.pass-timeout session - agent \
  "Return to the phase-specific value"
assert_eq "2400" "$(dx_override_effective "$SESSION" review.pass-timeout 900 3)" \
  "clearing the newer session override reveals phase policy"

ACTIVE="$(dx_override_list "$SESSION" 3)"
[[ "$ACTIVE" == *$'review.pass-timeout\t2400\tphase\t3\tagent\t'* ]] || \
  assert_at $LINENO
[[ "$ACTIVE" != *"Expired fixture"* ]] || assert_at $LINENO

assert_rejected "$LINENO" dx_override_set "$SESSION" 'bad gate' 1 phase 2 \
  agent "Invalid identifier" 0
assert_rejected "$LINENO" dx_override_set "$SESSION" loop.max-iterations 40 \
  phase 2 agent $'multi\nline' 0
assert_rejected "$LINENO" dx_override_set "$SESSION" loop.max-iterations 40 \
  phase 2 robot "Invalid source" 0
assert_rejected "$LINENO" dx_override_set "$SESSION" loop.max-iterations many \
  phase 2 agent "Invalid known numeric gate" 0
assert_rejected "$LINENO" dx_override_set "$SESSION" maintain.max-surfaces 0 \
  session - agent "Positive maintenance limit required" 0
assert_rejected "$LINENO" dx_override_set "$SESSION" guard.project-policy bypass \
  session - human "Unknown guard disposition" 0
assert_rejected "$LINENO" dx_override_set "$SESSION" unsupported.imaginary-gate 1 \
  session - agent "This gate has no runtime consumer" 0
assert_rejected "$LINENO" dx_override_clear "$SESSION" unsupported.imaginary-gate \
  session - agent "This gate has no runtime consumer"

# Waivers remain in the append-only journal for attribution but are not live
# values. A waiver also retires an older phase override for the same gate.
dx_override_waive "$SESSION" review.clean-passes 3 human \
  "Independent review is unavailable for this scope"
assert_eq "6" "$(dx_override_effective "$SESSION" review.clean-passes 6 3)" \
  "waiver is not an operational clean-pass value"
grep -Fq $'waive\treview.clean-passes\twaived\tphase\t3\thuman\t0\tIndependent review is unavailable for this scope' \
  "$(dx_override_file "$SESSION")" || assert_at $LINENO
assert_rejected "$LINENO" dx_override_waive "$SESSION" \
  unsupported.imaginary-gate 3 human "Unknown waiver target"

# Concurrent writers must not lose one another. Each writes a separate gate so
# the final active inventory should contain all of them.
writer_pids=""
for writer in 1 2 3 4 5 6 7 8; do
  (
    dx_override_set "$SESSION" "guard.writer-${writer}" allow session - \
      agent "Concurrent writer ${writer}" 0
  ) &
  writer_pids="${writer_pids} $!"
done
for writer_pid in $writer_pids; do
  wait "$writer_pid"
done
ACTIVE="$(dx_override_list "$SESSION" 3)"
for writer in 1 2 3 4 5 6 7 8; do
  [[ "$ACTIVE" == *$"guard.writer-${writer}"$'\tallow\t'* ]] || \
    assert_at $LINENO
done

OVERRIDE_FILE="$(dx_override_file "$SESSION")"
[[ "$(dx_path_mode "$OVERRIDE_FILE")" == "600" ]] || assert_at $LINENO

# Unsafe state never becomes policy. A symlinked override journal is rejected
# by both readers and writers.
UNSAFE_SESSION="repo-override-policy-unsafe"
ln -s /dev/null "$(dx_override_file "$UNSAFE_SESSION")"
assert_rejected "$LINENO" dx_override_effective "$UNSAFE_SESSION" \
  session.timeout 86400 2
assert_rejected "$LINENO" dx_override_set "$UNSAFE_SESSION" session.timeout 0 \
  session - agent "Disable the session deadline" 0

printf 'override policy tests passed\n'
