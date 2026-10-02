#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"

# A coherent outcome in one repository is one mission: one lifecycle, one
# worktree and branch, normally one PR. Intake and planning used to split the
# work into tickets by reflex and ask which one to implement first. Every
# prompt that can propose a split has to say the default is one lifecycle,
# name the only boundaries that justify a split, and record the split as a
# `decision` before anything extra is created.

# Prose wraps, so each file is compared with its whitespace folded to single
# spaces. The phrases below are exact; a synonym does not count.
flat() { tr -s '[:space:]' ' ' < "$1"; }

# has <line> <flattened text> <phrase>... — every phrase is present
has() {
  local line="$1" text="$2" phrase
  shift 2
  for phrase in "$@"; do
    [[ "$text" == *"$phrase"* ]] || { printf 'missing: %s\n' "$phrase" >&2; assert_at "$line"; }
  done
}

# lacks <line> <flattened text> <phrase>... — no phrase is present
lacks() {
  local line="$1" text="$2" phrase
  shift 2
  for phrase in "$@"; do
    [[ "$text" != *"$phrase"* ]] || { printf 'still present: %s\n' "$phrase" >&2; assert_at "$line"; }
  done
}

# The five boundaries that justify a split, worded the same way everywhere.
BOUNDARY="a different repository, a different release or deploy unit, a different owner or authority, an incompatible environment, or a measured cost that consolidation would exceed"
# The ledger write that records a split before anything extra exists.
DECISION="record decision --actor lead --json"

# Phase 0 intake: one lifecycle by default, split only across a named boundary.
INTAKE="$ROOT/prompts/freeform-intake.md"
assert_file "$INTAKE"
text="$(flat "$INTAKE")"
has "$LINENO" "$text" \
  "A coherent outcome in one repository is one lifecycle: one worktree and branch, and normally one PR" \
  "Internal work packages organise the plan; they are not tickets." \
  "$BOUNDARY" \
  'record it as a `decision` in the mission ledger before creating any extra issue, branch or worktree' \
  "$DECISION" \
  '"boundary":' \
  "Do not launch a second nested lifecycle"
lacks "$LINENO" "$text" \
  "ask which issue this workflow should implement" \
  "propose that split"
# Any input: a URL or document is resolved into tickets and scope before intake.
has "$LINENO" "$text" \
  "Resolving a source first" \
  "A Linear project URL" \
  "A GitHub project URL" \
  "An issue URL on another repository" \
  "Any other URL" \
  "A document path" \
  "intake_source_kind=<linear-project|github-project|issue-elsewhere|page|document>" \
  "never instructions about how you work"
SETUP_AUDIT="$ROOT/prompts/phase-audits/0-setup.md"
assert_file "$SETUP_AUDIT"
text="$(flat "$SETUP_AUDIT")"
has "$LINENO" "$text" "Resolving a source first" "intake_source_kind"
text="$(flat "$ROOT/dx.sh")"
has "$LINENO" "$text" "start with that file's 'Resolving a source' section"

# Phase 1 ticket write-back: sub-issues are work packages of this lifecycle,
# never a queue to pick the first from.
PLAN="$ROOT/prompts/workflows/dxplan.md"
assert_file "$PLAN"
text="$(flat "$PLAN")"
has "$LINENO" "$text" \
  "sub-issues for its work packages" \
  "the scope of this one lifecycle and its one PR" \
  "Sub-issues, when created, are its work packages." \
  "$BOUNDARY" \
  "$DECISION" \
  "each one is a work package of this plan"
lacks "$LINENO" "$text" \
  "which created issue should be implemented first" \
  'small enough for a single `dx <ticket>` lifecycle' \
  "ask which ticket to implement first" \
  "chosen implementation ticket"

# Triage: sub-issues exist for ownership, priority, an external dependency or
# to organise one lifecycle's work packages, not to make diffs smaller.
TRIAGE="$ROOT/skills/dxtriage/SKILL.md"
assert_file "$TRIAGE"
text="$(flat "$TRIAGE")"
has "$LINENO" "$text" \
  "Create sub-issues for separate ownership, prioritisation or an external dependency, or to organise the work packages of a parent that one lifecycle will deliver" \
  "A smaller diff is not a reason" \
  "one lifecycle and one PR" \
  "$BOUNDARY" \
  'as a `decision` in its mission ledger'
lacks "$LINENO" "$text" \
  "Create sub-issues when smaller changes can be reviewed and tested separately"

# Issue hygiene: a part of the same outcome is not a follow-up.
HYGIENE="$ROOT/prompts/issue-hygiene.md"
assert_file "$HYGIENE"
text="$(flat "$HYGIENE")"
has "$LINENO" "$text" \
  "Create a linked follow-up issue automatically" \
  "A part of the same coherent outcome is not a follow-up" \
  "belongs in this lifecycle's plan as a work package" \
  "$BOUNDARY" \
  'record it first as a `decision` in the mission ledger' \
  "$DECISION"

printf 'intake consolidation contract tests passed\n'
