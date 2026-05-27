#!/usr/bin/env bash
# shellcheck disable=SC1091
# dex init — bootstrap current repo for Dex
# Creates .dex/ skeleton, then uses Claude Code CLI to analyze
# the codebase and generate project-specific configuration.
set -euo pipefail

source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

INIT_PROVIDER_SESSION_ID=""
INIT_RUN_SESSION_ID=""
INIT_RUN_ID=""
__dx_init_cleanup() {
  local status=$?
  if [[ -n "${INIT_RUN_ID:-}" ]]; then
    if [[ $status -eq 0 ]]; then
      dx_event_emit_safe "$INIT_RUN_ID" "run.completed" "info" "Dex init completed" "" "{\"command\":\"dx init\"}"
      dx_run_write_summary_safe "$INIT_RUN_ID" "completed" "Dex init completed"
    elif [[ $status -eq 130 ]]; then
      dx_event_emit_safe "$INIT_RUN_ID" "run.blocked" "warn" "Dex init interrupted" "" "{\"command\":\"dx init\",\"exit_code\":${status}}"
      dx_run_write_summary_safe "$INIT_RUN_ID" "blocked" "Dex init interrupted"
    else
      dx_event_emit_safe "$INIT_RUN_ID" "run.failed" "error" "Dex init failed" "" "{\"command\":\"dx init\",\"exit_code\":${status}}"
      dx_run_write_summary_safe "$INIT_RUN_ID" "failed" "Dex init failed with code ${status}"
    fi
  fi
  if [[ -n "${INIT_PROVIDER_SESSION_ID:-}" ]]; then
    dx_provider_cleanup_session_state "$INIT_PROVIDER_SESSION_ID" 2>/dev/null || true
  fi
}
trap __dx_init_cleanup EXIT
trap 'printf "\nInterrupted.\n"; exit 130' INT

usage() {
  cat <<'USAGE'
Usage: dx init [options]

Bootstrap the current repository with Dex project context.

Options:
  --skip-analysis                    Create/update local files without provider analysis
  --skip-config                      Skip interactive reviewer/config prompts
  --install-maintenance-workflow     Install .github/workflows/dx-maintain.yml
  -h, --help                         Show this help
USAGE
}

# Parse all flags upfront so they work independently of each other.
# (Previously --skip-config was unreachable when --skip-analysis was set
# because the analysis section exited early before config flag was parsed.)
SKIP_ANALYSIS=0
SKIP_CONFIG=0
INSTALL_MAINTENANCE_WORKFLOW=0
for arg in "$@"; do
  case "$arg" in
    --skip-analysis) SKIP_ANALYSIS=1 ;;
    --skip-config)   SKIP_CONFIG=1 ;;
    --install-maintenance-workflow) INSTALL_MAINTENANCE_WORKFLOW=1 ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      dx_error "Unknown init option: $arg"
      usage
      exit 1
      ;;
  esac
done

# Must be in a git repo
if ! repo_root=$(git rev-parse --show-toplevel 2>/dev/null); then
  repo_root=""
fi
if [[ -z "$repo_root" ]]; then
  dx_error "Not in a git repository."
  exit 1
fi

repo_name=$(basename "$repo_root")
echo "Dex — Init: $repo_name"
echo ""

INIT_RUN_SESSION_ID="init-$(dx_unique_session_id)"
if INIT_RUN_ID=$(dx_run_prepare "$INIT_RUN_SESSION_ID" "$repo_root" "current-checkout" "$repo_name" "dx init $*" "dx init"); then
  export DEX_RUN_ID="$INIT_RUN_ID"
  dx_run_maybe_emit_started "$INIT_RUN_ID" "Dex init started" "{\"command\":\"dx init\"}"
  dx_info "Run id: $INIT_RUN_ID"
else
  dx_warn "Continuing without a local Dex run journal."
  INIT_RUN_ID=""
fi

# ── 1. Create .dex/ skeleton ──────────────────────────────────────

mkdir -p "$repo_root/.dex"

# .gitignore for worktree artifacts (don't overwrite — user may have added custom entries)
dex_gitignore="$repo_root/.dex/.gitignore"
if [[ ! -f "$dex_gitignore" ]]; then
  cat > "$dex_gitignore" << 'GITIGNORE'
worktrees/
GITIGNORE
  dx_done "Created .dex/.gitignore"
else
  dx_ok ".dex/.gitignore already exists"
fi

# Minimal dex.md (will be overwritten by codebase analysis if run)
dex_md="$repo_root/.dex/dex.md"
if [[ ! -f "$dex_md" ]]; then
  cat > "$dex_md" << 'DEXMD'
# Dex

This project uses Dex for workflow automation.

## Autonomous workflow

