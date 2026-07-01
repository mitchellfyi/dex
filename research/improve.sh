#!/usr/bin/env bash
# Research harness — improvement engine
# Analyzes test results, uses Claude to propose DX prompt/skill improvements.
#
# Usage:
#   ./research/improve.sh <run-dir>
#   ./research/improve.sh run-20260321-120000

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=research/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=research/lib/safety.sh
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

stream_excerpt() {
  local stream_file="$1"

  [[ -f "$stream_file" ]] || {
    echo "(no stream)"
    return 0
  }

  python3 - "$stream_file" <<'PYEOF'
import collections
import json
import sys

stream_file = sys.argv[1]

def compact(value, limit=900):
    if value is None:
        return ""
    if not isinstance(value, str):
        value = json.dumps(value, ensure_ascii=False, sort_keys=True)
    value = " ".join(value.split())
    if len(value) > limit:
        return value[:limit] + "... [truncated]"
    return value

events = collections.deque(maxlen=80)
with open(stream_file, encoding="utf-8", errors="replace") as fh:
    for raw in fh:
        raw = raw.strip()
        if not raw:
            continue
        try:
            event = json.loads(raw)
        except json.JSONDecodeError:
            continue
        events.append(event)

for event in events:
    event_type = event.get("type", "event")
    message = event.get("message") or {}
    role = message.get("role", event_type)
    content = message.get("content") or []
    if not isinstance(content, list):
        content = [{"type": "text", "text": content}]

    if not content and "tool_use_result" in event:
        print(f"{role}: tool result {compact(event.get('tool_use_result'), 700)}")
        continue

    for item in content:
        item_type = item.get("type")
        if item_type == "thinking":
            continue
        if item_type == "text":
            print(f"{role}: {compact(item.get('text'), 900)}")
            continue
        if item_type == "tool_use":
            name = item.get("name", "tool")
            tool_input = item.get("input") or {}
            if name == "Bash":
                detail = tool_input.get("description") or tool_input.get("command")
                print(f"{role}: tool_use Bash - {compact(detail, 500)}")
            elif name in {"Write", "Edit", "MultiEdit", "Read"}:
                path = tool_input.get("file_path") or tool_input.get("path") or "(unknown path)"
                content_value = tool_input.get("content")
                suffix = f" ({len(content_value)} chars)" if isinstance(content_value, str) else ""
                print(f"{role}: tool_use {name} {path}{suffix}")
            else:
                print(f"{role}: tool_use {name} - {compact(tool_input, 500)}")
            continue
        if item_type == "tool_result":
            print(f"{role}: tool_result {compact(item.get('content'), 900)}")
            continue
        print(f"{role}: {item_type or 'content'} {compact(item, 500)}")
PYEOF
}

# Build the analysis prompt
ANALYSIS_PROMPT="You are analyzing the results of an AI agent testing harness for Dex (DX), a workflow automation framework for Claude Code.

The harness runs DX against predefined scenarios (coding tasks), then scores its output with deterministic rubrics. Your job is to propose specific improvements to DX's skill prompts and audit criteria to improve scores.

## Current Scores

$(cat "$RUN_DIR/summary.json")

## Failure Details
"

