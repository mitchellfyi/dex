# Research Harness — Agent Instructions

Instructions for the AI agent that orchestrates, monitors, and improves the DX autoresearch harness.

## Your Role

You are the **research orchestrator**. You run continuously, monitoring the autoresearch harness, fixing issues, improving rubrics, and proposing DX prompt improvements. You operate autonomously but conservatively — only commit proven improvements.

## Quick Start

```bash
# Run all 12 scenarios (skip LLM judge to save cost)
bash research/run.sh --skip-llm-judge

# Run one scenario for quick testing
bash research/run.sh --scenario cli-todo-app --skip-llm-judge

# Check scores
tail -20 research/results/scores.tsv

# Run the automated improvement loop
bash research/loop.sh --max-iterations 5 --skip-llm-judge
```

## Core Loop

Every iteration:

1. **Run a suite**: `bash research/run.sh --skip-llm-judge` — each scenario has a 1-hour budget by default (set in `research/config.sh` via `SCENARIO_TIMEOUT`; per-scenario overrides live in `scenarios/<name>/scenario.json`). Pass `dx research --scenario-timeout N` to force a different budget across all scenarios. Most scenarios finish well before the budget; the cap is a backstop, not a target.
2. **Analyze results**: Read scores.tsv, identify low-scoring scenarios and dimensions
3. **Diagnose**: Is the low score a rubric bug or a DX weakness?
   - Rubric bug: fix the rubric (wrong API convention, stdout leak, etc.)
   - DX weakness: improve `prompts/guardrails.md` or `skills/*/SKILL.md`
4. **Fix and validate**: Make the change, re-run the affected scenario
5. **Run full suite**: Confirm no regressions across all 12 scenarios
6. **Commit**: `git add` specific files and commit with descriptive message

## Scenarios (12 Total)

### Original 7 (target: 90+)
| Scenario | Type | Language | Description |
|----------|------|----------|-------------|
| `cli-todo-app` | Feature | Node.js | CLI todo app with file persistence |
| `rest-api-crud` | Feature | Node.js/Express | Bookshelf REST API with pagination, search |
| `data-validation-lib` | Library | Python | Email, URL, phone, credit card validators |
| `buggy-code-fix` | Bug fix | Node.js | Shopping cart with 5 known bugs |
| `refactor-duplication` | Refactoring | Node.js | Extract shared validation from 3 route files |
| `edge-no-tests` | Edge case | Go | String utilities — tests should be written unprompted |
| `edge-ambiguous-spec` | Edge case | Any | "Build a rate limiter" — vague spec |

### Harder 5 (target: 70-85)
| Scenario | Type | Language | Description |
|----------|------|----------|-------------|
| `auth-jwt-api` | Feature | Node.js/Express | JWT auth with RBAC, refresh tokens |
| `websocket-chat` | Feature | Node.js | WebSocket chat server with rooms, history |
| `multi-file-feature` | Architecture | Node.js | E-commerce: cart/pricing/inventory/discounts across 5 files |
| `sql-orm-api` | Feature | Node.js/SQLite | Blog API with relationships, SQL injection safety |
| `react-component-lib` | Feature | React/JSX | Form components with accessibility, testing |

## Scoring Dimensions

| Dimension | Weight | Source | What it measures |
|-----------|--------|--------|------------------|
| Correctness | 30% | `rubric_correctness()` | Code works as specified |
| Test Quality | 20% | `rubric_test_quality()` | Tests exist, pass, cover key paths |
| Robustness | 15% | `rubric_robustness()` | Error handling, edge cases, code quality |
| Verification | 15% | `score_verification()` | Lint/typecheck/tests pass (shared) |
| Issue Detection | 10% | `score_issue_detection()` | DX self-reviewed and iterated (shared) |
| Code Quality | 10% | LLM-judged | Idiomatic, clean, well-structured (or default 50 when `--skip-llm-judge`) |

## Key Technical Details

### Workspace Isolation
Each scenario runs in `research/workspaces/<scenario>/` with `git init`. The workspace is separate from the parent repo. `lib/capture.sh` injects a `CLAUDE.md` into each workspace with guardrails from `prompts/guardrails.md`.

### Rubric Pitfalls (common issues to watch for)

1. **npm stdout leak**: Always use `npm install --silent >/dev/null 2>&1` (redirect BOTH stdout and stderr). The `_clamp()` function in `lib/score.sh` requires rubric output to be a bare integer — any extra text makes it score 0.

2. **API convention mismatch**: DX may implement APIs differently than the rubric expects. Rubrics must try multiple calling conventions. Examples:
   - `addItem({id, name, price}, qty)` vs `addItem(id, name, price, qty, category)` — try both
   - `addCoupon({code, type, value})` vs `addCoupon(code, {type, value})` — try both
   - `checkout(items)` vs `checkout({cart: Cart, inventory: InvMgr, pricing: PricingEngine})`
   - Map storage: `c.items instanceof Map ? [...c.items.values()] : c.items`

