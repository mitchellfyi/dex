#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-standalone-provider-test.XXXXXX")"
TEST_CHILD_PIDS=""

cleanup() {
  local child_pid
  for child_pid in $TEST_CHILD_PIDS; do
    kill "$child_pid" 2>/dev/null || true
    wait "$child_pid" 2>/dev/null || true
  done
  chmod -R u+w "$TMP_DIR" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

forget_test_child() {
  local completed_pid="$1" child_pid remaining=""
  for child_pid in $TEST_CHILD_PIDS; do
    [[ "$child_pid" == "$completed_pid" ]] && continue
    remaining="${remaining} ${child_pid}"
  done
  TEST_CHILD_PIDS="$remaining"
}

wait_for_test_file() {
  local target="$1" _attempt
  for _attempt in {1..500}; do
    [[ -f "$target" ]] && return 0
    sleep 0.01
  done
  return 1
}

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
export DX_TOOL_DIR="$TMP_DIR/tools"
export DX_RUN_ROOT="$TMP_DIR/runs"
export TEST_REPO="$TMP_DIR/repo"
export TEST_ROUTE_FILE="$TMP_DIR/routes.log"
export TEST_PROMPT_FILE="$TMP_DIR/prompt.txt"
export TEST_RECEIPT_LOG="$TMP_DIR/receipt.log"
export TEST_CONTEXT_LOG="$TMP_DIR/context.log"
export TEST_STALE_RECEIPT_FILE="$TMP_DIR/stale-receipt.tsv"
export TEST_DECISION_LOCK_ATTEMPT="$TMP_DIR/decision-lock-attempt"
export TEST_DECISION_LOCK_RELEASE="$TMP_DIR/decision-lock-release"
export TEST_CONSUME_ATTEMPT="$TMP_DIR/consume-attempt"
export PATH="$TMP_DIR/bin:/usr/bin:/bin"
mkdir -p "$HOME" "$TMP_DIR/bin" "$TEST_REPO"
: > "$TEST_RECEIPT_LOG"
: > "$TEST_CONTEXT_LOG"

git -C "$TEST_REPO" init -q
git -C "$TEST_REPO" config user.email dex@example.test
git -C "$TEST_REPO" config user.name "Dex Test"
printf '# repo\n' > "$TEST_REPO/README.md"
git -C "$TEST_REPO" add README.md
git -C "$TEST_REPO" commit -q -m init
git -C "$TEST_REPO" branch -m main

# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
DXCOMPLETE_SESSION_ID=$(cd "$TEST_REPO" && dx_session_id)

cat > "$TMP_DIR/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
  printf '%s\n' "17"
  exit 0
fi
printf 'unexpected gh invocation: %s\n' "$*" >&2
exit 2
SH
chmod +x "$TMP_DIR/bin/gh"

cat > "$TMP_DIR/provider-receipt.sh" <<'SH'
#!/usr/bin/env bash

extract_completion_literal() {
  python3 - "$@" <<'PY'
import re
import sys

pattern = re.compile(
    r'bash "\$DEX_DIR/bin/complete-receipt\.sh" '
    r'"([A-Za-z0-9][A-Za-z0-9._-]{0,179})" "([0-9a-f]{32})"'
)
matches = []
for value in sys.argv[1:]:
    matches.extend(pattern.findall(value))
if len(matches) != 1:
    raise SystemExit(1)
print(f"{matches[0][0]}\t{matches[0][1]}")
PY
}

extract_assessment_generation() {
  python3 - "$@" <<'PY'
import json
import re
import sys

matches = []
for value in sys.argv[1:]:
    for candidate in re.findall(r'\{[^\n]*"completion_generation"[^\n]*\}', value):
        try:
            record = json.loads(candidate)
        except (TypeError, ValueError):
            continue
        generation = record.get("completion_generation")
        if isinstance(generation, str) and re.fullmatch(r"[0-9a-f]{32}", generation):
            matches.append(generation)
if len(matches) != 1:
    raise SystemExit(1)
print(matches[0])
PY
}

assert_completion_context() { # <session> <generation> <purpose> <phase>
  local session_id="$1" generation="$2" expected_purpose="$3" expected_phase="$4"
  local config_file config_raw config_phase config_promise config_audit config_min
  local config_mode config_purpose config_generation
  config_file=$(dx_loop_config_file "$session_id")
  config_raw=$(cat "$config_file")
  IFS=: read -r config_phase config_promise config_audit config_min \
    config_mode config_purpose config_generation <<< "$config_raw"
  if [[ "$config_mode" != "standalone" || \
        "$config_purpose" != "$expected_purpose" || \
        "$config_phase" != "$expected_phase" || \
        "$config_generation" != "$generation" ]]; then
    printf 'completion context did not match the launch command: %s\n' "$config_raw" >&2
    return 1
  fi
  printf '%s\t%s\t%s\n' "$config_purpose" "$config_phase" "$config_generation" \
    >> "$TEST_CONTEXT_LOG"
}

remove_exact_receipt() { # <session> <generation>
  local receipt_file
  receipt_file=$(dx_completion_receipt_file "$1" "$2")
  rm -f "$receipt_file"
}

perform_completion_action() { # <action> <purpose> <phase> <provider args...>
  local action="$1" expected_purpose="$2" expected_phase="$3"
  local literal session_id generation replacement_generation wrong_generation
  shift 3
  literal=$(extract_completion_literal "$@") || {
    printf '%s\n' "provider launch did not contain exactly one completion command" >&2
    return 1
  }
  IFS=$'\t' read -r session_id generation <<< "$literal"
  printf 'bash "$DEX_DIR/bin/complete-receipt.sh" "%s" "%s"\n' \
    "$session_id" "$generation" \
    >> "$TEST_RECEIPT_LOG"
  printf '%s\t%s\n' "$session_id" "$generation" >> "${TEST_RECEIPT_LOG}.tsv"
  assert_completion_context "$session_id" "$generation" "$expected_purpose" "$expected_phase"

  # Every fixture starts by running the exact command carried in its prompt.
  # Failure cases then revoke or replace that receipt to model delayed, stale,
  # or conflicting provider output without looking up the current generation.
  bash "$DEX_DIR/bin/complete-receipt.sh" "$session_id" "$generation"
  case "$action" in
    complete) ;;
    paused)
      remove_exact_receipt "$session_id" "$generation"
      dx_write_pause_state "$session_id" provider-paused test-provider
      dx_lifecycle_atomic_write "$(dx_paused_file "$session_id")" paused
      ;;
    human-pause)
      remove_exact_receipt "$session_id" "$generation"
      dx_write_lifecycle_control "$session_id" pause "" terminal "" \
        "$expected_phase" ""
      ;;
    human-pause-dir)
      remove_exact_receipt "$session_id" "$generation"
      mkdir "$(dx_paused_file "$session_id")"
      dx_write_lifecycle_control "$session_id" pause "" terminal "" \
        "$expected_phase" ""
      ;;
    both)
      dx_write_pause_state "$session_id" provider-paused test-provider
      dx_lifecycle_atomic_write "$(dx_paused_file "$session_id")" paused
      ;;
    missing)
      remove_exact_receipt "$session_id" "$generation"
      ;;
    max)
      remove_exact_receipt "$session_id" "$generation"
      printf '%s\n' "30" > "$(dx_loop_file "$session_id")"
      ;;
    legacy)
      remove_exact_receipt "$session_id" "$generation"
      touch "$(dx_complete_file "$session_id")"
      ;;
    corrupt-legacy)
      remove_exact_receipt "$session_id" "$generation"
      printf '%s:LEGACY_PROMISE::1\n' "$expected_phase" \
        > "$(dx_loop_config_file "$session_id")"
      touch "$(dx_complete_file "$session_id")"
      ;;
    wrong-generation)
      remove_exact_receipt "$session_id" "$generation"
      if [[ "${generation:31:1}" == "0" ]]; then
        wrong_generation="${generation:0:31}1"
      else
        wrong_generation="${generation:0:31}0"
      fi
      dx_completion_write_receipt "$session_id" "$wrong_generation" 2>/dev/null || true
      ;;
    wrong-context)
      replacement_generation=$(dx_completion_issue "$session_id" standalone dxloop-plan 1)
      dx_completion_write_receipt "$session_id" "$replacement_generation"
      ;;
    replay)
      remove_exact_receipt "$session_id" "$generation"
      if [[ -s "$TEST_STALE_RECEIPT_FILE" ]]; then
        IFS=$'\t' read -r session_id generation < "$TEST_STALE_RECEIPT_FILE"
        dx_completion_write_receipt "$session_id" "$generation" 2>/dev/null || true
      fi
      ;;
    lost-active)
      rm -f "$(dx_active_file "$session_id")"
      ;;
    *)
      printf 'unknown completion fixture action: %s\n' "$action" >&2
      return 2
      ;;
  esac
}
SH

