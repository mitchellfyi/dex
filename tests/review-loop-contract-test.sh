#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-review-loop-contract-test.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

run_case() { # <name> <host> <scenario> <expected-rc> <expected-text>
  local name="$1" host="$2" scenario="$3" expected_rc="$4" expected_text="$5"
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
          print -r -- "BLOCKED:review tool unavailable" > "$(dx_review_result_file "$DEX_SESSION_ID")"
          ;;
        *)
          print -r -- CLEAN > "$(dx_review_result_file "$DEX_SESSION_ID")"
          ;;
      esac

      if [[ "$TEST_REVIEW_SCENARIO" != "missing-context" ]]; then
        print -r -- "reviewed the full supplied scope" > "$(dx_review_context_file "$DEX_SESSION_ID")"
      fi

      case "$TEST_REVIEW_SCENARIO" in
        missing-hash)
          ;;
        multiple-hashes)
          print -r -- 0123456789abcdef > "$(dx_findings_file "$DEX_SESSION_ID")"
          print -r -- fedcba9876543210 >> "$(dx_findings_file "$DEX_SESSION_ID")"
          ;;
        *)
          print -r -- 0123456789abcdef > "$(dx_findings_file "$DEX_SESSION_ID")"
          ;;
      esac

      if [[ "$TEST_REVIEW_SCENARIO" != "missing-completion" ]]; then
        touch "$(dx_complete_file "$DEX_SESSION_ID")"
      fi
    }

    __dx_claude() { emit_review_contract; }
    bash() {
      if [[ "${1:-}" == "$DEX_DIR/bin/dxcodex.sh" ]]; then
        emit_review_contract
      else
        command bash "$@"
      fi
    }

    DEX_REVIEW_PROFILE=light \
    DEX_REVIEW_CLEAN_PASSES=1 \
    DEX_REVIEW_MAX_ITERATIONS=4 \
    dxreviewloop
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
  if [[ "$(wc -l < "$call_file" | tr -d ' ')" -ne 1 ]]; then
    printf 'FAIL: %s ran more than one review wave\n' "$name" >&2
    cat "$call_file" >&2
    exit 1
  fi
}

run_case "claude-empty-context" "claude" "missing-context" 1 "context pack missing or empty"
run_case "claude-multiple-hashes" "claude" "multiple-hashes" 1 "findings hash missing or invalid"
run_case "claude-missing-completion" "claude" "missing-completion" 1 "completion receipt missing"
run_case "claude-blocked" "claude" "blocked" 1 "dxreviewloop blocked: review tool unavailable"
run_case "codex-empty-context" "codex" "missing-context" 1 "context pack missing or empty"
run_case "codex-missing-hash" "codex" "missing-hash" 1 "findings hash missing or invalid"
run_case "codex-missing-completion" "codex" "missing-completion" 1 "completion receipt missing"
run_case "codex-valid" "codex" "valid" 0 "Review complete: 1 consecutive clean passes."

printf 'review-loop-contract-test passed\n'
