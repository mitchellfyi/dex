#!/usr/bin/env bash
# shellcheck disable=SC2034
# Research harness configuration — sourced by other research scripts.
# All paths and defaults in one place.
# SC2034 suppressed: variables are exported via `source` to consuming scripts.

set -euo pipefail

# ── Paths ──────────────────────────────────────────────────────────────────
RESEARCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEX_DIR="$(cd "$RESEARCH_DIR/.." && pwd)"

SCENARIOS_DIR="$RESEARCH_DIR/scenarios"
WORKSPACES_DIR="$RESEARCH_DIR/workspaces"
RESULTS_DIR="$RESEARCH_DIR/results"
IMPROVEMENTS_DIR="$RESEARCH_DIR/improvements"
SCORES_TSV="$RESULTS_DIR/scores.tsv"

# ── Local tool compatibility ───────────────────────────────────────────────
# Research scripts and rubrics use GNU `timeout`. macOS does not ship it by
# default, so create a local PATH shim when only `gtimeout` is available, or a
# Python fallback when neither binary exists. The fallback implements the subset this harness uses:
# `timeout <seconds>[s|m|h|d] <command> ...` and exits 124 on timeout.
RESEARCH_TOOL_DIR="$RESEARCH_DIR/.tools"
if ! command -v timeout >/dev/null 2>&1; then
  mkdir -p "$RESEARCH_TOOL_DIR"
  if command -v gtimeout >/dev/null 2>&1; then
    cat > "$RESEARCH_TOOL_DIR/timeout" <<'SH'
#!/usr/bin/env bash
exec gtimeout "$@"
SH
    chmod +x "$RESEARCH_TOOL_DIR/timeout"
  else
    cat > "$RESEARCH_TOOL_DIR/timeout" <<'PY'
#!/usr/bin/env python3
import os
import signal
import subprocess
import sys


def parse_duration(raw):
    raw = str(raw or "").strip()
    if not raw:
        raise ValueError("missing duration")
    suffix = raw[-1].lower()
    multiplier = {"s": 1, "m": 60, "h": 3600, "d": 86400}.get(suffix)
    if multiplier is None:
        suffix = ""
        multiplier = 1
    value = float(raw[:-1] if suffix else raw)
    return max(0.0, value * multiplier)


def main():
    if len(sys.argv) < 3:
        print("usage: timeout DURATION COMMAND [ARG...]", file=sys.stderr)
        return 125
    try:
        timeout_s = parse_duration(sys.argv[1])
    except ValueError as exc:
        print(f"timeout: invalid duration: {exc}", file=sys.stderr)
        return 125

    command = sys.argv[2:]
    try:
        proc = subprocess.Popen(command, preexec_fn=os.setsid)
    except FileNotFoundError:
        print(f"timeout: failed to run command '{command[0]}': No such file or directory", file=sys.stderr)
        return 127
    except PermissionError:
        print(f"timeout: failed to run command '{command[0]}': Permission denied", file=sys.stderr)
        return 126

    try:
        return proc.wait(timeout=None if timeout_s <= 0 else timeout_s)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait()
        return 124


if __name__ == "__main__":
    raise SystemExit(main())
PY
    chmod +x "$RESEARCH_TOOL_DIR/timeout"
  fi
  PATH="$RESEARCH_TOOL_DIR:$PATH"
  export PATH
fi

# ── Agent runners ──────────────────────────────────────────────────────────
# Scenario execution defaults to Claude Code. Set RESEARCH_RUNNER=codex or pass
# `research/run.sh --runner codex` to run scenarios through Codex CLI instead.
RESEARCH_RUNNER="${RESEARCH_RUNNER:-claude}"

# ── Claude CLI ─────────────────────────────────────────────────────────────
CLAUDE_MODEL="${CLAUDE_MODEL:-opus}"
CLAUDE_EFFORT="${CLAUDE_EFFORT:-max}"
CLAUDE_BYPASS_FLAG="--dangerously-skip-permissions"
CLAUDE_PERMISSION_MODE="bypassPermissions"

# LLM judge model (opus for quality, matches production)
LLM_JUDGE_MODEL="${LLM_JUDGE_MODEL:-opus}"

# ── Execution ──────────────────────────────────────────────────────────────
# Max seconds per scenario execution (0 = no limit).
# Default: 3600s (1 hour). Per-scenario scenario.json `timeout` values still
# override this. Pass `dx research --scenario-timeout N` (or set
# SCENARIO_TIMEOUT_OVERRIDE in env) to force a value regardless of scenario.json.
SCENARIO_TIMEOUT="${SCENARIO_TIMEOUT:-3600}"

# Max audit loop iterations (keeps scenarios bounded)
MAX_LOOP_ITERATIONS="${MAX_LOOP_ITERATIONS:-20}"

# ── Scoring weights (must sum to 100) ─────────────────────────────────────
# Per-scenario weight overrides live in scenario.json under a "weights" object.
# Overrides must include all six dimensions and sum to 100, otherwise the
# scenario falls back to the globals below.
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