cat > "$TMP_DIR/bin/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "login" && "${2:-}" == "status" ]]; then
  printf '%s\n' "Logged in with ChatGPT"
  exit 0
fi
if [[ "${1:-}" == "exec" && "${2:-}" == "--help" ]]; then
  printf '%s\n' "--ignore-user-config"
  printf '%s\n' "--dangerously-bypass-approvals-and-sandbox"
  exit 0
fi
if [[ "${1:-}" == "exec" && "${2:-}" == "review" && "${3:-}" == "--help" ]]; then
  printf '%s\n' "--ignore-user-config"
  printf '%s\n' "--dangerously-bypass-approvals-and-sandbox"
  exit 0
fi
if [[ "${1:-}" == "exec" ]]; then
  printf '%s\n' "codex" >> "$TEST_ROUTE_FILE"
  printf '%s\n' "${*: -1}" > "$TEST_PROMPT_FILE"
  # shellcheck disable=SC1091
  source "$DEX_DIR/lib/common.sh"
  # shellcheck disable=SC1091
  source "$TEST_PROVIDER_HELPER"
  perform_completion_action "${TEST_CODEX_RECEIPT:-missing}" dxcomplete 6 "$@"
  if [[ -n "${TEST_CODEX_HOLD_READY:-}" ]]; then
    touch "$TEST_CODEX_HOLD_READY"
    while [[ ! -f "${TEST_CODEX_HOLD_RELEASE:?}" ]]; do
      sleep 0.01
    done
  fi
  exit 0
fi
exit 0
SH
chmod +x "$TMP_DIR/bin/codex"
export TEST_PROVIDER_HELPER="$TMP_DIR/provider-receipt.sh"

run_expect_failure() { # <output> <command...>
  local output_file="$1"
  shift
  if "$@" > "$output_file" 2>&1; then
    printf 'expected command to fail: %s\n' "$*" >&2
    cat "$output_file" >&2
    exit 1
  fi
}

assert_completion_authority_clean() { # <session>
  local session_id="$1" stale_receipts
  assert_no_file "$(dx_completion_expectation_file "$session_id")"
  assert_no_file "$(dx_loop_config_file "$session_id")"
  assert_no_file "$(dx_complete_file "$session_id")"
  assert_no_file "$(dx_active_file "$session_id")"
  assert_no_file "$(dx_owner_file "$session_id")"
  assert_no_file "$(dx_loop_file "$session_id")"
  assert_no_file "$(dx_paused_file "$session_id")"
  assert_no_file "$(dx_pause_state_file "$session_id")"
  assert_no_file "$(dx_lifecycle_control_file "$session_id")"
  assert_no_file "$(dx_handoff_mode_file "$session_id")"
  stale_receipts=$(find "$DX_LOOP_DIR" -type f \
    -name "${session_id}.completion-receipt.*" -print 2>/dev/null || true)
  if [[ -n "$stale_receipts" ]]; then
    printf 'completion receipts survived cleanup for %s:\n%s\n' \
      "$session_id" "$stale_receipts" >&2
    exit 1
  fi
}

assert_no_live_completion_authority() {
  local live_files
  live_files=$(find "$DX_LOOP_DIR" -type f \
    \( -name '*.completion-expectation' -o -name '*.completion-receipt.*' \) \
    -print 2>/dev/null || true)
  if [[ -n "$live_files" ]]; then
    printf 'standalone completion authority survived cleanup:\n%s\n' "$live_files" >&2
    exit 1
  fi
}

assert_no_standalone_runtime_files() {
  local live_files
  live_files=$(find "$DX_LOOP_DIR" -type f \
    \( -name '*.active' -o -name '*.config' -o -name '*.loop' -o \
       -name '*.paused' -o -name '*.pause-state' -o -name '*.control' -o \
       -name '*.complete' -o -name '*.prompt' -o -name '*.owner' \) \
    -print 2>/dev/null || true)
  if [[ -n "$live_files" ]]; then
    printf 'standalone runtime files survived cleanup:\n%s\n' "$live_files" >&2
    exit 1
  fi
}

# dxloop and dxrefine require interactive Claude-only primitives. A resolved
# Codex profile must explain that contract before looking for ambient Claude.
run_expect_failure "$TMP_DIR/dxloop-codex.out" \
  env DX_PROVIDER_PROFILE=codex-subscription zsh -fc \
  'source "$DEX_DIR/dx.sh"; cd "$TEST_REPO"; dxloop "implement the change"'
grep -Fq "dxloop requires an interactive Claude Code session" "$TMP_DIR/dxloop-codex.out"
if grep -Fq "Claude Code CLI not found" "$TMP_DIR/dxloop-codex.out"; then
  printf '%s\n' "dxloop reported ambient Claude detection instead of provider compatibility" >&2
  exit 1
fi

run_expect_failure "$TMP_DIR/dxrefine-codex.out" \
  env DX_PROVIDER_PROFILE=codex-subscription zsh -fc \
  'source "$DEX_DIR/dx.sh"; cd "$TEST_REPO"; dxrefine "split this effort"'
grep -Fq "dxrefine requires an interactive Claude Code session" "$TMP_DIR/dxrefine-codex.out"
if grep -Fq "Claude Code CLI not found" "$TMP_DIR/dxrefine-codex.out"; then
  printf '%s\n' "dxrefine reported ambient Claude detection instead of provider compatibility" >&2
  exit 1
fi

# Direct Codex accepts only the generation-bound receipt from its launch
# prompt. Every rejected result must revoke its outstanding authorization.
: > "$TEST_ROUTE_FILE"
: > "$TEST_RECEIPT_LOG"
: > "${TEST_RECEIPT_LOG}.tsv"
: > "$TEST_CONTEXT_LOG"
TEST_CODEX_RECEIPT=complete DX_PROVIDER_PROFILE=codex-subscription \
  zsh -fc 'source "$DEX_DIR/dx.sh"; cd "$TEST_REPO"; dxcomplete' \
  > "$TMP_DIR/dxcomplete-codex-complete.out" 2>&1
assert_eq "codex" "$(cat "$TEST_ROUTE_FILE")" "direct dxcomplete provider route"
assert_contains "Direct Codex completion contract" "$TEST_PROMPT_FILE"
assert_contains "dxcomplete finished" "$TMP_DIR/dxcomplete-codex-complete.out"
assert_eq "1" "$(wc -l < "$TEST_RECEIPT_LOG" | tr -d '[:space:]')" \
  "dxcomplete completion command count"
