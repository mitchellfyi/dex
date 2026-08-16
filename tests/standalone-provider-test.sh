#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-standalone-provider-test.XXXXXX")"

cleanup() {
  chmod -R u+w "$TMP_DIR" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

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
export PATH="$TMP_DIR/bin:/usr/bin:/bin"
mkdir -p "$HOME" "$TMP_DIR/bin" "$TEST_REPO"

git -C "$TEST_REPO" init -q
git -C "$TEST_REPO" config user.email dex@example.test
git -C "$TEST_REPO" config user.name "Dex Test"
printf '# repo\n' > "$TEST_REPO/README.md"
git -C "$TEST_REPO" add README.md
git -C "$TEST_REPO" commit -q -m init
git -C "$TEST_REPO" branch -m main

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
  case "${TEST_CODEX_RECEIPT:-missing}" in
    complete) touch "$(dx_complete_file "$DEX_SESSION_ID")" ;;
    paused) touch "$(dx_paused_file "$DEX_SESSION_ID")" ;;
    both)
      touch "$(dx_complete_file "$DEX_SESSION_ID")"
      touch "$(dx_paused_file "$DEX_SESSION_ID")"
      ;;
    missing) ;;
    *) exit 2 ;;
  esac
  exit 0
fi
exit 0
SH
chmod +x "$TMP_DIR/bin/codex"

run_expect_failure() { # <output> <command...>
  local output_file="$1"
  shift
  if "$@" > "$output_file" 2>&1; then
    printf 'expected command to fail: %s\n' "$*" >&2
    cat "$output_file" >&2
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

# A direct Codex completion run succeeds only with the explicit completion
# receipt and pauses cleanly when the agent writes the pause receipt.
: > "$TEST_ROUTE_FILE"
TEST_CODEX_RECEIPT=complete DX_PROVIDER_PROFILE=codex-subscription \
  zsh -fc 'source "$DEX_DIR/dx.sh"; cd "$TEST_REPO"; dxcomplete' \
  > "$TMP_DIR/dxcomplete-codex-complete.out" 2>&1
grep -Fxq "codex" "$TEST_ROUTE_FILE"
grep -Fq "Direct Codex completion contract" "$TEST_PROMPT_FILE"
grep -Fq "dxcomplete finished" "$TMP_DIR/dxcomplete-codex-complete.out"

run_expect_failure "$TMP_DIR/dxcomplete-codex-paused.out" \
  env TEST_CODEX_RECEIPT=paused DX_PROVIDER_PROFILE=codex-subscription \
  zsh -fc 'source "$DEX_DIR/dx.sh"; cd "$TEST_REPO"; dxcomplete'
grep -Fq "dxcomplete paused before completion" "$TMP_DIR/dxcomplete-codex-paused.out"

run_expect_failure "$TMP_DIR/dxcomplete-codex-missing.out" \
  env TEST_CODEX_RECEIPT=missing DX_PROVIDER_PROFILE=codex-subscription \
  zsh -fc 'source "$DEX_DIR/dx.sh"; cd "$TEST_REPO"; dxcomplete'
grep -Fq "provider exited without a completion receipt" "$TMP_DIR/dxcomplete-codex-missing.out"

run_expect_failure "$TMP_DIR/dxcomplete-codex-conflict.out" \
  env TEST_CODEX_RECEIPT=both DX_PROVIDER_PROFILE=codex-subscription \
  zsh -fc 'source "$DEX_DIR/dx.sh"; cd "$TEST_REPO"; dxcomplete'
grep -Fq "completion and pause receipts were both present" "$TMP_DIR/dxcomplete-codex-conflict.out"

# Claude profiles retain the Stop-hook receipt path and never launch Codex.
cat > "$TMP_DIR/bin/claude" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "claude" >> "$TEST_ROUTE_FILE"
# Simulate the Stop hook releasing a successfully completed standalone loop.
# shellcheck disable=SC1091
source "$DEX_DIR/lib/common.sh"
rm -f "$(dx_active_file "$DEX_SESSION_ID")"
touch "$(dx_complete_file "$DEX_SESSION_ID")"
SH
chmod +x "$TMP_DIR/bin/claude"

: > "$TEST_ROUTE_FILE"
DX_PROVIDER_PROFILE=claude-subscription \
  zsh -fc 'source "$DEX_DIR/dx.sh"; cd "$TEST_REPO"; dxloop "verify the provider route"' \
  > "$TMP_DIR/dxloop-claude.out" 2>&1
if [[ "$(grep -Fxc "claude" "$TEST_ROUTE_FILE")" -ne 2 ]]; then
  printf '%s\n' "Claude dxloop did not launch both plan and implementation sessions" >&2
  exit 1
fi
grep -Fq "dxloop complete" "$TMP_DIR/dxloop-claude.out"

: > "$TEST_ROUTE_FILE"
DX_PROVIDER_PROFILE=claude-subscription \
  zsh -fc 'source "$DEX_DIR/dx.sh"; cd "$TEST_REPO"; dxrefine "split this effort"' \
  > "$TMP_DIR/dxrefine-claude.out" 2>&1
grep -Fxq "claude" "$TEST_ROUTE_FILE"

: > "$TEST_ROUTE_FILE"
DX_PROVIDER_PROFILE=claude-subscription \
  zsh -fc 'source "$DEX_DIR/dx.sh"; cd "$TEST_REPO"; dxcomplete' \
  > "$TMP_DIR/dxcomplete-claude.out" 2>&1
grep -Fxq "claude" "$TEST_ROUTE_FILE"
if grep -Fxq "codex" "$TEST_ROUTE_FILE"; then
  printf '%s\n' "Claude provider launched Codex" >&2
  exit 1
fi

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

    emit_contract() {
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
      touch "$(dx_complete_file "$DEX_SESSION_ID")"
    }
    __dx_claude() {
      if [[ "${DEX_REVIEW_ASSESSMENT_ACTIVE:-0}" == "1" ]]; then
        print -r -- "$*" > "$TEST_REVIEW_ASSESSMENT_PROMPT_FILE"
        print -r -- "{\"tier\":\"small\",\"reason_codes\":\"localized-change,focused-verification\"}"
        return 0
      fi
      print -r -- claude >> "$TEST_REVIEW_ROUTE_FILE"
      emit_contract
    }
    bash() {
      if [[ "${1:-}" == "$DEX_DIR/bin/dxcodex.sh" ]]; then
        if [[ "${DEX_REVIEW_ASSESSMENT_ACTIVE:-0}" == "1" ]]; then
          print -r -- "${*: -1}" > "$TEST_REVIEW_ASSESSMENT_PROMPT_FILE"
          print -r -- "{\"tier\":\"small\",\"reason_codes\":\"localized-change,focused-verification\"}" \
            > "$DX_CODEX_OUTPUT_LAST_MESSAGE"
          return 0
        fi
        print -r -- codex >> "$TEST_REVIEW_ROUTE_FILE"
        emit_contract
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

  if [[ "$(grep -Fxc "$expected_route" "$route_file")" -ne 3 ]] || \
     grep -Fvxq "$expected_route" "$route_file"; then
    printf 'review provider %s did not use route %s for all three waves\n' \
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
