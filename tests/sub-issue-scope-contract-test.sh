#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"

# A parent ticket's sub-issues are scope: one lifecycle, one PR, all children.
# Each phase that touches the tracker has to say so, or an agent handed a
# consolidated ticket plans only the parent and leaves the children behind.

SETUP="$ROOT/prompts/ticket-instructions.md"
assert_file "$SETUP"
assert_contains "Sub-issues are scope, not references" "$SETUP"
assert_contains "list_issues" "$SETUP"
assert_contains "parentId" "$SETUP"
assert_contains "Do not skip, defer or hand off a sub-issue" "$SETUP"
assert_contains "Do not change their status during" "$SETUP"

PLAN="$ROOT/prompts/workflows/dxplan.md"
assert_file "$PLAN"
assert_contains "Read every sub-issue of the ticket" "$PLAN"
assert_contains "each one is a work package of this plan" "$PLAN"
assert_contains "of the ticket and of each of its sub-issues" "$PLAN"
assert_contains "Sub-issues are required scope, not future work" "$PLAN"
# Ticket write-back used to size each sub-issue for its own lifecycle and ask
# which one to implement first; both contradict sub-issues being this
# lifecycle's scope. tests/mission/intake-consolidation-test.sh owns the rest.
assert_not_contains "which created issue should be implemented first" "$PLAN"
assert_not_contains 'small enough for a single `dx <ticket>` lifecycle' "$PLAN"

PR="$ROOT/prompts/workflows/dxpr.md"
assert_file "$PR"
assert_contains "If the ticket has sub-issues, the body lists every one of them" "$PR"

COMPLETE="$ROOT/skills/dxcomplete/SKILL.md"
assert_file "$COMPLETE"
assert_contains "Mark each sub-issue Done as well" "$COMPLETE"
assert_contains "each sub-issue whose acceptance criteria this PR meets" "$COMPLETE"

assert_contains "A ticket's sub-issues are scope" "$ROOT/docs/autonomous-mode.md"

printf 'sub-issue scope contract tests passed\n'