DXCOMPLETE_COMMAND=$(head -n 1 "$TEST_RECEIPT_LOG")
assert_contains "$DXCOMPLETE_COMMAND" "$TEST_PROMPT_FILE"
assert_not_contains "dx_completion_current_generation" "$TEST_PROMPT_FILE"
assert_eq "dxcomplete" "$(cut -f1 "$TEST_CONTEXT_LOG")" \
  "dxcomplete standalone purpose"
head -n 1 "${TEST_RECEIPT_LOG}.tsv" > "$TEST_STALE_RECEIPT_FILE"
assert_completion_authority_clean "$DXCOMPLETE_SESSION_ID"

run_expect_failure "$TMP_DIR/dxcomplete-codex-paused.out" \
  env TEST_CODEX_RECEIPT=paused DX_PROVIDER_PROFILE=codex-subscription \
  zsh -fc 'source "$DEX_DIR/dx.sh"; cd "$TEST_REPO"; dxcomplete'
assert_contains "dxcomplete paused before completion" "$TMP_DIR/dxcomplete-codex-paused.out"
assert_completion_authority_clean "$DXCOMPLETE_SESSION_ID"

run_expect_failure "$TMP_DIR/dxcomplete-codex-missing.out" \
  env TEST_CODEX_RECEIPT=missing DX_PROVIDER_PROFILE=codex-subscription \
  zsh -fc 'source "$DEX_DIR/dx.sh"; cd "$TEST_REPO"; dxcomplete'
assert_contains "provider exited without a completion receipt" "$TMP_DIR/dxcomplete-codex-missing.out"
assert_completion_authority_clean "$DXCOMPLETE_SESSION_ID"

run_expect_failure "$TMP_DIR/dxcomplete-codex-wrong-generation.out" \
  env TEST_CODEX_RECEIPT=wrong-generation DX_PROVIDER_PROFILE=codex-subscription \
  zsh -fc 'source "$DEX_DIR/dx.sh"; cd "$TEST_REPO"; dxcomplete'
assert_contains "provider exited without a completion receipt" \
  "$TMP_DIR/dxcomplete-codex-wrong-generation.out"
assert_completion_authority_clean "$DXCOMPLETE_SESSION_ID"

run_expect_failure "$TMP_DIR/dxcomplete-codex-wrong-context.out" \
  env TEST_CODEX_RECEIPT=wrong-context DX_PROVIDER_PROFILE=codex-subscription \
  zsh -fc 'source "$DEX_DIR/dx.sh"; cd "$TEST_REPO"; dxcomplete'
assert_contains "provider exited without a completion receipt" \
  "$TMP_DIR/dxcomplete-codex-wrong-context.out"
assert_completion_authority_clean "$DXCOMPLETE_SESSION_ID"

run_expect_failure "$TMP_DIR/dxcomplete-codex-legacy.out" \
  env TEST_CODEX_RECEIPT=legacy DX_PROVIDER_PROFILE=codex-subscription \
  zsh -fc 'source "$DEX_DIR/dx.sh"; cd "$TEST_REPO"; dxcomplete'
assert_contains "ignored a legacy .complete marker" "$TMP_DIR/dxcomplete-codex-legacy.out"
assert_eq "1" \
  "$(grep -Fc "ignored a legacy .complete marker" "$TMP_DIR/dxcomplete-codex-legacy.out")" \
  "legacy marker diagnostic count"
assert_completion_authority_clean "$DXCOMPLETE_SESSION_ID"

run_expect_failure "$TMP_DIR/dxcomplete-codex-replay.out" \
  env TEST_CODEX_RECEIPT=replay DX_PROVIDER_PROFILE=codex-subscription \
  zsh -fc 'source "$DEX_DIR/dx.sh"; cd "$TEST_REPO"; dxcomplete'
assert_contains "provider exited without a completion receipt" \
  "$TMP_DIR/dxcomplete-codex-replay.out"
assert_eq "$(cut -f2 "$TEST_STALE_RECEIPT_FILE")" \
  "$(cut -f3 "$TEST_CONTEXT_LOG" | sed -n '1p')" \
  "saved stale generation"
if [[ "$(cut -f2 "$TEST_STALE_RECEIPT_FILE")" == \
      "$(cut -f3 "$TEST_CONTEXT_LOG" | tail -n 1)" ]]; then
  printf '%s\n' "dxcomplete reused a generation on retry" >&2
  exit 1
fi
assert_completion_authority_clean "$DXCOMPLETE_SESSION_ID"

run_expect_failure "$TMP_DIR/dxcomplete-codex-pause-wins.out" \
  env TEST_CODEX_RECEIPT=both DX_PROVIDER_PROFILE=codex-subscription \
  zsh -fc 'source "$DEX_DIR/dx.sh"; cd "$TEST_REPO"; dxcomplete'
assert_contains "dxcomplete paused before completion" \
  "$TMP_DIR/dxcomplete-codex-pause-wins.out"
assert_completion_authority_clean "$DXCOMPLETE_SESSION_ID"
assert_eq "8" "$(wc -l < "$TEST_CONTEXT_LOG" | tr -d '[:space:]')" \
  "direct dxcomplete launch count"
assert_eq "8" \
  "$(cut -f3 "$TEST_CONTEXT_LOG" | sort -u | wc -l | tr -d '[:space:]')" \
  "fresh dxcomplete generation per launch"

# The direct provider returns before its wrapper decides whether to accept the
# receipt. Hold that decision at the lifecycle lock, publish a human pause,
# then release it. The committed control must be observed before consumption.
rm -f "$TEST_DECISION_LOCK_ATTEMPT" "$TEST_DECISION_LOCK_RELEASE" \
  "$TEST_CONSUME_ATTEMPT" "$TMP_DIR/dxcomplete-control-race.rc"
(
  set +e
  TEST_CODEX_RECEIPT=complete DX_PROVIDER_PROFILE=codex-subscription \
    zsh -fc '
      source "$DEX_DIR/dx.sh"
      TEST_CONTROL_LOCK_CALLS=0
      functions[__test_real_control_lock_acquire]="${functions[dx_lifecycle_control_lock_acquire]}"
      functions[__test_real_control_lock_release]="${functions[dx_lifecycle_control_lock_release]}"
      dx_lifecycle_control_lock_acquire() {
        TEST_CONTROL_LOCK_CALLS=$((TEST_CONTROL_LOCK_CALLS + 1))
        if [[ "$TEST_CONTROL_LOCK_CALLS" -eq 1 ]]; then
          __test_real_control_lock_acquire "$@"
          return $?
        fi
        touch "$TEST_DECISION_LOCK_ATTEMPT"
        while [[ ! -f "$TEST_DECISION_LOCK_RELEASE" ]]; do
          sleep 0.01
        done
        __test_real_control_lock_acquire "$@"
      }
      dx_lifecycle_control_lock_release() {
        __test_real_control_lock_release "$@"
      }
      dx_completion_consume() {
        touch "$TEST_CONSUME_ATTEMPT"
        return 97
      }
      cd "$TEST_REPO"
      dxcomplete
    ' > "$TMP_DIR/dxcomplete-control-race.out" 2>&1
  printf '%s\n' "$?" > "$TMP_DIR/dxcomplete-control-race.rc"
) &
CONTROL_RACE_PID=$!
TEST_CHILD_PIDS="${TEST_CHILD_PIDS} ${CONTROL_RACE_PID}"
if ! wait_for_test_file "$TEST_DECISION_LOCK_ATTEMPT"; then
  printf '%s\n' "direct dxcomplete never reached its post-provider decision lock" >&2
  sed -n '1,160p' "$TMP_DIR/dxcomplete-control-race.out" >&2 || true
  exit 1
