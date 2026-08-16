#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-dx-script-test.XXXXXX")"
export HOME="$TMP_DIR/home"
export DX_RUN_ROOT="$TMP_DIR/review-runs"
mkdir -p "$HOME" "$DX_RUN_ROOT"

cleanup() {
  chmod -R u+w "$TMP_DIR" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT


zsh "$ROOT/dx.sh" --help > "$TMP_DIR/zsh-help.out"
assert_contains "Dex" "$TMP_DIR/zsh-help.out"
assert_contains "dx run --spec FILE" "$TMP_DIR/zsh-help.out"
assert_contains "dxcd [number|name]" "$TMP_DIR/zsh-help.out"
assert_not_contains "dx rename" "$TMP_DIR/zsh-help.out"

if zsh "$ROOT/dx.sh" > "$TMP_DIR/zsh-empty.out" 2>&1; then
  printf 'expected zsh dx.sh with no args to exit non-zero\n' >&2
  exit 1
fi
assert_contains "Usage: dx <NUMBER>" "$TMP_DIR/zsh-empty.out"

if bash "$ROOT/dx.sh" --help > "$TMP_DIR/bash-help.out" 2>&1; then
  printf 'expected bash dx.sh --help to fail with zsh requirement\n' >&2
  exit 1
fi
assert_contains "dx.sh requires zsh" "$TMP_DIR/bash-help.out"

DEX_DIR="$ROOT" zsh -fc 'source "$DEX_DIR/dx.sh"; dx help' > "$TMP_DIR/source-help.out"
assert_contains "Dex" "$TMP_DIR/source-help.out"

if DEX_DIR="$ROOT" zsh -fc 'source "$DEX_DIR/dx.sh"; dx rename' > "$TMP_DIR/rename.out" 2>&1; then
  printf 'expected removed dx rename command to fail\n' >&2
  exit 1
fi
assert_contains "'dx rename' is not a command" "$TMP_DIR/rename.out"

DEX_DIR="$ROOT" zsh -fc '
  source "$DEX_DIR/dx.sh"
  set -e

  [[ "$(dx_review_normalize_tier small)" == "small" ]]
  [[ "$(dx_review_normalize_tier light)" == "small" ]]
  [[ "$(dx_review_normalize_tier normal)" == "normal" ]]
  [[ "$(dx_review_normalize_tier standard)" == "normal" ]]
  [[ "$(dx_review_normalize_tier complex)" == "complex" ]]
  [[ "$(dx_review_normalize_tier thorough)" == "complex" ]]
  __dx_review_is_positive_integer 08
  unset DX_PHASE_PROMISES
  [[ "$(__dx_review_phase_promise)" == "PHASE_3_COMPLETE" ]]
' > "$TMP_DIR/review-profile-defaults.out"

DEX_DIR="$ROOT" \
DX_LOOP_DIR="$TMP_DIR/review-loop" \
TEST_EXPECTED_RUN_ROOT="$TMP_DIR/review-runs" \
REVIEW_CALL_FILE="$TMP_DIR/review-calls.out" \
zsh -fc '
  source "$DEX_DIR/dx.sh"
  cd "$DEX_DIR"
  [[ "$(dx_run_root)" == "$TEST_EXPECTED_RUN_ROOT" ]] || return 97
  __dx_refresh_provider() {
    DX_PROVIDER_ENGINE=claude
    DX_PROVIDER_AGENT=claude
    DX_CLAUDE_FLAGS=()
  }
  dx_agent_host() { print -r -- claude; }
  dx_agent_host_label() { print -r -- Claude; }
  dx_session_id() { print -r -- review-profile-test; }
  dx_provider_write_session_state() { return 0; }
  dx_provider_cleanup_session_state() { return 0; }
  __dx_provider_prompt() { return 0; }
  claude() { return 0; }
  __dx_claude() {
    print -r -- "${DEX_LOOP_PROMISE:-<empty>}" >> "$REVIEW_CALL_FILE"
    {
      print -r -- "## Scope"
      print -r -- ""
      print -r -- "Reviewed the complete adaptive-review fixture scope."
      print -r -- ""
      print -r -- "## Acceptance Criteria"
      print -r -- ""
      print -r -- "Criteria binding: standalone"
      print -r -- ""
      print -r -- "## Deterministic Checks"
      print -r -- ""
      print -r -- "All applicable fixture checks passed."
      print -r -- ""
      print -r -- "## Review Coverage"
      print -r -- ""
      print -r -- "Correctness, security, contracts, tests, architecture, frontend, devops, performance, and observability were covered."
      print -r -- ""
      print -r -- "## Verification"
      print -r -- ""
      print -r -- "The independent fixture verifier passed."
    } > "$(dx_review_context_file "$DEX_SESSION_ID")"
    print -r -- "{\"version\":3,\"scope_fingerprint\":\"${DEX_REVIEW_SCOPE_FINGERPRINT:-}\",\"criteria_binding\":\"standalone\",\"policy_binding\":\"${DEX_REVIEW_POLICY_BINDING:-}\",\"pass_binding\":\"${DEX_REVIEW_PASS_BINDING:-}\",\"criteria_evidence\":{\"acceptance_criteria\":[],\"objectives\":[],\"verification_requirements\":[]},\"deterministic_checks\":\"pass\",\"coverage\":[\"correctness\",\"security\",\"contracts\",\"tests\",\"architecture\",\"frontend\",\"devops\",\"performance\",\"observability\"],\"verifier\":\"pass\",\"verified_findings\":0,\"fixes_applied\":0}" > "$(dx_review_evidence_file "$DEX_SESSION_ID")"
    dx_review_empty_findings_hash > "$(dx_findings_file "$DEX_SESSION_ID")"
    print -r -- CLEAN > "$(dx_review_result_file "$DEX_SESSION_ID")"
    touch "$(dx_complete_file "$DEX_SESSION_ID")"
  }

  if DEX_REVIEW_CLEAN_PASSES=0 dxreviewloop; then
    print -u2 -- "expected a zero clean-pass requirement to fail"
    return 1
  fi
  unset DX_REVIEW_PROFILE \
    DX_REVIEW_LIGHT_CLEAN_PASSES DX_REVIEW_STANDARD_CLEAN_PASSES DX_REVIEW_THOROUGH_CLEAN_PASSES \
    DX_PHASE_PROMISES DEX_REVIEW_CLEAN_PASSES
  DEX_REVIEW_PROFILE=thorough dxreviewloop
' > "$TMP_DIR/review-profile-validation.out" 2>&1
assert_contains "Invalid clean-pass requirement '0'." "$TMP_DIR/review-profile-validation.out"
assert_contains "Review complete: 9 consecutive clean passes." "$TMP_DIR/review-profile-validation.out"
if [[ "$(wc -l < "$TMP_DIR/review-calls.out" | tr -d ' ')" -ne 9 ]]; then
  printf 'expected nine review-wave calls with missing shell globals\n' >&2
  exit 1
fi
if grep -Fvxq "PHASE_3_COMPLETE" "$TMP_DIR/review-calls.out"; then
  printf 'review wave received an unexpected completion promise\n' >&2
  exit 1
fi

printf 'dx-script-test passed\n'
