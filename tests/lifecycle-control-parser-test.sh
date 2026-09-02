#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
PARSER="$ROOT/scripts/lifecycle-control.py"
export DEX_DIR="$ROOT"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"

pass=0
fail=0

check() {
  local description="$1" phase="$2" prompt="$3" expected_action="$4" expected_target="$5"
  local result actual
  result=$(printf '%s' "$prompt" | python3 "$PARSER" --phase "$phase")
  actual=$(printf '%s' "$result" | python3 -c '
import json, sys
value = json.load(sys.stdin)
print(f"{value.get('"'"'action'"'"', '"'"''"'"')}:{value.get('"'"'target_phase'"'"', '"'"''"'"')}")
')
  if [[ "$actual" == "${expected_action}:${expected_target}" ]]; then
    pass=$((pass + 1))
  else
    printf 'FAIL: %s (got %s, expected %s:%s)\n' \
      "$description" "$actual" "$expected_action" "$expected_target" >&2
    fail=$((fail + 1))
  fi
}

check "stop Dex" 3 "Stop Dex and let me take over." cancel ""
check "short stop" 3 "Please stop now." cancel ""
check "short quit" 3 "quit" cancel ""
check "short exit" 3 "Exit now." cancel ""
check "ignore Dex" 2 "Ignore Dex for this session; commit what is ready." cancel ""
check "leave review loop" 3 "Please leave the review loop now." pause ""
check "stop review loop" 3 "Stop the review loop now." cancel ""
check "stop reviewing" 3 "Stop reviewing and move on." complete 4
check "stop verification" 4 "Stop verification and prepare the PR." complete 5
check "skip verify gates" 3 "Skip the verify gates." jump 5
check "stop phased workflow" 2 "Stop the phased approach." cancel ""
check "skip current phase" 2 "Skip this phase and continue." complete 3
check "mark current phase done" 2 "Mark the current phase done." complete 3
check "skip named phase" 3 "Skip verification and prepare the PR." jump 5
check "mark named phase done" 3 "Mark review as done and move on." complete 4
check "jump by number" 1 "Jump to phase 4." jump 4
check "jump by name" 2 "Go straight to the PR phase." jump 5
check "move Dex by name" 2 "Move the Dex lifecycle to review." jump 3
check "resume current phase" 3 "Resume Dex." resume ""
check "resume at phase" 3 "Resume Dex at verification." jump 4
check "explicit pause" 3 "/dex pause" pause ""
check "explicit complete" 3 "/dex complete" complete 4
check "explicit jump" 2 "/dex jump verify" jump 4
check "explicit resume" 2 "/dex resume" resume ""
check "compact pause" 3 "/dxpause" pause ""
check "compact recover" 3 "/dxrecover" recover ""
check "compact jump" 2 "/dxjump verify" jump 4
check "compact resume" 2 "/dxresume" resume ""
check "explicit recover" 3 "/dx recover" recover ""
for phase in 0 1 2 3 4 5 6; do
  check "compact skip phase ${phase}" "$phase" "/dxskip" complete "$((phase + 1))"
done
check "compact skip named phase" 2 "/dxskip verify" jump 5
check "compact jump requires target" 2 "/dxjump" "" ""

check "negated stop" 3 "Do not stop Dex; keep reviewing." "" ""
check "negated skip" 3 "Don't skip verification." "" ""
check "quoted example" 3 "Document the phrase 'stop Dex' for users." "" ""
check "feature discussion" 3 "Add support for agents being told to stop Dex." "" ""
check "original feature request is discussion" 3 "Can you make sure that there is a way for an agent to be instructed to stop the phased approach and skip ahead?" "" ""
check "human-control design discussion" 3 "We need an easy way for a human to ask it to stop Dex." "" ""
check "ordinary phase mention" 3 "Explain what happens after the review phase." "" ""
check "described user option is not a directive" 2 \
  "If approved work produces no branch-specific commit, pause for user direction; the user may stop the lifecycle as no-change or choose an explicit lifecycle control action." \
  "" ""
check "described human ability is not a directive" 3 \
  "A human can stop Dex from the terminal at any time." "" ""
check "second-person permission is still a directive" 3 "You may stop Dex now." cancel ""
check "whether-to option is not a directive" 2 \
  "Ask the user whether to stop the lifecycle as no-change or choose an explicit lifecycle control action." \
  "" ""
check "soft-wrapped whether-to option is not a directive" 2 \
  $'Ask the user whether to\nstop the lifecycle as no-change or choose an explicit lifecycle control action.' \
  "" ""
check "hard line break still ends the clause" 3 $'Do not do any more work.\nStop Dex.' cancel ""
check "mark the PR ready is GitHub work" 6 "Mark the PR ready and request reviewers." "" ""
check "mark named phase done still completes" 5 "Mark the PR phase done." complete 6
check "skip named phase without verdict still jumps" 3 "Skip the PR." jump 6
check "ordinary implementation imperative" 2 "Go implement the requested fix." "" ""
check "ordinary plan imperative" 2 "Move to plan the requested work." "" ""
check "watcher resume is unrelated" 6 "Resume watcher monitoring." "" ""

# Dex's own phase launch messages reach the prompt hook as the session's first
# prompt on every launch and resume. Phase 2 once read as "stop the lifecycle"
# and Phase 6 as "mark the PR", each detaching a freshly resumed session.
for phase in 0 1 2 3 4 5 6; do
  LAUNCH_PROMPT=$(DEX_DIR="$ROOT" zsh -fc \
    'source "$DEX_DIR/dx.sh" >/dev/null 2>&1; __dx_phase_message "$1" 2310' _ "$phase")
  [[ -n "$LAUNCH_PROMPT" ]] || assert_at $LINENO
  check "generated phase ${phase} launch prompt is not human lifecycle control" \
    "$phase" "$LAUNCH_PROMPT" "" ""
done

# The phase audit prompts speak in the same voice. They arrive through the
# Stop hook today, but nothing Dex writes to the agent may read as a control.
for AUDIT_PROMPT_FILE in "$ROOT"/prompts/phase-audits/*.md; do
  AUDIT_PHASE=$(basename "$AUDIT_PROMPT_FILE" | cut -c1)
  [[ "$AUDIT_PHASE" =~ ^[0-6]$ ]] || AUDIT_PHASE=3
  check "audit prompt $(basename "$AUDIT_PROMPT_FILE") is not human lifecycle control" \
    "$AUDIT_PHASE" "$(<"$AUDIT_PROMPT_FILE")" "" ""
done

__dx_provider_prompt() { return 0; }
WAVE_PROMPT=$(__dx_review_wave_message_template \
  "current change set" "main" "changes" "git diff" \
  "git diff --stat" "git diff --name-only" "REVIEW_PASS_COMPLETE")
check "generated review-wave prompt is not human lifecycle control" 3 \
  "$WAVE_PROMPT" "" ""
grep -q "Commit, push, and PR actions remain available" <<< "$WAVE_PROMPT" \
  || assert_at $LINENO
LIFECYCLE_WAVE_PROMPT=$(__dx_review_wave_message_template \
  "current change set" "main" "changes" "git diff" \
  "git diff --stat" "git diff --name-only" "REVIEW_PASS_COMPLETE" "lifecycle")
grep -q "Commit and push coherent accepted fixes" <<< "$LIFECYCLE_WAVE_PROMPT" \
  || assert_at $LINENO
if grep -q "Do not commit, push, switch branches" \
  <<< "$LIFECYCLE_WAVE_PROMPT"; then
  assert_at $LINENO
fi
if grep -Ein 'mark[[:space:]]+plan-dependent' \
  "$ROOT/lib/review-loop.sh" "$ROOT/prompts/phase-audits/3-review.md" \
  >/dev/null; then
  assert_at $LINENO
fi
[[ "$(__dx_review_default_pass_timeout light)" == "900" ]] || assert_at $LINENO
[[ "$(__dx_review_default_pass_timeout standard)" == "1800" ]] || assert_at $LINENO
[[ "$(__dx_review_default_pass_timeout thorough)" == "3600" ]] || assert_at $LINENO
if __dx_review_default_pass_timeout unsupported >/dev/null 2>&1; then
  assert_at $LINENO
fi

check "negation ends at semicolon" 3 "Do not do any more work; stop Dex." cancel ""
check "never mind is not negation" 3 "Never mind the review, stop Dex." cancel ""
check "meta word in prior clause" 3 "The test passed; stop Dex." cancel ""
check "sequenced instruction" 3 "Please explain the result, then stop Dex." cancel ""

printf 'lifecycle-control-parser-test: %d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || assert_at $LINENO
