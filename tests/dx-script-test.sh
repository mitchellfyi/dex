#!/usr/bin/env bash
set -euo pipefail
umask 077

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

REVIEW_POLICY_REPO="$TMP_DIR/review-policy-repo"
mkdir -p "$REVIEW_POLICY_REPO/.dex"
git init -q -b main "$REVIEW_POLICY_REPO"
git -C "$REVIEW_POLICY_REPO" config user.name "Dex Test"
git -C "$REVIEW_POLICY_REPO" config user.email "dex-test@example.com"
{
  printf '%s\n' '## Review Policy'
  printf '%s\n' '| Setting | Value |'
  printf '%s\n' '|---------|-------|'
  printf '%s\n' '| small_clean_passes | 1 |'
  printf '%s\n' '| normal_clean_passes | 2 |'
  printf '%s\n' '| complex_clean_passes | 3 |'
} > "$REVIEW_POLICY_REPO/.dex/dex.md"
git -C "$REVIEW_POLICY_REPO" add .dex/dex.md
git -C "$REVIEW_POLICY_REPO" commit -qm "test: initialize review policy fixture"
git -C "$REVIEW_POLICY_REPO" update-ref refs/remotes/origin/main HEAD

TEST_COMPLETION_PARSER="$TMP_DIR/parse-completion.py"
cat > "$TEST_COMPLETION_PARSER" <<'PY'
import re
import sys

if len(sys.argv) > 1 and sys.argv[1] == "--assessment":
    matches = []
    for value in sys.argv[2:]:
        matches.extend(re.findall(r'"completion_generation":"([0-9a-f]{32})"', value))
    if len(matches) != 1:
        raise SystemExit(1)
    print(matches[0])
    raise SystemExit(0)

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
export TEST_COMPLETION_PARSER

zsh "$ROOT/dx.sh" --help > "$TMP_DIR/zsh-help.out"
assert_contains "Dex" "$TMP_DIR/zsh-help.out"
assert_contains "dx run --spec FILE" "$TMP_DIR/zsh-help.out"
assert_contains "dxcd [number|name]" "$TMP_DIR/zsh-help.out"
assert_contains "commit and push coherent checkpoints" "$TMP_DIR/zsh-help.out"
assert_contains "final PR gate" "$TMP_DIR/zsh-help.out"
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

DEX_DIR="$ROOT" zsh -fc 'source "$DEX_DIR/dx.sh"; __dx_phase_message 2' > "$TMP_DIR/phase-2-message.out"
assert_contains "Follow prompts/commit-format.md" "$TMP_DIR/phase-2-message.out"
assert_contains "Do not wait for full verification" "$TMP_DIR/phase-2-message.out"
assert_contains "push immediately after every commit" "$TMP_DIR/phase-2-message.out"
assert_contains "stop the lifecycle as no-change" "$TMP_DIR/phase-2-message.out"

DEX_DIR="$ROOT" zsh -fc 'source "$DEX_DIR/dx.sh"; __dx_phase_message 3' > "$TMP_DIR/phase-3-message.out"
assert_contains "Commit and push accepted review fixes" "$TMP_DIR/phase-3-message.out"
assert_not_contains "Do not commit, push, or create a PR in Phase 3" "$TMP_DIR/phase-3-message.out"

DEX_DIR="$ROOT" zsh -fc 'source "$DEX_DIR/dx.sh"; __dx_phase_message 4' > "$TMP_DIR/phase-4-message.out"
assert_contains "final PR gate" "$TMP_DIR/phase-4-message.out"
assert_contains "commit and push each coherent repair checkpoint" "$TMP_DIR/phase-4-message.out"

assert_contains "Verification is the PR gate, not a commit prerequisite" "$ROOT/prompts/commit-format.md"
assert_contains "even while that test is failing" "$ROOT/prompts/commit-format.md"
assert_not_contains "Never commit broken code or failing tests" "$ROOT/prompts/commit-format.md"
assert_contains "Throughout implementation, review, and verification whenever" "$ROOT/skills/dxcommit/SKILL.md"
assert_contains "before PR handoff" "$ROOT/skills/dxverify/SKILL.md"

assert_contains "BRANCH_SPECIFIC_COUNT" "$ROOT/skills/dxpr/SKILL.md"
assert_contains "Do not push the branch" "$ROOT/skills/dxpr/SKILL.md"
assert_contains "no branch-specific commits cannot enter the ordinary PR flow" "$TMP_DIR/phase-4-message.out"

if DEX_DIR="$ROOT" zsh -fc 'source "$DEX_DIR/dx.sh"; dx rename' > "$TMP_DIR/rename.out" 2>&1; then
  printf 'expected removed dx rename command to fail\n' >&2
  exit 1
fi
assert_contains "'dx rename' is not a command" "$TMP_DIR/rename.out"