From the terminal, run `dx <ticket-number>` to start the full autonomous lifecycle (Plan → Implement → Review → Verify & Commit → PR → Complete) in an isolated worktree. You can also run `dx "description"` for freeform tasks, or `dx --no-worktree <ticket-or-description>` to set up the normal lifecycle branch in the current checkout without creating a worktree.

## One-off prompt (no ticket)

Run `dxloop <prompt>` to execute a prompt in a loop until Claude confirms it's fully implemented. Works in the current directory — no worktree or ticket needed.

## Agent and model

Dex defaults to Claude on Opus 4.7. Override a single run with:

```bash
dx --agent codex --model gpt-5.3-codex "<task>"
```

Use `.dex/providers.json` for repo defaults, or `dx provider use --repo <profile>`
for built-in profiles.

## Inside Claude Code CLI

If you're already in a Claude Code session, run `/dex` to begin the ticket lifecycle interactively.

## Commands

Run `dx help` in the terminal for all available commands.

## Maintenance

| Setting | Value |
|---------|-------|
| enabled | true |
| branch_prefix | dex/maintain/ |
| label | dex-maintenance |
| default_mode | report |
| max_prs | 1 |
| low_risk_fix_categories | docs, rules, guards, memory, tests |
| copilot_review | true |

`fix-scoped` may only patch the low-risk categories listed above unless a repo
maintainer expands this table.
DEXMD
  dx_done "Created .dex/dex.md (minimal)"
else
  dx_ok ".dex/dex.md already exists"
fi

# AGENTS.md is the source of truth for generated Dex project context.
dex_agents_md="$repo_root/.dex/AGENTS.md"
if [[ -f "$dex_agents_md" ]] && grep -qF '@dex.md' "$dex_agents_md" 2>/dev/null; then
  dx_ok ".dex/AGENTS.md already imports dex.md"
elif [[ -f "$dex_agents_md" ]]; then
  # File exists but doesn't import dex.md — prepend the import.
  { printf '@dex.md\n\n'; cat "$dex_agents_md"; } > "${dex_agents_md}.tmp" && mv "${dex_agents_md}.tmp" "$dex_agents_md"
  dx_done "Added @import to existing .dex/AGENTS.md"
else
  printf '@dex.md\n' > "${dex_agents_md}.tmp" && mv "${dex_agents_md}.tmp" "$dex_agents_md"
  dx_done "Created .dex/AGENTS.md with @import"
fi

# CLAUDE.md remains as a compatibility pointer for Claude Code.
dex_claude_md="$repo_root/.dex/CLAUDE.md"
if [[ -f "$dex_claude_md" ]] && grep -qF '@AGENTS.md' "$dex_claude_md" 2>/dev/null; then
  dx_ok ".dex/CLAUDE.md already points to AGENTS.md"
elif [[ -f "$dex_claude_md" ]] && [[ "$(sed '/^[[:space:]]*$/d' "$dex_claude_md")" == "@dex.md" ]]; then
  printf '@AGENTS.md\n' > "${dex_claude_md}.tmp" && mv "${dex_claude_md}.tmp" "$dex_claude_md"
  dx_done "Updated .dex/CLAUDE.md to point to AGENTS.md"
elif [[ -f "$dex_claude_md" ]]; then
  # Preserve custom Claude instructions, but route generated context through AGENTS.md.
  { printf '@AGENTS.md\n\n'; cat "$dex_claude_md"; } > "${dex_claude_md}.tmp" && mv "${dex_claude_md}.tmp" "$dex_claude_md"
  dx_done "Added AGENTS.md pointer to existing .dex/CLAUDE.md"
else
  printf '@AGENTS.md\n' > "${dex_claude_md}.tmp" && mv "${dex_claude_md}.tmp" "$dex_claude_md"
  dx_done "Created .dex/CLAUDE.md pointing to AGENTS.md"
fi

# Memory index scaffold. Durable entries are added by codebase analysis or dx sync;
# raw observations live outside the repo.
memory_dir="$repo_root/.dex/memory"
mkdir -p "$memory_dir/domains"
memory_index="$memory_dir/index.md"
if [[ ! -f "$memory_index" ]]; then
  cat > "${memory_index}.tmp" << 'MEMORYINDEX'
# Dex Memory Index

No durable repo memory has been promoted yet.

Run `/dxsync` or `dx sync` after repeated review comments, CI failures,
maintenance runs, or durable workflow lessons create evidence worth preserving.

## Domains

| Domain | File | Loads For | Status |
|--------|------|-----------|--------|
MEMORYINDEX
  mv "${memory_index}.tmp" "$memory_index"
  dx_done "Created .dex/memory/index.md"
else
  dx_ok ".dex/memory/index.md already exists"
fi

echo ""
echo "Skeleton created."

# ── 2. Ensure global Dex tooling is available ─────────────────────

CODEX_SKILL_COUNT=0
TOOL_BOOTSTRAP_RAN=0
if [[ "${DEX_SKIP_TOOL_BOOTSTRAP:-0}" == "1" ]]; then
  dx_skip "Skipping Claude/Codex tooling bootstrap (already handled by caller)"