fi
assert_no_file "$TEST_CONSUME_ATTEMPT"
assert_no_file "$TMP_DIR/dxcomplete-control-race.rc"
dx_write_lifecycle_control "$DXCOMPLETE_SESSION_ID" pause "" terminal "" 6 ""
touch "$TEST_DECISION_LOCK_RELEASE"
wait "$CONTROL_RACE_PID"
forget_test_child "$CONTROL_RACE_PID"
assert_eq "1" "$(cat "$TMP_DIR/dxcomplete-control-race.rc")" \
  "human control wins direct dxcomplete race"
assert_no_file "$TEST_CONSUME_ATTEMPT"
assert_contains "dxcomplete paused before completion" \
  "$TMP_DIR/dxcomplete-control-race.out"
assert_completion_authority_clean "$DXCOMPLETE_SESSION_ID"
assert_no_file "$(dx_lifecycle_control_file "$DXCOMPLETE_SESSION_ID")"
assert_no_file "$(dx_pause_state_file "$DXCOMPLETE_SESSION_ID")"
TEST_CODEX_RECEIPT=complete DX_PROVIDER_PROFILE=codex-subscription \
  zsh -fc 'source "$DEX_DIR/dx.sh"; cd "$TEST_REPO"; dxcomplete' \
  > "$TMP_DIR/dxcomplete-after-control-pause.out" 2>&1
assert_contains "dxcomplete finished" "$TMP_DIR/dxcomplete-after-control-pause.out"
assert_completion_authority_clean "$DXCOMPLETE_SESSION_ID"

# A lock owner that commits before activation prevents dxcomplete from
# publishing any context or launching a provider.
: > "$TEST_ROUTE_FILE"
dx_lifecycle_control_lock_acquire "$DXCOMPLETE_SESSION_ID"
run_expect_failure "$TMP_DIR/dxcomplete-activation-lock-busy.out" \
  env TEST_CODEX_RECEIPT=complete DX_PROVIDER_PROFILE=codex-subscription \
  DEX_LIFECYCLE_CONTROL_LOCK_ATTEMPTS=1 \
  zsh -fc 'source "$DEX_DIR/dx.sh"; cd "$TEST_REPO"; dxcomplete'
dx_lifecycle_control_lock_release "$DXCOMPLETE_SESSION_ID"
assert_contains "Could not lock the dxcomplete launch state" \
  "$TMP_DIR/dxcomplete-activation-lock-busy.out"
assert_eq "" "$(cat "$TEST_ROUTE_FILE")" "busy activation provider route"
assert_completion_authority_clean "$DXCOMPLETE_SESSION_ID"

# A malformed control path still owns the launch decision. Treating an empty
# parse as absence would let dxcomplete overwrite a pending human intervention.
: > "$TEST_ROUTE_FILE"
printf '%s\n' keep > "$TMP_DIR/invalid-control-target"
ln -s "$TMP_DIR/invalid-control-target" \
  "$(dx_lifecycle_control_file "$DXCOMPLETE_SESSION_ID")"
run_expect_failure "$TMP_DIR/dxcomplete-control-symlink.out" \
  env TEST_CODEX_RECEIPT=complete DX_PROVIDER_PROFILE=codex-subscription \
  zsh -fc 'source "$DEX_DIR/dx.sh"; cd "$TEST_REPO"; dxcomplete'
assert_contains "already owns this checkout" \
  "$TMP_DIR/dxcomplete-control-symlink.out"
assert_eq "" "$(cat "$TEST_ROUTE_FILE")" "control symlink provider route"
assert_eq "keep" "$(cat "$TMP_DIR/invalid-control-target")" \
  "control symlink target"
rm -f "$(dx_lifecycle_control_file "$DXCOMPLETE_SESSION_ID")"
assert_completion_authority_clean "$DXCOMPLETE_SESSION_ID"

mkdir "$(dx_lifecycle_control_file "$DXCOMPLETE_SESSION_ID")"
run_expect_failure "$TMP_DIR/dxcomplete-control-directory.out" \
  env TEST_CODEX_RECEIPT=complete DX_PROVIDER_PROFILE=codex-subscription \
  zsh -fc 'source "$DEX_DIR/dx.sh"; cd "$TEST_REPO"; dxcomplete'
assert_contains "already owns this checkout" \
  "$TMP_DIR/dxcomplete-control-directory.out"
assert_eq "" "$(cat "$TEST_ROUTE_FILE")" "control directory provider route"
rmdir "$(dx_lifecycle_control_file "$DXCOMPLETE_SESSION_ID")"
assert_completion_authority_clean "$DXCOMPLETE_SESSION_ID"

# Path-derived dxcomplete must not seize a lifecycle even when only part of
# its durable identity survived a crash.
LIFECYCLE_GENERATION=$(dx_completion_issue \
  "$DXCOMPLETE_SESSION_ID" lifecycle phase 2)
printf '2\n' > "$(dx_state_file "$DXCOMPLETE_SESSION_ID")"
printf 'inline\n' > "$(dx_handoff_mode_file "$DXCOMPLETE_SESSION_ID")"
printf '2:PHASE_2_COMPLETE:%s/prompts/phase-audits/2-implement.md:1:lifecycle:phase:%s\n' \
  "$ROOT" "$LIFECYCLE_GENERATION" \
  > "$(dx_loop_config_file "$DXCOMPLETE_SESSION_ID")"
touch "$(dx_active_file "$DXCOMPLETE_SESSION_ID")"
run_expect_failure "$TMP_DIR/dxcomplete-active-lifecycle.out" \
  env TEST_CODEX_RECEIPT=complete DX_PROVIDER_PROFILE=codex-subscription \
  zsh -fc 'source "$DEX_DIR/dx.sh"; cd "$TEST_REPO"; dxcomplete'
assert_contains "already owns this checkout" \
  "$TMP_DIR/dxcomplete-active-lifecycle.out"
assert_eq "$LIFECYCLE_GENERATION" \
  "$(dx_completion_current_generation \
    "$DXCOMPLETE_SESSION_ID" lifecycle phase 2)" \
  "active lifecycle generation"
dx_completion_cleanup "$DXCOMPLETE_SESSION_ID"
rm -f "$(dx_active_file "$DXCOMPLETE_SESSION_ID")" \
  "$(dx_loop_config_file "$DXCOMPLETE_SESSION_ID")" \
  "$(dx_handoff_mode_file "$DXCOMPLETE_SESSION_ID")"

run_expect_failure "$TMP_DIR/dxcomplete-state-only.out" \
  env TEST_CODEX_RECEIPT=complete DX_PROVIDER_PROFILE=codex-subscription \
  zsh -fc 'source "$DEX_DIR/dx.sh"; cd "$TEST_REPO"; dxcomplete'
assert_contains "already owns this checkout" "$TMP_DIR/dxcomplete-state-only.out"
rm -f "$(dx_state_file "$DXCOMPLETE_SESSION_ID")"
printf 'inline\n' > "$(dx_handoff_mode_file "$DXCOMPLETE_SESSION_ID")"
run_expect_failure "$TMP_DIR/dxcomplete-handoff-only.out" \
  env TEST_CODEX_RECEIPT=complete DX_PROVIDER_PROFILE=codex-subscription \
  zsh -fc 'source "$DEX_DIR/dx.sh"; cd "$TEST_REPO"; dxcomplete'