DEX_DIR="$ROOT" zsh -fc '
  source "$DEX_DIR/dx.sh"
  set -e

  [[ "$(dx_review_normalize_tier small)" == "small" ]] || assert_at $LINENO
  [[ "$(dx_review_normalize_tier light)" == "small" ]] || assert_at $LINENO
  [[ "$(dx_review_normalize_tier normal)" == "normal" ]] || assert_at $LINENO
  [[ "$(dx_review_normalize_tier standard)" == "normal" ]] || assert_at $LINENO
  [[ "$(dx_review_normalize_tier complex)" == "complex" ]] || assert_at $LINENO
  [[ "$(dx_review_normalize_tier thorough)" == "complex" ]] || assert_at $LINENO
  __dx_review_is_positive_integer 08
  [[ "$(__dx_review_phase_promise)" == "PHASE_3_COMPLETE" ]] || assert_at $LINENO
' > "$TMP_DIR/review-profile-defaults.out"

DEX_DIR="$ROOT" \
DX_LOOP_DIR="$TMP_DIR/review-loop" \
TEST_EXPECTED_RUN_ROOT="$TMP_DIR/review-runs" \
TEST_REVIEW_REPO="$REVIEW_POLICY_REPO" \
REVIEW_CALL_FILE="$TMP_DIR/review-calls.out" \
zsh -fc '
  source "$DEX_DIR/dx.sh"
  cd "$TEST_REVIEW_REPO"
  [[ "$(dx_run_root)" == "$TEST_EXPECTED_RUN_ROOT" ]] || return 97
  __dx_refresh_provider() {
    DX_PROVIDER_ENGINE=claude
    DX_PROVIDER_AGENT=claude
    DX_CLAUDE_FLAGS=()
  }
  dx_session_id() { print -r -- review-profile-test; }
  dx_provider_write_session_state() { return 0; }
  dx_provider_cleanup_session_state() { return 0; }
  __dx_provider_prompt() { return 0; }
  claude() { return 0; }
  __dx_claude() {
    local completion_literal completion_session completion_generation
    if [[ "${DEX_REVIEW_ASSESSMENT_ACTIVE:-0}" == "1" ]]; then
      completion_generation=$(python3 "$TEST_COMPLETION_PARSER" \
        --assessment "$@") || return 96
      print -r -- "{\"tier\":\"complex\",\"reason_codes\":\"cross-module,public-contract\",\"completion_generation\":\"${completion_generation}\"}"
      return 0
    fi
    completion_literal=$(python3 "$TEST_COMPLETION_PARSER" "$@") || return 96
    completion_session=$(print -r -- "$completion_literal" | command cut -f1)
    completion_generation=$(print -r -- "$completion_literal" | command cut -f2)
    [[ "$completion_session" == "$DEX_SESSION_ID" ]] || return 96
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
    command bash "$DEX_DIR/bin/complete-receipt.sh" \
      "$completion_session" "$completion_generation"
  }

  if DEX_REVIEW_CLEAN_PASSES=0 dxreviewloop; then
    print -u2 -- "expected a zero clean-pass requirement to fail"
    return 1
  fi
  unset DX_REVIEW_PROFILE DEX_REVIEW_CLEAN_PASSES
  DEX_REVIEW_PROFILE=thorough dxreviewloop
' > "$TMP_DIR/review-profile-validation.out" 2>&1
assert_contains "Invalid clean-pass requirement '0'." "$TMP_DIR/review-profile-validation.out"
assert_contains "Review complete: 3 consecutive clean passes." "$TMP_DIR/review-profile-validation.out"
if [[ "$(wc -l < "$TMP_DIR/review-calls.out" | tr -d ' ')" -ne 3 ]]; then
  printf 'expected six review-wave calls with missing shell globals\n' >&2
  exit 1
fi
if grep -Fvxq "PHASE_3_COMPLETE" "$TMP_DIR/review-calls.out"; then
  printf 'review wave received an unexpected completion promise\n' >&2
  exit 1
fi

# Naming an already-declared local again with no value does not redeclare it in
# zsh — `local x` prints `x=<current value>` on stdout and leaves the value
# alone. dxclean did that with old_files and printed "old_files=''" above its
# own report. bash does not, shellcheck reads dx.sh as bash, and the suite runs
# under bash, so nothing else sees it. Assert on the symptom: none of these
# commands may print a shell assignment.
SCRATCH_REPO="$TMP_DIR/scratch-repo"
git init -q "$SCRATCH_REPO"
git -C "$SCRATCH_REPO" config user.email test@example.com
git -C "$SCRATCH_REPO" config user.name Test
git -C "$SCRATCH_REPO" commit --allow-empty -qm init

for command in dxls dxclean; do
  DEX_DIR="$ROOT" DX_STATE_DIR="$TMP_DIR/leak-state" DX_LOOP_DIR="$TMP_DIR/leak-loops" \
  DX_ARTIFACT_DIR="$TMP_DIR/leak-art" DX_TOOL_DIR="$TMP_DIR/leak-tools" \
  DEXCODE_SYNC=0 DX_TEST_COMMAND="$command" \
  zsh -fc '
    source "$DEX_DIR/dx.sh"
    cd '"$SCRATCH_REPO"'
    "$DX_TEST_COMMAND"
  ' > "$TMP_DIR/leak-$command.out" 2>&1
  if grep -qE "^ *[a-z_][a-z0-9_]*=" "$TMP_DIR/leak-$command.out"; then
    printf '%s leaked a shell assignment into its output:\n' "$command" >&2
    cat "$TMP_DIR/leak-$command.out" >&2
    exit 1
  fi