else
  TOOL_BOOTSTRAP_RAN=1
  if ! dx_bootstrap_agent_tooling "$repo_root" "install"; then
    dx_warn "Continuing init without complete Claude/Codex tooling bootstrap"
  fi
fi

if command -v codex &>/dev/null; then
  CODEX_SKILL_COUNT=$(dx_count_codex_dex_skills)
fi

# ── 3. Codebase analysis via Claude Code CLI ──────────────────────────

if [[ $SKIP_ANALYSIS -eq 1 ]]; then
  echo ""
  echo "Skipped codebase analysis (--skip-analysis)."
  echo "To generate project-specific config later, run:"
  echo "  dx init --skip-config"
elif ! command -v claude &>/dev/null; then
  echo ""
  echo "Claude Code CLI not found. Skipping codebase analysis."
  echo "Install Claude Code CLI, then run:"
  echo "  dx init --skip-config"
else
  echo ""
  echo "Analyzing codebase with the active Dex provider..."
  echo "This discovers your tech stack, quality gates, and conventions."
  echo ""
  printf '[....]  Starting analysis...'

  # -p runs a one-shot prompt; Claude writes files directly to .dex/
  # --verbose --output-format stream-json enables real-time progress.
  dx_provider_apply
  analysis_prompt=$(cat "$DEX_DIR/prompts/init-analysis.md")
  provider_prompt=$(dx_provider_prompt)
  INIT_PROVIDER_SESSION_ID="${INIT_RUN_SESSION_ID:-init-$(dx_unique_session_id)}"
  dx_provider_cleanup_session_state "$INIT_PROVIDER_SESSION_ID"
  set +o pipefail
  DEX_SESSION_ID="$INIT_PROVIDER_SESSION_ID" DEX_RUN_ID="${INIT_RUN_ID:-}" DX_RUN_ROOT="$DX_RUN_ROOT" dx_provider_claude -p "${analysis_prompt}${provider_prompt}" \
    --model "$DX_CLAUDE_MODEL" --effort "$DX_CLAUDE_EFFORT" \
    --dangerously-skip-permissions --permission-mode bypassPermissions \
    --verbose --output-format stream-json --include-partial-messages \
    | dx_progress_filter
  CLAUDE_EXIT=${PIPESTATUS[0]}
  set -o pipefail
  dx_provider_cleanup_session_state "$INIT_PROVIDER_SESSION_ID"
  INIT_PROVIDER_SESSION_ID=""
  if [[ $CLAUDE_EXIT -ne 0 ]]; then
    echo ""
    echo "WARNING: Codebase analysis exited with code $CLAUDE_EXIT."
    echo "The .dex/ skeleton was created but project-specific config may be incomplete."
    echo "You can re-run the analysis manually:"
    echo "  dx init --skip-config"
  fi
fi

# ── 4. Configure integrations ─────────────────────────────────────────

if [[ $SKIP_CONFIG -eq 0 ]]; then
  echo ""
  bash "$DEX_DIR/bin/config.sh"
else
  echo ""
  echo "Skipped integration config (--skip-config)."
  echo "To configure later, run: dx config"
fi

if [[ $INSTALL_MAINTENANCE_WORKFLOW -eq 1 ]]; then
  echo ""
  bash "$DEX_DIR/bin/maintain.sh" install-workflow
fi

echo ""
echo "Init complete for: $repo_name"
echo ""
echo "What happened:"
echo "  - .dex/ created (worktrees, config, gitignored artifacts)"
echo "  - .dex/AGENTS.md imports .dex/dex.md"
echo "  - .dex/CLAUDE.md points to .dex/AGENTS.md"
echo "  - .dex/memory/index.md is ready for durable repo memory"
if [[ "$CODEX_SKILL_COUNT" -gt 0 ]]; then
  echo "  - ${CODEX_SKILL_COUNT} Dex skill link(s) available in $(dx_codex_skills_dir) for Codex CLI"
fi
if [[ "$TOOL_BOOTSTRAP_RAN" -eq 1 ]]; then
  echo "  - Claude/Codex tooling installed with Dex links, official MCPs, and safe official plugins"
fi
if [[ $SKIP_ANALYSIS -eq 0 ]] && command -v claude &>/dev/null; then
  echo "  - Claude analyzed the codebase and generated project-specific config"
fi
if [[ $SKIP_CONFIG -eq 0 ]]; then
  echo "  - Integrations configured (ticket tracker, optional MCPs)"
fi
if [[ $INSTALL_MAINTENANCE_WORKFLOW -eq 1 ]]; then
  echo "  - DX maintain GitHub workflow installed"
fi
echo ""
echo "Next: run 'dx <ticket-number>' to start a worktree, or 'dx --no-worktree <task>' to branch in-place"
