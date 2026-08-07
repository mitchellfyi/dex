#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-review-loop-contract-test.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

run_case() { # <name> <host> <scenario> <expected-rc> <expected-text> [expected-waves]
  local name="$1" host="$2" scenario="$3" expected_rc="$4" expected_text="$5"
  local expected_waves="${6:-1}"
  local output_file="$TMP_DIR/$name.out" call_file="$TMP_DIR/$name.calls" rc

  set +e
  DEX_DIR="$ROOT" \
  DX_LOOP_DIR="$TMP_DIR/$name-loops" \
  DX_STATE_DIR="$TMP_DIR/$name-phases" \
  TEST_AGENT_HOST="$host" \
  TEST_REVIEW_SCENARIO="$scenario" \
  TEST_REVIEW_CALL_FILE="$call_file" \
  zsh -fc '
    source "$DEX_DIR/dx.sh"
    cd "$DEX_DIR"

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

    emit_review_contract() {
      print -r -- "$DEX_SESSION_ID" >> "$TEST_REVIEW_CALL_FILE"
      case "$TEST_REVIEW_SCENARIO" in
        blocked)
          print -r -- "BLOCKED:review-tool-unavailable" > "$(dx_review_result_file "$DEX_SESSION_ID")"
          ;;
        *)
          print -r -- CLEAN > "$(dx_review_result_file "$DEX_SESSION_ID")"
          ;;
      esac

      if [[ "$TEST_REVIEW_SCENARIO" != "missing-context" ]]; then
        {
          print -r -- "## Scope"
          print -r -- ""
          print -r -- "Reviewed the complete caller-supplied scope for this independent contract pass."
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
        } > "$(dx_review_context_file "$DEX_SESSION_ID")"
      fi

      if [[ "$TEST_REVIEW_SCENARIO" != "missing-evidence" ]]; then
        local checks=pass verifier=pass findings=0
        if [[ "$TEST_REVIEW_SCENARIO" == "blocked" ]]; then
          checks=partial
          verifier=not-run
          findings=0
        fi
        print -r -- "{\"version\":1,\"scope_fingerprint\":\"${DEX_REVIEW_SCOPE_FINGERPRINT:-}\",\"deterministic_checks\":\"${checks}\",\"coverage\":[\"correctness\",\"security\",\"contracts\",\"tests\",\"architecture\"],\"verifier\":\"${verifier}\",\"verified_findings\":${findings},\"fixes_applied\":0}" > "$(dx_review_evidence_file "$DEX_SESSION_ID")"
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
    }

    __dx_claude() {
      emit_review_contract
      if [[ "$TEST_REVIEW_SCENARIO" == "valid-hook" ]]; then
        print -r -- "{\"session_id\":\"${DEX_SESSION_ID}\"}" | \
          command env DEX_DIR="$DEX_DIR" DEX_SESSION_ID="$DEX_SESSION_ID" \
            DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=3 DEX_REVIEW_PASS_ACTIVE=1 \
            DEX_REVIEW_PROFILE="${DEX_REVIEW_PROFILE}" \
            DEX_REVIEW_SCOPE_FINGERPRINT="${DEX_REVIEW_SCOPE_FINGERPRINT}" \
            DEX_PHASE_HANDOFF="" bash "$DEX_DIR/hooks/phase-loop.sh" >/dev/null
      fi
    }
    bash() {
      if [[ "${1:-}" == "$DEX_DIR/bin/dxcodex.sh" ]]; then
        emit_review_contract
      else
        command bash "$@"
      fi
    }

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
  if [[ "$(wc -l < "$call_file" | tr -d ' ')" -ne "$expected_waves" ]]; then
    printf 'FAIL: %s ran an unexpected number of review waves\n' "$name" >&2
    cat "$call_file" >&2
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

printf 'review-loop-contract-test passed\n'
