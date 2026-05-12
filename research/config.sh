#!/usr/bin/env bash
# shellcheck disable=SC2034
# Research harness configuration — sourced by other research scripts.
# All paths and defaults in one place.
# SC2034 suppressed: variables are exported via `source` to consuming scripts.

set -euo pipefail

# ── Paths ──────────────────────────────────────────────────────────────────
RESEARCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOYAKEN_DIR="$(cd "$RESEARCH_DIR/.." && pwd)"

SCENARIOS_DIR="$RESEARCH_DIR/scenarios"
WORKSPACES_DIR="$RESEARCH_DIR/workspaces"
RESULTS_DIR="$RESEARCH_DIR/results"
IMPROVEMENTS_DIR="$RESEARCH_DIR/improvements"
SCORES_TSV="$RESULTS_DIR/scores.tsv"

# ── Claude CLI ─────────────────────────────────────────────────────────────
CLAUDE_MODEL="${CLAUDE_MODEL:-opus}"
CLAUDE_EFFORT="${CLAUDE_EFFORT:-max}"
CLAUDE_BYPASS_FLAG="--dangerously-skip-permissions"
CLAUDE_PERMISSION_MODE="bypassPermissions"

# LLM judge model (opus for quality, matches production)
LLM_JUDGE_MODEL="${LLM_JUDGE_MODEL:-opus}"

# ── Execution ──────────────────────────────────────────────────────────────
# Max seconds per scenario execution (0 = no limit)
SCENARIO_TIMEOUT="${SCENARIO_TIMEOUT:-900}"

# Max audit loop iterations (keeps scenarios bounded)
MAX_LOOP_ITERATIONS="${MAX_LOOP_ITERATIONS:-20}"

# ── Scoring weights (must sum to 100) ─────────────────────────────────────
W_CORRECTNESS=30
W_TEST_QUALITY=20
W_ROBUSTNESS=15
W_VERIFICATION=15
W_ISSUE_DETECTION=10
W_CODE_QUALITY=10

# ── Improvement loop ──────────────────────────────────────────────────────
# Max improvement iterations per loop.sh invocation
MAX_IMPROVE_ITERATIONS="${MAX_IMPROVE_ITERATIONS:-20}"

# Cumulative cost limit in USD (abort loop if exceeded)
COST_LIMIT_USD="${COST_LIMIT_USD:-200}"

# Regression threshold: revert if aggregate score drops by more than this %
REGRESSION_THRESHOLD="${REGRESSION_THRESHOLD:-5}"

# Scenario regression threshold: revert if any single scenario drops by this %
SCENARIO_REGRESSION_THRESHOLD="${SCENARIO_REGRESSION_THRESHOLD:-20}"

# Smoke test scenario (cheapest/fastest, used for quick validation)
SMOKE_SCENARIO="${SMOKE_SCENARIO:-edge-no-tests}"

# ── Allowed modification paths (for improvement loop scope validation) ────
ALLOWED_MODIFY_PATTERNS=(
  "skills/*/SKILL.md"
  "prompts/*.md"
  "prompts/phase-audits/*.md"
  "agents/*.md"
  "hooks/guards/*.md"
  "research/config.sh"
  "research/run.sh"
  "research/loop.sh"
  "research/improve.sh"
  "research/lib/*.sh"
  "research/scenarios/*/prompt.md"
  "research/scenarios/*/rubric.sh"
  "research/scenarios/*/scenario.json"
)
