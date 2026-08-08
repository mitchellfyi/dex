#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-review-loop-contract-test.XXXXXX")"
export HOME="$TMP_DIR/home"
export DX_RUN_ROOT="$TMP_DIR/runs"
mkdir -p "$HOME" "$DX_RUN_ROOT"

cleanup() {
  chmod -R u+w "$TMP_DIR" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

run_case() { # <name> <host> <scenario> <expected-rc> <expected-text> [expected-waves]
  local name="$1" host="$2" scenario="$3" expected_rc="$4" expected_text="$5"
  local expected_waves="${6:-1}"
  local output_file="$TMP_DIR/$name.out" call_file="$TMP_DIR/$name.calls" rc

  set +e
  DEX_DIR="$ROOT" \
  HOME="$TMP_DIR/$name-home" \
  DX_LOOP_DIR="$TMP_DIR/$name-loops" \
  DX_RUN_ROOT="$TMP_DIR/$name-runs" \
  DX_STATE_DIR="$TMP_DIR/$name-phases" \
  TEST_EXPECTED_RUN_ROOT="$TMP_DIR/$name-runs" \
  TEST_AGENT_HOST="$host" \
  TEST_REVIEW_SCENARIO="$scenario" \
  TEST_REVIEW_CALL_FILE="$call_file" \
  zsh -fc '
    source "$DEX_DIR/dx.sh"
    cd "$DEX_DIR"
    [[ "$(dx_run_root)" == "$TEST_EXPECTED_RUN_ROOT" ]] || return 97

    __dx_refresh_provider() {
      if [[ "$TEST_AGENT_HOST" == "codex" ]]; then
        DX_PROVIDER_ENGINE=codex-plugin
        DX_PROVIDER_AGENT=codex
      else
        DX_PROVIDER_ENGINE=claude
        DX_PROVIDER_AGENT=claude
      fi
      DX_CLAUDE_FLAGS=()
    }
    dx_agent_host() { print -r -- "$TEST_AGENT_HOST"; }
    dx_agent_host_label() { print -r -- "$TEST_AGENT_HOST"; }
    dx_session_id() { print -r -- "contract-${TEST_AGENT_HOST}-${TEST_REVIEW_SCENARIO}"; }
    dx_provider_write_session_state() { return 0; }
    dx_provider_cleanup_session_state() { return 0; }
    __dx_provider_prompt() { return 0; }
    claude() { return 0; }
    codex() { return 0; }

    __test_contract_criteria_evidence() {
      local result="$1" context_path="$2" criteria_path criteria_hashes
      local objective_hash acceptance_hash verification_hash
      local objective_outcome=met acceptance_outcome=met verification_outcome=met
      criteria_path=$(dx_review_criteria_file "$DEX_SESSION_ID")
      if [[ "${DEX_REVIEW_CRITERIA_BINDING:-standalone}" == "standalone" ]]; then
        print -r -- "{\"acceptance_criteria\":[],\"objectives\":[],\"verification_requirements\":[]}"
        return 0
      fi

      criteria_hashes=$(dx_review_criteria_coverage_json "$DEX_REVIEW_CRITERIA_BINDING" "$criteria_path") || return 1
      objective_hash=$(print -r -- "$criteria_hashes" | sed -E "s/.*\"objectives\":\\[\"([a-f0-9]{64})\"\\].*/\\1/")
      acceptance_hash=$(print -r -- "$criteria_hashes" | sed -E "s/.*\"acceptance_criteria\":\\[\"([a-f0-9]{64})\"\\].*/\\1/")
      verification_hash=$(print -r -- "$criteria_hashes" | sed -E "s/.*\"verification_requirements\":\\[\"([a-f0-9]{64})\"\\].*/\\1/")
      [[ "$objective_hash" =~ ^[a-f0-9]{64}$ && "$acceptance_hash" =~ ^[a-f0-9]{64}$ && \
        "$verification_hash" =~ ^[a-f0-9]{64}$ ]] || return 1
      case "$result" in
        FINDINGS:*) acceptance_outcome=not_met ;;
        BLOCKED:*) verification_outcome=blocked ;;
      esac
      {
        print -r -- "Evidence-Ref: criteria:objectives:1:fixture-objective | analysis | Reviewed the lifecycle objective against the complete supplied scope."
        print -r -- "Evidence-Ref: criteria:acceptance_criteria:1:fixture-acceptance | test | Exercised the lifecycle control behavior in this contract fixture."
        print -r -- "Evidence-Ref: criteria:verification_requirements:1:fixture-verification | command | Ran the focused review-loop contract fixture required by this criterion."
      } >> "$context_path"
      printf "{\"acceptance_criteria\":[{\"item_hash\":\"%s\",\"outcome\":\"%s\",\"evidence_refs\":[\"criteria:acceptance_criteria:1:fixture-acceptance\"]}],\"objectives\":[{\"item_hash\":\"%s\",\"outcome\":\"%s\",\"evidence_refs\":[\"criteria:objectives:1:fixture-objective\"]}],\"verification_requirements\":[{\"item_hash\":\"%s\",\"outcome\":\"%s\",\"evidence_refs\":[\"criteria:verification_requirements:1:fixture-verification\"]}]}\n" \
        "$acceptance_hash" "$acceptance_outcome" "$objective_hash" "$objective_outcome" \
        "$verification_hash" "$verification_outcome"
    }

    emit_review_contract() {
      local result context_path criteria_evidence checks=pass verifier=pass findings=0
      print -r -- "$DEX_SESSION_ID" >> "$TEST_REVIEW_CALL_FILE"
      case "$TEST_REVIEW_SCENARIO" in
        blocked)
          result="BLOCKED:review-tool-unavailable"
          ;;
        *)
          result=CLEAN
          ;;
      esac
      print -r -- "$result" > "$(dx_review_result_file "$DEX_SESSION_ID")"

      if [[ "$TEST_REVIEW_SCENARIO" != "missing-context" ]]; then
        context_path=$(dx_review_context_file "$DEX_SESSION_ID")
        {
          print -r -- "## Scope"
          print -r -- ""
          print -r -- "Reviewed the complete caller-supplied scope for this independent contract pass."
          print -r -- ""
          print -r -- "## Acceptance Criteria"
          print -r -- ""
          print -r -- "Criteria binding: ${DEX_REVIEW_CRITERIA_BINDING:-standalone}"
          print -r -- ""
          print -r -- "## Deterministic Checks"
          print -r -- ""
          print -r -- "All applicable fixture checks passed."
          print -r -- ""
          print -r -- "## Review Coverage"
          print -r -- ""
          print -r -- "Correctness, security, contracts, tests, and architecture were covered."
          print -r -- ""
          print -r -- "## Verification"
          print -r -- ""
          print -r -- "The fixture verifier passed."
        } > "$context_path"
      fi

      if [[ "$TEST_REVIEW_SCENARIO" != "missing-evidence" ]]; then
        if [[ "$TEST_REVIEW_SCENARIO" == "blocked" ]]; then
          checks=partial
          verifier=not-run
          findings=0
        fi
        context_path=$(dx_review_context_file "$DEX_SESSION_ID")
        criteria_evidence=$(__test_contract_criteria_evidence "$result" "$context_path") || return 96
        print -r -- "{\"version\":3,\"scope_fingerprint\":\"${DEX_REVIEW_SCOPE_FINGERPRINT:-}\",\"criteria_binding\":\"${DEX_REVIEW_CRITERIA_BINDING:-standalone}\",\"policy_binding\":\"${DEX_REVIEW_POLICY_BINDING:-}\",\"pass_binding\":\"${DEX_REVIEW_PASS_BINDING:-}\",\"criteria_evidence\":${criteria_evidence},\"deterministic_checks\":\"${checks}\",\"coverage\":[\"correctness\",\"security\",\"contracts\",\"tests\",\"architecture\"],\"verifier\":\"${verifier}\",\"verified_findings\":${findings},\"fixes_applied\":0}" > "$(dx_review_evidence_file "$DEX_SESSION_ID")"
      fi

      case "$TEST_REVIEW_SCENARIO" in
        missing-hash)
          ;;
        multiple-hashes)
          dx_review_empty_findings_hash > "$(dx_findings_file "$DEX_SESSION_ID")"
          print -r -- fedcba9876543210 >> "$(dx_findings_file "$DEX_SESSION_ID")"
          ;;
        blocked)
          print -r -- 0123456789abcdef > "$(dx_findings_file "$DEX_SESSION_ID")"
          ;;
        *)
          dx_review_empty_findings_hash > "$(dx_findings_file "$DEX_SESSION_ID")"
          ;;
      esac

      if [[ "$TEST_REVIEW_SCENARIO" != "missing-completion" ]]; then
        touch "$(dx_complete_file "$DEX_SESSION_ID")"
      fi

      if [[ "$TEST_REVIEW_SCENARIO" == "human-cancel" ]]; then
        local parent_session
        parent_session=$(dx_session_id)
        dx_write_lifecycle_control "$parent_session" cancel "" user-prompt "" 3 ""
        dx_phase_busy_request_cancel "$parent_session" 3
      fi
    }

    assert_review_criteria_prompt() {
      local invocation="$*" criteria_path criteria_binding expected_pass_binding
      dx_review_policy_binding_valid "${DEX_REVIEW_POLICY_BINDING:-}" || return 1
      dx_review_pass_id_valid "${DEX_REVIEW_PASS_ID:-}" || return 1
      expected_pass_binding=$(dx_review_pass_binding "$DEX_REVIEW_PASS_ID" \
        "$DEX_REVIEW_SCOPE_FINGERPRINT" "${DEX_REVIEW_CRITERIA_BINDING:-standalone}" \
        "$DEX_REVIEW_POLICY_BINDING") || return 1
      [[ "${DEX_REVIEW_PASS_BINDING:-}" == "$expected_pass_binding" ]] || return 1
      [[ "$invocation" == *"$DEX_REVIEW_PASS_ID"* ]] || return 1
      [[ "$invocation" == *"$DEX_REVIEW_POLICY_BINDING"* ]] || return 1
      [[ "$invocation" == *"$DEX_REVIEW_PASS_BINDING"* ]] || return 1
      criteria_path=$(dx_review_criteria_file "$DEX_SESSION_ID")
      if [[ -e "$criteria_path" ]]; then
        criteria_binding=$(dx_review_criteria_hash "$criteria_path") || return 1
        [[ "${DEX_REVIEW_CRITERIA_BINDING:-}" == "$criteria_binding" ]]
        [[ "${DEX_REVIEW_CRITERIA_FILE:-}" == "$criteria_path" ]]
        [[ "$invocation" == *"$criteria_path"* ]]
        [[ "$invocation" == *"$criteria_binding"* ]]
        return
      fi
      [[ "${DEX_REVIEW_CRITERIA_BINDING:-}" == "standalone" ]]
      [[ "$invocation" == *"Approved requirements: N/A — standalone review"* ]]
      [[ "$invocation" != *"$criteria_path"* ]]
    }

    __dx_claude() {
      assert_review_criteria_prompt "$@" || return 96
      emit_review_contract
      if [[ "$TEST_REVIEW_SCENARIO" == "valid-hook" ]]; then
        print -r -- "{\"session_id\":\"${DEX_SESSION_ID}\"}" | \
          command env DEX_DIR="$DEX_DIR" DEX_SESSION_ID="$DEX_SESSION_ID" \
            DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=3 DEX_REVIEW_PASS_ACTIVE=1 \
            DEX_REVIEW_PROFILE="${DEX_REVIEW_PROFILE}" \
            DEX_REVIEW_SCOPE_FINGERPRINT="${DEX_REVIEW_SCOPE_FINGERPRINT}" \
            DEX_REVIEW_CRITERIA_BINDING="${DEX_REVIEW_CRITERIA_BINDING}" \
            DEX_REVIEW_CRITERIA_FILE="${DEX_REVIEW_CRITERIA_FILE}" \
            DEX_REVIEW_POLICY_BINDING="${DEX_REVIEW_POLICY_BINDING}" \
            DEX_REVIEW_PASS_ID="${DEX_REVIEW_PASS_ID}" \
            DEX_REVIEW_PASS_BINDING="${DEX_REVIEW_PASS_BINDING}" \
            DEX_PHASE_HANDOFF="" bash "$DEX_DIR/hooks/phase-loop.sh" >/dev/null
      fi
    }
    bash() {
      if [[ "${1:-}" == "$DEX_DIR/bin/dxcodex.sh" ]]; then
        assert_review_criteria_prompt "$@" || return 96
        emit_review_contract
      else
        command bash "$@"
      fi
    }

    if [[ "$TEST_REVIEW_SCENARIO" == "human-cancel" || "$TEST_REVIEW_SCENARIO" == "preflight-cancel" ]]; then
      mkdir -p "$DX_STATE_DIR" "$DX_LOOP_DIR"
      parent_session=$(dx_session_id)
      print -r -- 3 > "$(dx_state_file "$parent_session")"
      print -r -- "{\"version\":1,\"source\":\"approved-plan\",\"objectives\":[\"Exercise human review control.\"],\"acceptance_criteria\":[\"A direct human stop pauses the review loop.\"],\"verification_requirements\":[\"Run tests/review-loop-contract-test.sh.\"]}" > "$(dx_review_criteria_file "$parent_session")"
      dx_review_approve_criteria "$parent_session" initial "$(dx_review_criteria_hash "$(dx_review_criteria_file "$parent_session")")" >/dev/null
    fi
    if [[ "$TEST_REVIEW_SCENARIO" == "preflight-cancel" ]]; then
      dx_write_lifecycle_control "$(dx_session_id)" cancel "" terminal "" 3 ""
    fi
    DEX_REVIEW_TIER=small dxreviewloop
  ' > "$output_file" 2>&1
  rc=$?
  set -e

  if [[ "$rc" -ne "$expected_rc" ]]; then
    printf 'FAIL: %s returned %d, expected %d\n' "$name" "$rc" "$expected_rc" >&2
    cat "$output_file" >&2
    exit 1
  fi
  if ! grep -Fq "$expected_text" "$output_file"; then
    printf 'FAIL: %s did not print %s\n' "$name" "$expected_text" >&2
    cat "$output_file" >&2
    exit 1
  fi
  local actual_waves=0
  [[ -f "$call_file" ]] && actual_waves=$(wc -l < "$call_file" | tr -d ' ')
  if [[ "$actual_waves" -ne "$expected_waves" ]]; then
    printf 'FAIL: %s ran an unexpected number of review waves\n' "$name" >&2
    [[ -f "$call_file" ]] && cat "$call_file" >&2
    exit 1
  fi
}

