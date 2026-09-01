#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"

assert_contains "dx_ticket_branch_prepare" "$ROOT/prompts/ticket-instructions.md"
assert_contains "ticket_branch_source" "$ROOT/prompts/phase-audits/0-setup.md"
assert_contains "origin/<tracker-branch>" "$ROOT/prompts/phase-audits/0-setup.md"
assert_contains "dx_ticket_branch_prepare" "$ROOT/skills/dex/SKILL.md"
assert_contains "dx_ticket_branch_prepare" "$ROOT/skills/dxplan/SKILL.md"

if grep -Fq 'git branch -m {{BRANCH}} <suggested-branch-name>' \
    "$ROOT/prompts/ticket-instructions.md"; then
  printf 'ticket setup still bypasses remote branch adoption\n' >&2
  exit 1
fi

printf 'ticket branch instruction tests passed\n'