done
assert_contains "Nothing to clean." "$TMP_DIR/leak-dxclean.out"
assert_contains "No worktrees." "$TMP_DIR/leak-dxls.out"

# __dx_show_header reads the same times file bin/status-line.sh does, and put
# its fields straight into $(( )). zsh evaluates an array subscript there as an
# arithmetic expression too, so a start time of `HOME[$(…)]` ran that command
# every time a phase header was drawn.
HEADER_CANARY="$TMP_DIR/header-canary"
DEX_DIR="$ROOT" DX_STATE_DIR="$TMP_DIR/header-state" DX_LOOP_DIR="$TMP_DIR/header-loops" \
DX_ARTIFACT_DIR="$TMP_DIR/header-art" DX_TOOL_DIR="$TMP_DIR/header-tools" \
DEXCODE_SYNC=0 DX_TEST_CANARY="$HEADER_CANARY" \
zsh -fc '
  source "$DEX_DIR/dx.sh"
  session_id=$(dx_session_id)
  mkdir -p "$DX_STATE_DIR"
  print -r -- "0:HOME[\$(touch $DX_TEST_CANARY)]" > "$(dx_times_file "$session_id")"
  print -r -- "1:HOME[\$(touch $DX_TEST_CANARY)]" >> "$(dx_times_file "$session_id")"
  __dx_show_header "wt" 3 "$DEX_DIR" main "$session_id" worktree
' > "$TMP_DIR/header.out" 2>&1
if [[ -e "$HEADER_CANARY" ]]; then
  printf 'dx.sh phase header executed a command from the times file\n' >&2
  exit 1
fi
assert_not_contains 'HOME[' "$TMP_DIR/header.out"

# Management commands and the lifecycle share one argument slot, so a mistyped
# subcommand is indistinguishable from a one-word task description — and used
# to cut a worktree, a branch and a full agent run without a word. A word that
# is nearly a command now has to be confirmed; anything else is untouched.
DEX_DIR="$ROOT" zsh -fc '
  source "$DEX_DIR/dx.sh"
  for pair in statu:status satus:status isntall:install confg:config refne:refine logs:log; do
    word="${pair%%:*}"
    expected="${pair##*:}"
    got=$(__dx_nearest_command "$word" 2>/dev/null || true)
    [[ "$got" == "$expected" ]] || {
      print -u2 -- "nearest command for $word was ${got:-<none>}, expected $expected"
      exit 1
    }
  done
  # A real task description must not be mistaken for a typo.
  for word in refactor frobnicate xyz; do
    got=$(__dx_nearest_command "$word" 2>/dev/null || true)
    [[ -z "$got" ]] || {
      print -u2 -- "$word was matched to $got; a plain task description must not be"
      exit 1
    }
  done
' > "$TMP_DIR/nearest.out" 2>&1 || {
  printf 'near-miss command matching failed:\n' >&2
  cat "$TMP_DIR/nearest.out" >&2
  exit 1
}

# Without a terminal there is nobody to ask, and refusing would break a script
# that has always been allowed to pass a one-word task: warn, then continue.
DEX_DIR="$ROOT" zsh -fc '
  source "$DEX_DIR/dx.sh"
  __dx_confirm_task_word statu 1 || exit 1
' > "$TMP_DIR/typo-headless.out" 2>&1 || {
  printf 'a non-interactive near-miss was refused instead of warned about\n' >&2
  cat "$TMP_DIR/typo-headless.out" >&2
  exit 1
}
assert_contains "is not a Dex command" "$TMP_DIR/typo-headless.out"
assert_contains "Did you mean 'dx status'" "$TMP_DIR/typo-headless.out"

# The cases that must never be interrupted: a multi-word description, a ticket,
# a flag, and an unquoted multi-argument task.
DEX_DIR="$ROOT" zsh -fc '
  source "$DEX_DIR/dx.sh"
  __dx_confirm_task_word "fix the login bug" 1 || exit 1
  __dx_confirm_task_word 123 1 || exit 1
  __dx_confirm_task_word ENG-456 1 || exit 1
  __dx_confirm_task_word --resume 1 || exit 1
  __dx_confirm_task_word fix 3 || exit 1
' > "$TMP_DIR/typo-quiet.out" 2>&1 || {
  printf 'an unambiguous request was interrupted by the typo guard:\n' >&2
  cat "$TMP_DIR/typo-quiet.out" >&2
  exit 1
}
if [[ -s "$TMP_DIR/typo-quiet.out" ]]; then
  printf 'the typo guard spoke up for an unambiguous request:\n' >&2
  cat "$TMP_DIR/typo-quiet.out" >&2
  exit 1
fi

printf 'dx-script-test passed\n'