run_case "claude-empty-context" "claude" "missing-context" 1 "context pack missing or empty"
run_case "claude-multiple-hashes" "claude" "multiple-hashes" 1 "findings hash missing or invalid"
run_case "claude-missing-completion" "claude" "missing-completion" 1 "completion receipt missing"
run_case "claude-missing-evidence" "claude" "missing-evidence" 1 "evidence manifest missing or invalid"
run_case "claude-blocked" "claude" "blocked" 1 "dxreviewloop blocked: review-tool-unavailable"
run_case "claude-valid-hook" "claude" "valid-hook" 0 "Review complete: 3 consecutive clean passes." 3
run_case "codex-empty-context" "codex" "missing-context" 1 "context pack missing or empty"
run_case "codex-missing-hash" "codex" "missing-hash" 1 "findings hash missing or invalid"
run_case "codex-missing-completion" "codex" "missing-completion" 1 "completion receipt missing"
run_case "codex-valid" "codex" "valid" 0 "Review complete: 3 consecutive clean passes." 3
run_case "claude-human-cancel" "claude" "human-cancel" 1 "Review paused: human_intervention." 1
run_case "claude-preflight-cancel" "claude" "preflight-cancel" 1 "Review paused: human_intervention." 0

# Signal cleanup runs only after the supervised child has stopped. Its matching
# quiescence acknowledgement must release the parent Phase 3 barrier.
SIGNAL_STATE_DIR="$TMP_DIR/signal-phases"
SIGNAL_LOOP_DIR="$TMP_DIR/signal-loops"
mkdir -p "$SIGNAL_STATE_DIR" "$SIGNAL_LOOP_DIR"
DEX_DIR="$ROOT" DX_STATE_DIR="$SIGNAL_STATE_DIR" DX_LOOP_DIR="$SIGNAL_LOOP_DIR" zsh -fc '
  source "$DEX_DIR/dx.sh"
  token=$(dx_phase_busy_begin signal-review-parent 3 "signal fixture")
  __dx_review_handle_interrupt "" "" 0 signal-review-parent "" 3 user_interrupt "$token"
  [[ ! -f "$(dx_phase_busy_file signal-review-parent 3)" ]]
'

# Codex assessments need their read-only shell to inspect unchanged tests and
# other verification sources. Claude keeps using its non-shell read tools.
DEX_DIR="$ROOT" zsh -fc '
  source "$DEX_DIR/dx.sh"
  codex_guidance=$(__dx_review_assessment_inspection_guidance codex)
  claude_guidance=$(__dx_review_assessment_inspection_guidance claude)
  [[ "$codex_guidance" == *"read-only shell commands"* ]]
  [[ "$codex_guidance" == *"focused verification sources"* ]]
  [[ "$codex_guidance" != *"Do not use Bash"* ]]
  [[ "$claude_guidance" == *"non-shell read-only inspection tools"* ]]
  ! __dx_review_assessment_inspection_guidance unsupported >/dev/null 2>&1
'

printf 'review-loop-contract-test passed\n'