assert_contains "already owns this checkout" "$TMP_DIR/dxcomplete-handoff-only.out"
rm -f "$(dx_handoff_mode_file "$DXCOMPLETE_SESSION_ID")"

# The first launch owns its exact config before the provider runs. A second
# launch in the same checkout is rejected instead of rotating that generation.
: > "$TEST_ROUTE_FILE"
rm -f "$TMP_DIR/dxcomplete-concurrent.ready" \
  "$TMP_DIR/dxcomplete-concurrent.release" "$TMP_DIR/dxcomplete-concurrent.rc"
(
  set +e
  TEST_CODEX_RECEIPT=complete DX_PROVIDER_PROFILE=codex-subscription \
  TEST_CODEX_HOLD_READY="$TMP_DIR/dxcomplete-concurrent.ready" \
  TEST_CODEX_HOLD_RELEASE="$TMP_DIR/dxcomplete-concurrent.release" \
    zsh -fc 'source "$DEX_DIR/dx.sh"; cd "$TEST_REPO"; dxcomplete' \
    > "$TMP_DIR/dxcomplete-concurrent-first.out" 2>&1
  printf '%s\n' "$?" > "$TMP_DIR/dxcomplete-concurrent.rc"
) &
CONCURRENT_PID=$!
TEST_CHILD_PIDS="${TEST_CHILD_PIDS} ${CONCURRENT_PID}"
wait_for_test_file "$TMP_DIR/dxcomplete-concurrent.ready"
assert_no_file "$(dx_active_file "$DXCOMPLETE_SESSION_ID")"
run_expect_failure "$TMP_DIR/dxcomplete-concurrent-second.out" \
  env TEST_CODEX_RECEIPT=complete DX_PROVIDER_PROFILE=codex-subscription \
  zsh -fc 'source "$DEX_DIR/dx.sh"; cd "$TEST_REPO"; dxcomplete'
assert_contains "already owns this checkout" \
  "$TMP_DIR/dxcomplete-concurrent-second.out"
touch "$TMP_DIR/dxcomplete-concurrent.release"
wait "$CONCURRENT_PID"
forget_test_child "$CONCURRENT_PID"
assert_eq "0" "$(cat "$TMP_DIR/dxcomplete-concurrent.rc")" \
  "first concurrent dxcomplete result"
assert_eq "1" "$(grep -Fxc codex "$TEST_ROUTE_FILE")" \
  "concurrent dxcomplete provider count"
assert_completion_authority_clean "$DXCOMPLETE_SESSION_ID"

# A malformed control can arrive while the provider runs. The terminal
# decision observes the path under lock, rejects success, and removes only the
# symlink rather than touching its target.
: > "$TEST_ROUTE_FILE"
rm -f "$TMP_DIR/dxcomplete-invalid-control.ready" \
  "$TMP_DIR/dxcomplete-invalid-control.release" \
  "$TMP_DIR/dxcomplete-invalid-control.rc"
(
  set +e
  TEST_CODEX_RECEIPT=complete DX_PROVIDER_PROFILE=codex-subscription \
  TEST_CODEX_HOLD_READY="$TMP_DIR/dxcomplete-invalid-control.ready" \
  TEST_CODEX_HOLD_RELEASE="$TMP_DIR/dxcomplete-invalid-control.release" \
    zsh -fc 'source "$DEX_DIR/dx.sh"; cd "$TEST_REPO"; dxcomplete' \
    > "$TMP_DIR/dxcomplete-invalid-control.out" 2>&1
  printf '%s\n' "$?" > "$TMP_DIR/dxcomplete-invalid-control.rc"
) &
INVALID_CONTROL_PID=$!
TEST_CHILD_PIDS="${TEST_CHILD_PIDS} ${INVALID_CONTROL_PID}"
wait_for_test_file "$TMP_DIR/dxcomplete-invalid-control.ready"
ln -s "$TMP_DIR/invalid-control-target" \
  "$(dx_lifecycle_control_file "$DXCOMPLETE_SESSION_ID")"
touch "$TMP_DIR/dxcomplete-invalid-control.release"
wait "$INVALID_CONTROL_PID"
forget_test_child "$INVALID_CONTROL_PID"
assert_eq "1" "$(cat "$TMP_DIR/dxcomplete-invalid-control.rc")" \
  "in-flight invalid control result"
assert_eq "1" "$(grep -Fxc codex "$TEST_ROUTE_FILE")" \
  "in-flight invalid control provider count"
assert_contains "dxcomplete paused before completion" \
  "$TMP_DIR/dxcomplete-invalid-control.out"
assert_eq "keep" "$(cat "$TMP_DIR/invalid-control-target")" \
  "in-flight control symlink target"
assert_completion_authority_clean "$DXCOMPLETE_SESSION_ID"

# No direct-Codex launch leaves a file activation that a bystander Stop could
# claim after the wrapper returns.
set +e
printf '{"session_id":"claude-bystander"}' | env \
  DEX_SESSION_ID="$DXCOMPLETE_SESSION_ID" DEX_LOOP_ACTIVE=0 \
  bash "$DEX_DIR/hooks/phase-loop.sh" \
  > "$TMP_DIR/dxcomplete-post-release-bystander.out" 2>&1
BYSTANDER_RC=$?
set -e
[[ "$BYSTANDER_RC" -eq 0 ]] || assert_at $LINENO
assert_no_file "$(dx_completion_expectation_file "$DXCOMPLETE_SESSION_ID")"

# A failed decision-lock release is also non-success. The wrapper deactivates
# and revokes before returning, so a later bystander cannot reauthorize it.
run_expect_failure "$TMP_DIR/dxcomplete-control-release-failure.out" \
  env TEST_CODEX_RECEIPT=complete DX_PROVIDER_PROFILE=codex-subscription \
  zsh -fc '
    source "$DEX_DIR/dx.sh"
    functions[__test_real_control_lock_acquire]="${functions[dx_lifecycle_control_lock_acquire]}"
    functions[__test_real_control_lock_release]="${functions[dx_lifecycle_control_lock_release]}"
    TEST_CONTROL_RELEASE_CALLS=0
    dx_lifecycle_control_lock_acquire() {
      __test_real_control_lock_acquire "$@"
    }
    dx_lifecycle_control_lock_release() {
      TEST_CONTROL_RELEASE_CALLS=$((TEST_CONTROL_RELEASE_CALLS + 1))
      if [[ "$TEST_CONTROL_RELEASE_CALLS" -eq 2 ]]; then
        return 1
      fi
      __test_real_control_lock_release "$@"
    }
    cd "$TEST_REPO"
    dxcomplete
  '
assert_contains "could not prove that completion authorization was revoked" \
  "$TMP_DIR/dxcomplete-control-release-failure.out"
assert_not_contains "dxcomplete finished" \
  "$TMP_DIR/dxcomplete-control-release-failure.out"
assert_no_file "$(dx_completion_expectation_file "$DXCOMPLETE_SESSION_ID")"
assert_no_file "$(dx_active_file "$DXCOMPLETE_SESSION_ID")"
assert_file "$(dx_paused_file "$DXCOMPLETE_SESSION_ID")"
printf '{"session_id":"claude-after-release-failure"}' | env \
  DEX_SESSION_ID="$DXCOMPLETE_SESSION_ID" DEX_LOOP_ACTIVE=0 \
  bash "$DEX_DIR/hooks/phase-loop.sh" \
  > "$TMP_DIR/dxcomplete-release-failure-bystander.out" 2>&1