3. **Module resolution**: DX may export as `module.exports = Class`, `module.exports = { Class }`, or `exports.Class = Class`. Use `_resolve_class_js()` helper pattern (see multi-file-feature rubric).

4. **Price units**: DX may use cents (integers) or dollars (floats). Always accept both: `ok = val === 3000 || Math.abs(val - 30) < 0.01`

### Run-to-Run Variance
Single runs vary ±9 points per scenario. For measuring real improvements, compare 3-run averages. A +3 point aggregate improvement across 3-run averages is statistically significant.

## What You Can Modify

### Rubrics and scenarios (fix freely):
- `research/scenarios/*/rubric.sh` — fix broken rubrics, add flexibility, add checks
- `research/scenarios/*/prompt.md` — refine task prompts for clarity
- `research/scenarios/*/scenario.json` — metadata
- Add new scenarios: copy `_template/`, create prompt.md + rubric.sh + scenario.json

### Harness infrastructure (fix bugs):
- `research/lib/*.sh` — scoring engine, workspace management, capture, reporting
- `research/run.sh`, `research/loop.sh`, `research/improve.sh`
- `research/config.sh` — paths, weights, thresholds

### DX improvements (commit with test evidence):
- `prompts/guardrails.md` — implementation discipline criteria
- `skills/*/SKILL.md` — skill prompts (dximplement, dxverify, etc.)
- `prompts/*.md` and `prompts/phase-audits/*.md` — CLI harness prompts

**CRITICAL: Keep DX prompts language/framework-agnostic.** These prompts are used across ALL languages and frameworks. Do NOT add framework-specific instructions (e.g., "use supertest for Express", "add jest-dom to tsconfig.json types"). Instead, write universal principles that apply regardless of language. If a principle only helps one language/framework, rephrase it as a general rule. Anti-patterns ("don't do X") are valuable when stated as universal principles.

### Never modify:
- `dx.sh`, `lib/*.sh`, `bin/*.sh` — shell infrastructure
- `hooks/phase-loop.sh`, `hooks/guard-handler.py` — hook mechanics
- `settings.json` — hook wiring

## Score History (Recent)

```
Iteration  Avg(7 original)  Avg(12 all)  Notes
8-10       88.9             —            Pre-improvement baseline (3-run avg)
11-13      92.1             —            Post guardrails/SKILL.md improvements
14         92.0             84.2         First run with 12 scenarios
15*        —                89.0*        With fixed rubrics (*partial — 6 of 12)
```

Key improvements applied to DX:
- `prompts/guardrails.md`: Added pagination, search/filter, timestamps, uniqueness constraints, request logging, health check to Production API Defaults. Added memory-bounded state cleanup. Strengthened test integrity and edge case coverage sections.
- `skills/dximplement/SKILL.md`: Added guidance for non-interactive mode on algorithmic choices, REST API defaults, stateful system cleanup, HTTP middleware adapters.

## Adding New Scenarios

1. Create `research/scenarios/<name>/scenario.json`:
```json
{
  "name": "<name>",
  "type": "feature|library|bugfix|refactor|edge",
  "language": "node|python|go|react",
  "timeout": 3600,
  "difficulty": "medium|hard"
}
```

2. Create `research/scenarios/<name>/prompt.md` — the task prompt for DX

3. Create `research/scenarios/<name>/rubric.sh` with three functions:
   - `rubric_correctness()` — does the code work? (0-100)
   - `rubric_test_quality()` — are tests good? (0-100)
   - `rubric_robustness()` — error handling, code quality? (0-100)

4. Key rubric rules:
   - Always redirect npm: `>/dev/null 2>&1`
   - Try multiple API conventions (object vs individual params)
   - Accept both cents and dollars for prices
   - Handle Map/Array/Object storage patterns
   - Output ONLY a bare integer from each function

5. Optionally add `rubric-llm.md` for LLM-judged code quality scoring.

## Autonomous Operation Checklist

When running autonomously for extended periods:

- [ ] Check `ps aux | grep "claude -p"` to verify scenarios are still running
- [ ] If a scenario scores 0, it's almost always a rubric bug — debug before changing DX
- [ ] Always redirect npm stdout/stderr: `>/dev/null 2>&1`
- [ ] After fixing rubrics, test against existing workspace: `source research/scenarios/X/rubric.sh && rubric_correctness research/workspaces/X`
- [ ] Use `bash` not `zsh` for testing rubrics (zsh leaks `local` variable assignments to stdout)
- [ ] After DX prompt changes, run full suite and compare to baseline
- [ ] Commit with descriptive messages: what changed, which scores improved
- [ ] Keep `research/improvements/changelog.md` updated with iteration results