# Add per-scenario details for low-scoring, weak-dimension, or timed-out scenarios.
for scenario_dir in "$RUN_DIR"/*/; do
  [[ -d "$scenario_dir" ]] || continue
  scenario=$(basename "$scenario_dir")
  [[ -f "$scenario_dir/rubric-results.json" ]] || continue

  total=$(json_field "$scenario_dir/rubric-results.json" "total")
  [[ -z "$total" ]] && continue

  include_reason=""

  if [[ "$total" =~ ^[0-9]+$ && $total -lt 80 ]]; then
    include_reason="total score below 80"
  fi

  timing_file="$scenario_dir/timing.json"
  exit_code="0"
  if [[ -f "$timing_file" ]]; then
    exit_code=$(json_field "$timing_file" "exit_code")
    [[ "$exit_code" =~ ^[0-9]+$ ]] || exit_code="0"
    if [[ "$exit_code" -ne 0 ]]; then
      include_reason="${include_reason:+$include_reason; }exit code $exit_code"
    fi
  fi

  for dimension in correctness test_quality robustness verification issue_detection; do
    dimension_score=$(json_field "$scenario_dir/rubric-results.json" "$dimension")
    if [[ "$dimension_score" =~ ^[0-9]+$ && "$dimension_score" -lt 75 ]]; then
      include_reason="${include_reason:+$include_reason; }$dimension score $dimension_score"
    fi
  done

  if [[ -n "$include_reason" ]]; then
    ANALYSIS_PROMPT+="
### Scenario: $scenario (Score: $total/100)

Included because: $include_reason

#### Timing:
$(cat "$timing_file" 2>/dev/null || echo "(no timing)")

#### Rubric Scores:
$(cat "$scenario_dir/rubric-results.json" 2>/dev/null)

#### Scenario Prompt:
$(cat "$SCENARIOS_DIR/$scenario/prompt.md" 2>/dev/null || echo "(not found)")

#### DX Output (last 100 lines of stderr, which includes hook/guard messages):
$(tail -100 "$scenario_dir/stderr.log" 2>/dev/null || echo "(no stderr)")

#### DX Stream Summary (last 80 events):
$(stream_excerpt "$scenario_dir/stream.jsonl")

"
  fi
done

# Add current DX skill/prompt content
ANALYSIS_PROMPT+="
## Current DX Skill/Prompt Files (these are what you can modify)

### prompts/guardrails.md:
$(cat "$DEX_DIR/prompts/guardrails.md" 2>/dev/null || echo "(not found)")

### prompts/phase-audits/prompt-loop.md:
$(cat "$DEX_DIR/prompts/phase-audits/prompt-loop.md" 2>/dev/null || echo "(not found)")

### skills/dximplement/SKILL.md:
$(head -100 "$DEX_DIR/skills/dximplement/SKILL.md" 2>/dev/null || echo "(not found)")

### skills/dxreview/SKILL.md:
$(head -100 "$DEX_DIR/skills/dxreview/SKILL.md" 2>/dev/null || echo "(not found)")

### skills/dxverify/SKILL.md:
$(head -100 "$DEX_DIR/skills/dxverify/SKILL.md" 2>/dev/null || echo "(not found)")

## Constraints

You may ONLY propose changes to files matching these patterns:
- skills/*/SKILL.md
- prompts/*.md
- prompts/phase-audits/*.md
- hooks/guards/*.md

You MUST NOT modify: dx.sh, lib/*.sh, bin/*.sh, hooks/phase-loop.sh, hooks/guard-handler.py, settings.json

### CRITICAL: Language/Framework Agnosticism

DX prompts (guardrails.md, SKILL.md) must remain **language-agnostic and framework-agnostic**. These prompts are used across ALL coding tasks — Go, Python, Node.js, React, Rust, Java, and any other language.

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

Analyze the failures and propose SPECIFIC, TARGETED changes to DX's skill prompts or audit criteria.

For each proposed change:
1. Explain WHY the current text causes the failure
2. Show the EXACT change in unified diff format
3. Verify the change is **language/framework-agnostic** — rephrase if it isn't

Focus on the lowest-scoring scenarios first. Prefer small, precise edits over broad rewrites. Prefer adding anti-patterns (like 'avoid doing X') alongside existing positive guidance over adding new framework-specific sections.

Output your proposed changes as a series of unified diffs that can be applied with git apply. Wrap each diff in a markdown code block with the diff language tag.
"

# ── Run analyzer to generate improvements ──────────────────────────────────
log_step "Generating improvement proposals..."

PROPOSAL_DIR="$IMPROVEMENTS_DIR/proposals"
mkdir -p "$PROPOSAL_DIR"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
PROPOSAL_FILE="$PROPOSAL_DIR/proposal-${TIMESTAMP}.md"
PATCH_FILE="$PROPOSAL_DIR/patch-${TIMESTAMP}.diff"
ANALYZER="${RESEARCH_IMPROVE_RUNNER:-claude}"

run_claude_analysis() {
  claude -p \
    --model "$CLAUDE_MODEL" \
    "$CLAUDE_BYPASS_FLAG" \
    --permission-mode "$CLAUDE_PERMISSION_MODE" \
    --effort "$CLAUDE_EFFORT" \
    --output-format text \
    "$ANALYSIS_PROMPT"
}

run_codex_analysis() {
  local output_file="$1"
  DX_CODEX_OUTPUT_LAST_MESSAGE="$output_file" \
    bash "$DEX_DIR/bin/dxcodex.sh" exec -- "$ANALYSIS_PROMPT" >/dev/null
}

claude_response=""
analysis_stderr="$PROPOSAL_DIR/proposal-${TIMESTAMP}.stderr.log"
case "$ANALYZER" in
  claude)
    if ! claude_response=$(run_claude_analysis 2>"$analysis_stderr"); then
      if command -v codex >/dev/null 2>&1; then
        log_warn "Claude analysis failed; falling back to Codex. See $analysis_stderr"
        if ! run_codex_analysis "$PROPOSAL_FILE" 2>>"$analysis_stderr"; then
          log_error "Codex analysis failed. See $analysis_stderr"
          exit 1
        fi
        claude_response=$(cat "$PROPOSAL_FILE" 2>/dev/null || true)
      else
        log_error "Claude analysis failed. See $analysis_stderr"
        exit 1
      fi
    fi
    ;;
  codex)
    if ! run_codex_analysis "$PROPOSAL_FILE" 2>"$analysis_stderr"; then
      log_error "Codex analysis failed. See $analysis_stderr"
      exit 1
    fi
    claude_response=$(cat "$PROPOSAL_FILE" 2>/dev/null || true)
    ;;
  *)
    log_error "Unknown research improvement analyzer: $ANALYZER"
    log_info "Supported analyzers: claude, codex"
    exit 1
    ;;
esac

if [[ -z "$claude_response" ]]; then
  log_error "Analyzer produced no response. See $analysis_stderr"
  exit 1
fi

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

apply_hint="cd $DEX_DIR && git apply $PATCH_FILE"
patch_applicable=0
if git -C "$DEX_DIR" apply --check "$PATCH_FILE" 2>/dev/null; then
  patch_applicable=1
else
  part_idx=0
  applicable_parts=0
  while [[ -f "${PATCH_FILE}.${part_idx}" ]]; do
    if (cd "$DEX_DIR" && patch -p1 --dry-run --fuzz=3 --no-backup-if-mismatch < "${PATCH_FILE}.${part_idx}" >/dev/null 2>&1); then
      applicable_parts=$((applicable_parts + 1))
    else
      log_warn "Patch part $part_idx is not applicable"
    fi
    part_idx=$((part_idx + 1))
  done

  if [[ $part_idx -gt 0 && $applicable_parts -eq $part_idx ]]; then
    patch_applicable=1
    apply_hint="cd $DEX_DIR && for f in $PATCH_FILE.*; do patch -p1 --fuzz=3 --no-backup-if-mismatch < \"\$f\"; done"
  fi
fi

if [[ $patch_applicable -ne 1 ]]; then
  log_error "Proposed patch is within scope but is not applicable. Rejecting."
  log_info "Review the full proposal: $PROPOSAL_FILE"
  exit 1
fi

log_success "Proposal validated. Patch ready: $PATCH_FILE"
echo ""
echo "To apply:  $apply_hint"
echo "To review: cat $PROPOSAL_FILE"

# Output the patch file path for loop.sh
echo "$PATCH_FILE"
