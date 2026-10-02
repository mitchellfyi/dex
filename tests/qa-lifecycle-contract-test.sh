#!/usr/bin/env bash
# The manual QA pass is described in every place the lifecycle talks about
# Phase 2: the launch text, the in-session handoff, the compact checklist, the
# scope lines, the implement workflow and audit, the orchestrator skill, the PR
# workflow and template, and the docs. This pins them to one story.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"

DX="$ROOT/dx.sh"
LOOP="$ROOT/hooks/phase-loop.sh"
SKILL="$ROOT/skills/dxqa/SKILL.md"
WORKFLOW="$ROOT/prompts/workflows/dxqa.md"
IMPLEMENT="$ROOT/prompts/workflows/dximplement.md"
AUDIT="$ROOT/prompts/phase-audits/2-implement.md"

# The skill is a stub over the workflow, like the other lifecycle skills.
assert_file "$SKILL"
assert_file "$WORKFLOW"
python3 - "$SKILL" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(r'^name:\s*["\']?([a-z0-9-]+)["\']?\s*$', text, re.M)
assert match and match.group(1) == "dxqa", match.group(1) if match else None
assert "prompts/workflows/dxqa.md" in text
assert len(text.splitlines()) < 30, "the skill duplicated the workflow"
PY
assert_contains 'directly, not under `dx run-gate`' "$WORKFLOW"
assert_contains 'Resource Discipline' "$WORKFLOW"
assert_contains 'prompts/issue-hygiene.md' "$WORKFLOW"
assert_contains 'dx ps' "$WORKFLOW"
assert_contains 'dx qa report' "$WORKFLOW"
assert_contains 'dx_review_criteria_file' "$WORKFLOW"
assert_contains 'NOT_MET' "$WORKFLOW"

# Both Phase 2 message copies name the pass, and the old drift is gone.
launch_line=$(grep -F 'skill: \"dximplement\"' "$DX" | head -1)
[[ "$launch_line" == *'skill: \"dxqa\"'* ]] || assert_at $LINENO
[[ "$launch_line" == *'dx qa report'* ]] || assert_at $LINENO
[[ "$launch_line" == *'SKIPPED with a reason'* ]] || assert_at $LINENO
handoff_line=$(grep -F 'skill: "dximplement"' "$LOOP" | head -1)
[[ "$handoff_line" == *'skill: "dxqa"'* ]] || assert_at $LINENO
[[ "$handoff_line" == *'dx qa report'* ]] || assert_at $LINENO
[[ "$handoff_line" == *'SKIPPED'* ]] || assert_at $LINENO
assert_not_contains 'before UI edits for baseline evidence' "$LOOP"
assert_not_contains 'before UI edits for baseline evidence' "$DX"
assert_contains 'dx qa show' "$LOOP"
assert_contains 'DO run dxqa' "$DX"

# The implement workflow hands the step to the skill; the audit reads the report.
assert_contains '### 8. Manual QA Pass' "$IMPLEMENT"
assert_not_contains 'Manual Local Smoke Test' "$IMPLEMENT"
assert_contains 'skill: "dxqa"' "$IMPLEMENT"
assert_contains 'dx qa show' "$IMPLEMENT"
assert_contains 'Step 6.5: Manual QA Report' "$AUDIT"
assert_contains 'dx qa show' "$AUDIT"
assert_contains 'NOT_MET' "$AUDIT"
assert_contains 'dxqa' "$ROOT/skills/dex/SKILL.md"
assert_contains 'dx qa report' "$ROOT/skills/dex/SKILL.md"

# Phase 5 summarizes the report in the PR and warns when it is stale.
assert_contains 'dx qa status' "$ROOT/prompts/workflows/dxpr.md"
assert_contains 'dx qa status' "$ROOT/prompts/pr-description.md"
assert_contains 'dx qa status' "$ROOT/prompts/phase-audits/5-pr.md"
assert_contains 'stale' "$ROOT/prompts/workflows/dxpr.md"

# The command, the header, status, retention and docs know the report.
grep -Fq 'echo "  dx qa ' "$DX" || fail "dx help has no qa line"
grep -Eq '^[[:space:]]*qa\) bash "\$DEX_DIR/bin/qa.sh" "\$@" ;;' "$DX" || fail "dx.sh does not route dx qa"
assert_contains 'dx_qa_summary' "$DX"
assert_contains 'dx_qa_mark_completed' "$DX"
assert_contains 'dx_qa_cleanup' "$DX"
assert_contains 'QA:' "$ROOT/bin/status.sh"
assert_contains 'dx_qa_status' "$ROOT/bin/status.sh"
assert_file "$ROOT/docs/qa.md"
assert_contains 'dx qa report' "$ROOT/docs/qa.md"
assert_contains '| `qa.sh` |' "$ROOT/docs/reference.md"
assert_contains 'manual QA report' "$ROOT/docs/ui-capture.md"
grep -F '| 2. Implement |' "$ROOT/docs/autonomous-mode.md" | grep -Fq 'QA report' || fail "autonomous-mode Phase 2 row does not mention the QA report"
assert_contains 'dxqa' "$ROOT/README.md"
assert_contains 'dx qa ' "$ROOT/README.md"
assert_contains 'docs/qa.md' "$ROOT/README.md"
grep -Fq 'qa-report-test.sh' "$ROOT/tests/manifest.tsv" || fail "qa-report-test.sh is not in the manifest"
grep -Fq 'qa-lifecycle-contract-test.sh' "$ROOT/tests/manifest.tsv" || fail "qa-lifecycle-contract-test.sh is not in the manifest"

printf 'qa lifecycle contract tests passed\n'
