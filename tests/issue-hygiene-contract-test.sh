#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"

CONTRACT="$ROOT/prompts/issue-hygiene.md"
assert_file "$CONTRACT"
assert_contains "Search before writing" "$CONTRACT"
assert_contains "Update an existing issue instead of creating a duplicate" "$CONTRACT"
assert_contains "same pull request" "$CONTRACT"
assert_contains "Create a linked follow-up issue" "$CONTRACT"
assert_contains "existing open PR" "$CONTRACT"
assert_contains "active lifecycle phase" "$CONTRACT"
assert_contains "never move a ready PR back to" "$CONTRACT"
assert_contains "Issue/PR work:" "$CONTRACT"
assert_contains "humanizer" "$CONTRACT"

for phase in 0-setup 1-plan 2-implement 3-review-loop 4-verify 5-pr 6-complete; do
  phase_file="$ROOT/prompts/phase-audits/${phase}.md"
  assert_contains "prompts/issue-hygiene.md" "$phase_file"
  assert_contains "Issue/PR work:" "$phase_file"
done

for skill in dex dxplan dximplement dxreview dxreviewloop dxverify dxpr dxprreview dxcomplete dxwatchpr; do
  assert_contains "prompts/issue-hygiene.md" "$ROOT/skills/${skill}/SKILL.md"
done

assert_contains "prompts/issue-hygiene.md" "$ROOT/prompts/ticket-instructions.md"
assert_contains "Issue/PR work:" "$ROOT/prompts/ticket-instructions.md"
assert_contains "prompts/issue-hygiene.md" "$ROOT/dx.sh"
assert_contains "Issue/PR work:" "$ROOT/dx.sh"
assert_contains "prompts/issue-hygiene.md" "$ROOT/docs/autonomous-mode.md"

if grep -Fq "do not create new tickets unless asked" \
    "$ROOT/skills/dxcomplete/SKILL.md"; then
  printf 'dxcomplete still suppresses actionable follow-up issue creation\n' >&2
  exit 1
fi

printf 'issue hygiene contract tests passed\n'
