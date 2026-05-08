#!/usr/bin/env bash
# Research harness — improvement engine
# Analyzes test results, uses Claude to propose DK prompt/skill improvements.
#
# Usage:
#   ./research/improve.sh <run-dir>
#   ./research/improve.sh results/run-20260321-120000

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/safety.sh"

# ── Parse arguments ────────────────────────────────────────────────────────
RUN_DIR="${1:-}"
if [[ -z "$RUN_DIR" ]]; then
  # Try to use latest
  if [[ -L "$RESULTS_DIR/latest" ]]; then
    RUN_DIR="$RESULTS_DIR/$(readlink "$RESULTS_DIR/latest")"
  else
    log_error "Usage: $0 <run-dir>"
    exit 1
  fi
fi

# Resolve relative paths
[[ "$RUN_DIR" != /* ]] && RUN_DIR="$RESULTS_DIR/$RUN_DIR"

if [[ ! -f "$RUN_DIR/summary.json" ]]; then
  log_error "No summary.json found in $RUN_DIR"
  exit 1
fi

log_step "Analyzing results from: $(basename "$RUN_DIR")"

# ── Gather failure details ─────────────────────────────────────────────────

# Build the analysis prompt
ANALYSIS_PROMPT="You are analyzing the results of an AI agent testing harness for Doyaken (DK), a workflow automation framework for Claude Code.

The harness runs DK against predefined scenarios (coding tasks), then scores its output with deterministic rubrics. Your job is to propose specific improvements to DK's skill prompts and audit criteria to improve scores.

## Current Scores

$(cat "$RUN_DIR/summary.json")

## Failure Details
"

# Add per-scenario details for low-scoring scenarios
for scenario_dir in "$RUN_DIR"/*/; do
  [[ -d "$scenario_dir" ]] || continue
  scenario=$(basename "$scenario_dir")
  [[ -f "$scenario_dir/rubric-results.json" ]] || continue

  total=$(json_field "$scenario_dir/rubric-results.json" "total")
  [[ -z "$total" ]] && continue

  # Include scenarios scoring below 80
  if [[ $total -lt 80 ]]; then
    ANALYSIS_PROMPT+="
### Scenario: $scenario (Score: $total/100)

#### Rubric Scores:
$(cat "$scenario_dir/rubric-results.json" 2>/dev/null)

#### Scenario Prompt:
$(cat "$SCENARIOS_DIR/$scenario/prompt.md" 2>/dev/null || echo "(not found)")

#### DK Output (last 100 lines of stderr, which includes hook/guard messages):
$(tail -100 "$scenario_dir/stderr.log" 2>/dev/null || echo "(no stderr)")

"
  fi
done

# Add current DK skill/prompt content
ANALYSIS_PROMPT+="
## Current DK Skill/Prompt Files (these are what you can modify)

### prompts/guardrails.md:
$(cat "$DOYAKEN_DIR/prompts/guardrails.md" 2>/dev/null || echo "(not found)")

### prompts/phase-audits/prompt-loop.md:
$(cat "$DOYAKEN_DIR/prompts/phase-audits/prompt-loop.md" 2>/dev/null || echo "(not found)")

### skills/dkimplement/SKILL.md:
$(head -100 "$DOYAKEN_DIR/skills/dkimplement/SKILL.md" 2>/dev/null || echo "(not found)")

### skills/dkreview/SKILL.md:
$(head -100 "$DOYAKEN_DIR/skills/dkreview/SKILL.md" 2>/dev/null || echo "(not found)")

### skills/dkverify/SKILL.md:
$(head -100 "$DOYAKEN_DIR/skills/dkverify/SKILL.md" 2>/dev/null || echo "(not found)")

## Constraints

You may ONLY propose changes to files matching these patterns:
- skills/*/SKILL.md
- prompts/*.md
- prompts/phase-audits/*.md
- agents/*.md
- hooks/guards/*.md

You MUST NOT modify: dk.sh, lib/*.sh, bin/*.sh, hooks/phase-loop.sh, hooks/guard-handler.py, settings.json

### CRITICAL: Language/Framework Agnosticism

DK prompts (guardrails.md, SKILL.md) must remain **language-agnostic and framework-agnostic**. These prompts are used across ALL coding tasks — Go, Python, Node.js, React, Rust, Java, and any other language.

**DO NOT add:**
- Framework-specific configuration details (e.g., 'in jest.config.js use setupFilesAfterEnv', 'use supertest for Express')
- Language-specific syntax examples (e.g., 'use strings.Builder in Go', 'use React.forwardRef')
- Library-specific setup instructions (e.g., 'add jest-dom to tsconfig.json types array')
- Tool-specific commands (e.g., 'run go vet ./...', 'run npx tsc --noEmit')

**INSTEAD, write principles that apply universally:**
- BAD: 'Use setupFilesAfterEnv in jest.config.js to load jest-dom'
- GOOD: 'When using test assertion libraries that extend the test framework, configure them in the test setup file so the type system and runtime both recognize the extensions.'

- BAD: 'Use strings.Builder for concatenation in Go loops'
- GOOD: 'Do not concatenate strings in a loop with += or equivalent — use the language efficient string builder (StringBuilder, strings.Builder, StringIO, etc.).'

- BAD: 'For Express API tests, use supertest'
- GOOD: 'Use the idiomatic HTTP test client for the framework (the one that manages server lifecycle and provides assertion helpers) rather than raw HTTP calls.'

**The test for any proposed change:** Would this guidance help someone building in a language/framework NOT mentioned in the current scenarios? If it only helps React or only helps Go, it is too specific. Rephrase it as a universal principle.

**Negative examples (anti-patterns) are especially valuable** when written as universal principles. 'Do not return bare arrays from list endpoints' is framework-agnostic. 'Do not use res.send() instead of res.json()' is Express-specific.

## Task

Analyze the failures and propose SPECIFIC, TARGETED changes to DK's skill prompts or audit criteria.

For each proposed change:
1. Explain WHY the current text causes the failure
2. Show the EXACT change in unified diff format
3. Verify the change is **language/framework-agnostic** — rephrase if it isn't

Focus on the lowest-scoring scenarios first. Prefer small, precise edits over broad rewrites. Prefer adding anti-patterns (like 'avoid doing X') alongside existing positive guidance over adding new framework-specific sections.

Output your proposed changes as a series of unified diffs that can be applied with git apply. Wrap each diff in a markdown code block with the diff language tag.
"

# ── Run Claude to generate improvements ────────────────────────────────────
log_step "Generating improvement proposals..."

PROPOSAL_DIR="$IMPROVEMENTS_DIR/proposals"
mkdir -p "$PROPOSAL_DIR"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
PROPOSAL_FILE="$PROPOSAL_DIR/proposal-${TIMESTAMP}.md"
PATCH_FILE="$PROPOSAL_DIR/patch-${TIMESTAMP}.diff"

# Run Claude for analysis
claude_response=$(claude -p \
  --model "$CLAUDE_MODEL" \
  "$CLAUDE_BYPASS_FLAG" \
  --permission-mode "$CLAUDE_PERMISSION_MODE" \
  --effort "$CLAUDE_EFFORT" \
  --output-format text \
  "$ANALYSIS_PROMPT" 2>/dev/null) || {
    log_error "Claude analysis failed"
    exit 1
  }

# Save the full response
echo "$claude_response" > "$PROPOSAL_FILE"
log_info "Proposal saved: $PROPOSAL_FILE"

# Extract the diff portion
python3 - "$PROPOSAL_FILE" "$PATCH_FILE" <<'PYEOF'
import sys, re

with open(sys.argv[1]) as f:
    content = f.read()

# Extract all diff blocks
diffs = []
in_diff = False
current_diff = []

for line in content.split('\n'):
    if line.startswith('```diff'):
        in_diff = True
        current_diff = []
        continue
    if line.startswith('```') and in_diff:
        in_diff = False
        if current_diff:
            diffs.append('\n'.join(current_diff))
        continue
    if in_diff:
        current_diff.append(line)

# Also catch diffs not in code blocks
if not diffs:
    for line in content.split('\n'):
        if line.startswith('--- a/') or line.startswith('diff --git'):
            in_diff = True
            current_diff = [line]
            continue
        if in_diff:
            if line.startswith('--- a/') or line.startswith('diff --git'):
                if current_diff:
                    diffs.append('\n'.join(current_diff))
                current_diff = [line]
            else:
                current_diff.append(line)
    if current_diff:
        diffs.append('\n'.join(current_diff))

# Fix hunk headers: Claude often gets line counts wrong.
# Recalculate old_count and new_count from actual hunk content.
import os

def fix_hunk_headers(diff_text):
    """Recalculate @@ line counts from actual content."""
    lines = diff_text.split('\n')
    result = []
    hunk_start = None
    hunk_lines = []

    def flush_hunk():
        if hunk_start is None or not hunk_lines:
            return
        old_count = sum(1 for l in hunk_lines if l.startswith(' ') or l.startswith('-'))
        new_count = sum(1 for l in hunk_lines if l.startswith(' ') or l.startswith('+'))
        # Parse the original @@ header for old_start and new_start
        m = re.match(r'@@ -(\d+),?\d* \+(\d+),?\d* @@(.*)', hunk_start)
        if m:
            old_start, new_start, rest = m.group(1), m.group(2), m.group(3)
            result.append(f'@@ -{old_start},{old_count} +{new_start},{new_count} @@{rest}')
        else:
            result.append(hunk_start)  # Can't parse, keep original
        result.extend(hunk_lines)

    for line in lines:
        if line.startswith('@@'):
            flush_hunk()
            hunk_start = line
            hunk_lines = []
        elif hunk_start is not None and (line.startswith(' ') or line.startswith('+') or line.startswith('-')):
            hunk_lines.append(line)
        else:
            flush_hunk()
            hunk_start = None
            hunk_lines = []
            result.append(line)

    flush_hunk()
    return '\n'.join(result)

# Fix all diffs and write individual patch files
fixed_diffs = [fix_hunk_headers(d) for d in diffs]

all_content = '\n'.join(fixed_diffs) + '\n' if fixed_diffs else ''
with open(sys.argv[2], 'w') as f:
    f.write(all_content)

for i, diff_text in enumerate(fixed_diffs):
    part_file = f"{sys.argv[2]}.{i}"
    with open(part_file, 'w') as f:
        f.write(diff_text + '\n')

if fixed_diffs:
    print(f"Extracted and fixed {len(fixed_diffs)} diff(s)")
else:
    print("No diffs found in response")
PYEOF

if [[ ! -s "$PATCH_FILE" ]]; then
  log_warn "No actionable diffs extracted from Claude's response"
  log_info "Review the full proposal: $PROPOSAL_FILE"
  exit 1
fi

# ── Validate scope ─────────────────────────────────────────────────────────
log_step "Validating proposed changes..."

if ! cat "$PATCH_FILE" | safety_validate_diff; then
  log_error "Proposed changes touch files outside allowed scope. Rejecting."
  exit 1
fi

log_success "Proposal validated. Patch ready: $PATCH_FILE"
echo ""
echo "To apply:  cd $DOYAKEN_DIR && git apply $PATCH_FILE"
echo "To review: cat $PROPOSAL_FILE"

# Output the patch file path for loop.sh
echo "$PATCH_FILE"