assert_no_file "$(dx_completion_expectation_file "$DXCOMPLETE_SESSION_ID")"
dx_completion_cleanup "$DXCOMPLETE_SESSION_ID"
rm -f "$(dx_active_file "$DXCOMPLETE_SESSION_ID")" \
  "$(dx_owner_file "$DXCOMPLETE_SESSION_ID")" \
  "$(dx_loop_file "$DXCOMPLETE_SESSION_ID")" \
  "$(dx_loop_config_file "$DXCOMPLETE_SESSION_ID")" \
  "$(dx_complete_file "$DXCOMPLETE_SESSION_ID")" \
  "$(dx_paused_file "$DXCOMPLETE_SESSION_ID")" \
  "$(dx_pause_state_file "$DXCOMPLETE_SESSION_ID")" 2>/dev/null || true

# A finalizer that cannot acquire the transition lock must not revoke or
# delete state owned by the concurrent control operation.
FINALIZE_SESSION="standalone-finalize-lock"
FINALIZE_GENERATION=$(dx_completion_issue \
  "$FINALIZE_SESSION" standalone dxloop-plan 1)
printf '1:PHASE_1_COMPLETE:%s/prompts/phase-audits/1-plan.md:1:standalone:dxloop-plan:%s\n' \
  "$ROOT" "$FINALIZE_GENERATION" > "$(dx_loop_config_file "$FINALIZE_SESSION")"
printf 'keep this prompt\n' > "$(dx_prompt_file "$FINALIZE_SESSION")"
touch "$(dx_active_file "$FINALIZE_SESSION")" \
  "$(dx_paused_file "$FINALIZE_SESSION")"
dx_lifecycle_control_lock_acquire "$FINALIZE_SESSION"
set +e
env TEST_FINALIZE_SESSION="$FINALIZE_SESSION" \
  TEST_FINALIZE_GENERATION="$FINALIZE_GENERATION" \
  DEX_STANDALONE_FINALIZE_LOCK_ATTEMPTS=1 zsh -fc '
  source "$DEX_DIR/dx.sh"
  __dx_finalize_standalone_pause "$TEST_FINALIZE_SESSION" standalone \
    dxloop-plan 1 "$TEST_FINALIZE_GENERATION"
'
FINALIZE_RC=$?
set -e
dx_lifecycle_control_lock_release "$FINALIZE_SESSION"
assert_eq "2" "$FINALIZE_RC" "locked standalone finalizer result"
assert_file "$(dx_active_file "$FINALIZE_SESSION")"
assert_file "$(dx_loop_config_file "$FINALIZE_SESSION")"
assert_file "$(dx_prompt_file "$FINALIZE_SESSION")"
assert_eq "$FINALIZE_GENERATION" \
  "$(dx_completion_current_generation \
    "$FINALIZE_SESSION" standalone dxloop-plan 1)" \
  "locked standalone finalizer generation"
dx_completion_cleanup "$FINALIZE_SESSION"
rm -f "$(dx_active_file "$FINALIZE_SESSION")" \
  "$(dx_paused_file "$FINALIZE_SESSION")" \
  "$(dx_loop_config_file "$FINALIZE_SESSION")" \
  "$(dx_prompt_file "$FINALIZE_SESSION")"

# Claude profiles write the launch-bound receipt and let the real Stop hook
# consume it. This covers dxloop's two standalone purposes end to end.
export TEST_CLAUDE_PROMPT_LOG="$TMP_DIR/claude-prompts.log"
cat > "$TMP_DIR/bin/claude" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "claude" >> "$TEST_ROUTE_FILE"
printf '%s\n' "$@" >> "$TEST_CLAUDE_PROMPT_LOG"
# shellcheck disable=SC1091
source "$DEX_DIR/lib/common.sh"
# shellcheck source=/dev/null
source "$TEST_PROVIDER_HELPER"

joined_args="$*"
if [[ "$joined_args" == *'skill: "dxrefine"'* ]]; then
  exit 0
elif [[ "$joined_args" == *"Call EnterPlanMode now, then run /dxplan"* ]]; then
  action="${TEST_CLAUDE_PLAN_RECEIPT:-complete}"
  purpose="dxloop-plan"
  phase="1"
elif [[ "$joined_args" == *"The plan is approved. Implement it now."* ]]; then
  action="${TEST_CLAUDE_PROMPT_RECEIPT:-complete}"
  purpose="dxloop-prompt"
  phase="prompt-loop"
elif [[ "$joined_args" == *'skill: "dxcomplete"'* ]]; then
  action="${TEST_CLAUDE_COMPLETE_RECEIPT:-complete}"
  purpose="dxcomplete"
  phase="6"
else
  printf '%s\n' "unrecognized Claude standalone prompt" >&2
  exit 2
fi

perform_completion_action "$action" "$purpose" "$phase" "$@"
case "$action" in
  complete|paused|both|human-pause|human-pause-dir)
    bash "$DEX_DIR/hooks/phase-loop.sh"
    ;;
  legacy|corrupt-legacy)
    bash "$DEX_DIR/hooks/phase-loop.sh" || true
    ;;
  missing|max|wrong-generation|wrong-context|replay|lost-active) ;;
esac
SH
chmod +x "$TMP_DIR/bin/claude"

: > "$TEST_ROUTE_FILE"
: > "$TEST_RECEIPT_LOG"
: > "${TEST_RECEIPT_LOG}.tsv"
: > "$TEST_CONTEXT_LOG"
: > "$TEST_CLAUDE_PROMPT_LOG"
DX_PROVIDER_PROFILE=claude-subscription \
  zsh -fc 'source "$DEX_DIR/dx.sh"; cd "$TEST_REPO"; dxloop "verify the provider route"' \
  > "$TMP_DIR/dxloop-claude.out" 2>&1
assert_eq "2" "$(grep -Fxc "claude" "$TEST_ROUTE_FILE")" \
  "Claude dxloop provider launches"
assert_contains "dxloop complete" "$TMP_DIR/dxloop-claude.out"
assert_eq $'dxloop-plan\t1' "$(cut -f1-2 "$TEST_CONTEXT_LOG" | sed -n '1p')" \
  "dxloop planning purpose"
assert_eq $'dxloop-prompt\tprompt-loop' \
  "$(cut -f1-2 "$TEST_CONTEXT_LOG" | sed -n '2p')" \
  "dxloop implementation purpose"
assert_eq "2" "$(cut -f3 "$TEST_CONTEXT_LOG" | sort -u | wc -l | tr -d '[:space:]')" \
  "dxloop generation isolation"
assert_eq "2" "$(wc -l < "$TEST_RECEIPT_LOG" | tr -d '[:space:]')" \
  "dxloop completion command count"
while IFS= read -r completion_command; do
  assert_contains "$completion_command" "$TEST_CLAUDE_PROMPT_LOG"
done < "$TEST_RECEIPT_LOG"
assert_not_contains "dx_completion_current_generation" "$TEST_CLAUDE_PROMPT_LOG"
assert_no_live_completion_authority
assert_no_standalone_runtime_files

: > "$TEST_ROUTE_FILE"
: > "$TEST_RECEIPT_LOG"
: > "${TEST_RECEIPT_LOG}.tsv"
: > "$TEST_CONTEXT_LOG"
: > "$TEST_CLAUDE_PROMPT_LOG"
run_expect_failure "$TMP_DIR/dxloop-claude-max.out" \
  env TEST_CLAUDE_PLAN_RECEIPT=complete TEST_CLAUDE_PROMPT_RECEIPT=max \
  DX_PROVIDER_PROFILE=claude-subscription \
  zsh -fc 'source "$DEX_DIR/dx.sh"; cd "$TEST_REPO"; dxloop "exercise max cleanup"'
assert_contains "dxloop paused: max audit iterations reached without completion" \
  "$TMP_DIR/dxloop-claude-max.out"
assert_no_live_completion_authority
assert_no_standalone_runtime_files

: > "$TEST_ROUTE_FILE"
: > "$TEST_RECEIPT_LOG"
: > "${TEST_RECEIPT_LOG}.tsv"
: > "$TEST_CONTEXT_LOG"
: > "$TEST_CLAUDE_PROMPT_LOG"
run_expect_failure "$TMP_DIR/dxloop-claude-missing.out" \
  env TEST_CLAUDE_PLAN_RECEIPT=missing DX_PROVIDER_PROFILE=claude-subscription \
  zsh -fc 'source "$DEX_DIR/dx.sh"; cd "$TEST_REPO"; dxloop "exercise missing cleanup"'
assert_contains "dxloop paused during planning: the provider exited without a completion receipt" \
  "$TMP_DIR/dxloop-claude-missing.out"
assert_no_live_completion_authority
assert_no_standalone_runtime_files

: > "$TEST_ROUTE_FILE"
run_expect_failure "$TMP_DIR/dxloop-claude-plan-lost-active.out" \
  env TEST_CLAUDE_PLAN_RECEIPT=lost-active DX_PROVIDER_PROFILE=claude-subscription \
  zsh -fc 'source "$DEX_DIR/dx.sh"; cd "$TEST_REPO"; dxloop "lose planning activation"'
assert_contains "provider exited without a completion receipt" \
  "$TMP_DIR/dxloop-claude-plan-lost-active.out"
assert_not_contains "dxloop complete" "$TMP_DIR/dxloop-claude-plan-lost-active.out"
assert_eq "1" "$(grep -Fxc claude "$TEST_ROUTE_FILE")" \
  "lost planning activation provider count"
assert_no_live_completion_authority
assert_no_standalone_runtime_files

: > "$TEST_ROUTE_FILE"
run_expect_failure "$TMP_DIR/dxloop-claude-prompt-lost-active.out" \
  env TEST_CLAUDE_PLAN_RECEIPT=complete \
  TEST_CLAUDE_PROMPT_RECEIPT=lost-active \
  DX_PROVIDER_PROFILE=claude-subscription \
  zsh -fc 'source "$DEX_DIR/dx.sh"; cd "$TEST_REPO"; dxloop "lose implementation activation"'
assert_contains "provider exited without a completion receipt" \
  "$TMP_DIR/dxloop-claude-prompt-lost-active.out"
assert_not_contains "dxloop complete" "$TMP_DIR/dxloop-claude-prompt-lost-active.out"
assert_eq "2" "$(grep -Fxc claude "$TEST_ROUTE_FILE")" \
  "lost implementation activation provider count"
assert_no_live_completion_authority
assert_no_standalone_runtime_files

: > "$TEST_ROUTE_FILE"
run_expect_failure "$TMP_DIR/dxloop-claude-plan-human-pause.out" \
  env TEST_CLAUDE_PLAN_RECEIPT=human-pause \
  DX_PROVIDER_PROFILE=claude-subscription \
  zsh -fc 'source "$DEX_DIR/dx.sh"; cd "$TEST_REPO"; dxloop "pause planning"'
assert_contains "stopped during planning by direct human control" \
  "$TMP_DIR/dxloop-claude-plan-human-pause.out"
assert_eq "1" "$(grep -Fxc claude "$TEST_ROUTE_FILE")" \
  "planning pause provider count"
assert_no_live_completion_authority
assert_no_standalone_runtime_files

: > "$TEST_ROUTE_FILE"
run_expect_failure "$TMP_DIR/dxloop-claude-prompt-human-pause.out" \
  env TEST_CLAUDE_PLAN_RECEIPT=complete \
  TEST_CLAUDE_PROMPT_RECEIPT=human-pause \
  DX_PROVIDER_PROFILE=claude-subscription \
  zsh -fc 'source "$DEX_DIR/dx.sh"; cd "$TEST_REPO"; dxloop "pause implementation"'
assert_contains "dxloop stopped by direct human control" \
  "$TMP_DIR/dxloop-claude-prompt-human-pause.out"
assert_eq "2" "$(grep -Fxc claude "$TEST_ROUTE_FILE")" \
  "implementation pause provider count"
assert_no_live_completion_authority
assert_no_standalone_runtime_files

: > "$TEST_ROUTE_FILE"
DX_PROVIDER_PROFILE=claude-subscription \
  zsh -fc 'source "$DEX_DIR/dx.sh"; cd "$TEST_REPO"; dxrefine "split this effort"' \
  > "$TMP_DIR/dxrefine-claude.out" 2>&1
grep -Fxq "claude" "$TEST_ROUTE_FILE"

: > "$TEST_ROUTE_FILE"
: > "$TEST_RECEIPT_LOG"
: > "${TEST_RECEIPT_LOG}.tsv"
: > "$TEST_CONTEXT_LOG"
: > "$TEST_CLAUDE_PROMPT_LOG"
DX_PROVIDER_PROFILE=claude-subscription \
  zsh -fc 'source "$DEX_DIR/dx.sh"; cd "$TEST_REPO"; dxcomplete' \
  > "$TMP_DIR/dxcomplete-claude.out" 2>&1
assert_eq "claude" "$(cat "$TEST_ROUTE_FILE")" "Claude dxcomplete provider route"
if grep -Fxq "codex" "$TEST_ROUTE_FILE"; then
  printf '%s\n' "Claude provider launched Codex" >&2
  exit 1
fi
assert_eq $'dxcomplete\t6' "$(cut -f1-2 "$TEST_CONTEXT_LOG")" \
  "Claude dxcomplete purpose"
assert_no_live_completion_authority

# A truncated standalone config cannot downgrade the Stop hook to the review
# child's temporary bare-marker path. The launch phase recovers a fresh exact
# generation and the legacy marker remains non-authorizing.
run_expect_failure "$TMP_DIR/dxcomplete-claude-corrupt-legacy.out" \
  env TEST_CLAUDE_COMPLETE_RECEIPT=corrupt-legacy \
  DX_PROVIDER_PROFILE=claude-subscription \
  zsh -fc 'source "$DEX_DIR/dx.sh"; cd "$TEST_REPO"; dxcomplete'
assert_contains "Legacy completion marker ignored" \
  "$TMP_DIR/dxcomplete-claude-corrupt-legacy.out"
assert_no_live_completion_authority
assert_no_standalone_runtime_files

# If the pause marker cannot be published, neither the Stop hook nor the
# wrapper may turn the surviving human control into a successful completion.
run_expect_failure "$TMP_DIR/dxcomplete-claude-pause-directory.out" \
  env TEST_CLAUDE_COMPLETE_RECEIPT=human-pause-dir \
  DX_PROVIDER_PROFILE=claude-subscription \
  zsh -fc 'source "$DEX_DIR/dx.sh"; cd "$TEST_REPO"; dxcomplete'
assert_not_contains "dxcomplete finished" \
  "$TMP_DIR/dxcomplete-claude-pause-directory.out"
assert_contains "could not prove that completion authorization was revoked" \
  "$TMP_DIR/dxcomplete-claude-pause-directory.out"
assert_no_live_completion_authority
rmdir "$(dx_paused_file "$DXCOMPLETE_SESSION_ID")"
rm -f "$(dx_pause_state_file "$DXCOMPLETE_SESSION_ID")" \
  "$(dx_lifecycle_control_file "$DXCOMPLETE_SESSION_ID")" \
  "$(dx_loop_config_file "$DXCOMPLETE_SESSION_ID")" \
  "$(dx_active_file "$DXCOMPLETE_SESSION_ID")" 2>/dev/null || true

run_review_route_case() { # <provider> <ambient-host> <expected-route> [use-assessor]
  local provider="$1" ambient_host="$2" expected_route="$3"
  local use_assessor="${4:-0}"
  local route_file="$TMP_DIR/review-${provider}.route"
  local output_file="$TMP_DIR/review-${provider}.out"
  local assessment_prompt_file="$TMP_DIR/review-${provider}-assessment.prompt"
  if [[ "$use_assessor" == "1" ]] && git -C "$TEST_REPO" diff --quiet; then
    printf '%s\n' "localized candidate change" >> "$TEST_REPO/README.md"
  fi
  : > "$route_file"
  : > "$assessment_prompt_file"

  if ! TEST_PROVIDER="$provider" \
  TEST_AMBIENT_HOST="$ambient_host" \
  TEST_REVIEW_ROUTE_FILE="$route_file" \
  TEST_REVIEW_ASSESSMENT_PROMPT_FILE="$assessment_prompt_file" \
  TEST_USE_ASSESSOR="$use_assessor" \
  zsh -fc '
	    source "$DEX_DIR/dx.sh"
	    cd "$TEST_REPO"
	    source "$TEST_PROVIDER_HELPER"

    if [[ "$TEST_USE_ASSESSOR" == "1" ]]; then
      unset DEX_REVIEW_TIER
    else
      export DEX_REVIEW_TIER=small
    fi

    __dx_refresh_provider() {
      if [[ "$TEST_PROVIDER" == "codex" ]]; then
        DX_PROVIDER_ENGINE=codex-plugin
        DX_PROVIDER_AGENT=codex
      else
        DX_PROVIDER_ENGINE=claude
        DX_PROVIDER_AGENT=claude
      fi
      DX_CLAUDE_FLAGS=()
    }
    dx_session_id() { print -r -- "review-${TEST_PROVIDER}"; }
    dx_provider_write_session_state() { return 0; }
    dx_provider_cleanup_session_state() { return 0; }
    __dx_provider_prompt() { return 0; }
    claude() { return 0; }
    codex() { return 0; }

	    emit_assessment() {
	      local generation
	      generation=$(extract_assessment_generation "$@") || return 96
	      print -r -- "{\"tier\":\"small\",\"reason_codes\":\"localized-change,focused-verification\",\"completion_generation\":\"${generation}\"}"
	    }
	    emit_contract() {
	      local completion_literal completion_session completion_generation
	      completion_literal=$(extract_completion_literal "$@") || return 96
	      completion_session=$(print -r -- "$completion_literal" | command cut -f1)
	      completion_generation=$(print -r -- "$completion_literal" | command cut -f2)
	      [[ "$completion_session" == "$DEX_SESSION_ID" ]] || return 96
	      print -r -- CLEAN > "$(dx_review_result_file "$DEX_SESSION_ID")"
      {
        print -r -- "## Scope"
        print -r -- ""
        print -r -- "Reviewed the complete caller-supplied scope for this provider-route pass."
        print -r -- ""
        print -r -- "## Acceptance Criteria"
        print -r -- ""
        print -r -- "Criteria binding: standalone"
        print -r -- ""
        print -r -- "## Deterministic Checks"
        print -r -- ""
        print -r -- "All applicable provider-route fixture checks passed."
        print -r -- ""
        print -r -- "## Review Coverage"
        print -r -- ""
        print -r -- "Correctness, security, contracts, tests, and architecture were covered."
        print -r -- ""
        print -r -- "## Verification"
        print -r -- ""
        print -r -- "The fixture verifier confirmed the selected provider route."
      } > "$(dx_review_context_file "$DEX_SESSION_ID")"
	      print -r -- "{\"version\":3,\"scope_fingerprint\":\"${DEX_REVIEW_SCOPE_FINGERPRINT:-}\",\"criteria_binding\":\"standalone\",\"policy_binding\":\"${DEX_REVIEW_POLICY_BINDING:-}\",\"pass_binding\":\"${DEX_REVIEW_PASS_BINDING:-}\",\"criteria_evidence\":{\"acceptance_criteria\":[],\"objectives\":[],\"verification_requirements\":[]},\"deterministic_checks\":\"pass\",\"coverage\":[\"correctness\",\"security\",\"contracts\",\"tests\",\"architecture\"],\"verifier\":\"pass\",\"verified_findings\":0,\"fixes_applied\":0}" > "$(dx_review_evidence_file "$DEX_SESSION_ID")"
	      dx_review_empty_findings_hash > "$(dx_findings_file "$DEX_SESSION_ID")"
	      command bash "$DEX_DIR/bin/complete-receipt.sh" \
	        "$completion_session" "$completion_generation"
	    }
	    __dx_claude() {
	      if [[ "${DEX_REVIEW_ASSESSMENT_ACTIVE:-0}" == "1" ]]; then
	        print -r -- "$*" > "$TEST_REVIEW_ASSESSMENT_PROMPT_FILE"
	        emit_assessment "$@"
	        return 0
	      fi
	      print -r -- claude >> "$TEST_REVIEW_ROUTE_FILE"
	      emit_contract "$@"
	    }
    bash() {
      if [[ "${1:-}" == "$DEX_DIR/bin/dxcodex.sh" ]]; then
	        if [[ "${DEX_REVIEW_ASSESSMENT_ACTIVE:-0}" == "1" ]]; then
	          print -r -- "${*: -1}" > "$TEST_REVIEW_ASSESSMENT_PROMPT_FILE"
	          emit_assessment "$@" > "$DX_CODEX_OUTPUT_LAST_MESSAGE"
	          return 0
	        fi
	        print -r -- codex >> "$TEST_REVIEW_ROUTE_FILE"
	        emit_contract "$@"
      else
        command bash "$@"
      fi
    }

    dxreviewloop
  ' > "$output_file" 2>&1; then
    printf 'review provider %s failed before completing its route\n' "$provider" >&2
    cat "$output_file" >&2
    exit 1
  fi

  if [[ "$(grep -Fxc "$expected_route" "$route_file")" -ne 1 ]] || \
     grep -Fvxq "$expected_route" "$route_file"; then
    printf 'review provider %s did not use route %s for its review wave\n' \
      "$provider" "$expected_route" >&2
    cat "$output_file" >&2
    exit 1
  fi
  grep -Fq "Agent:  $(tr '[:lower:]' '[:upper:]' <<< "${expected_route:0:1}")${expected_route:1}" "$output_file"

  if [[ "$use_assessor" == "1" ]]; then
    grep -Fq "focused verification sources" "$assessment_prompt_file"
    if [[ "$provider" == "codex" ]]; then
      grep -Fq "read-only shell commands" "$assessment_prompt_file"
      grep -Fq ".review-context" "$assessment_prompt_file"
      if grep -Fq "Do not use Bash" "$assessment_prompt_file"; then
        printf '%s\n' "Codex assessor was told not to use its read-only shell" >&2
        exit 1
      fi
    else
      grep -Fq "non-shell read-only inspection tools" "$assessment_prompt_file"
      if grep -Fq "read-only shell commands" "$assessment_prompt_file"; then
        printf '%s\n' "Claude assessor received Codex-specific shell guidance" >&2
        exit 1
      fi
    fi
  fi
}

# Ambient host signals are deliberately opposite to the selected profile.
run_review_route_case codex claude codex
run_review_route_case claude codex claude
run_review_route_case codex claude codex 1
run_review_route_case claude codex claude 1

printf 'standalone provider tests passed\n'
