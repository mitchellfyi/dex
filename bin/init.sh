#!/usr/bin/env bash
# doyaken init — bootstrap current repo for Doyaken
# Creates .doyaken/ skeleton, then uses Claude Code CLI to analyze
# the codebase and generate project-specific configuration.
set -euo pipefail

source "${DOYAKEN_DIR:-$HOME/work/doyaken}/lib/common.sh"

INIT_PROVIDER_SESSION_ID=""
__dk_init_cleanup() {
  if [[ -n "${INIT_PROVIDER_SESSION_ID:-}" ]]; then
    dk_provider_cleanup_session_state "$INIT_PROVIDER_SESSION_ID" 2>/dev/null || true
  fi
}
trap __dk_init_cleanup EXIT
trap 'printf "\nInterrupted.\n"; exit 130' INT

# Parse all flags upfront so they work independently of each other.
# (Previously --skip-config was unreachable when --skip-analysis was set
# because the analysis section exited early before config flag was parsed.)
SKIP_ANALYSIS=0
SKIP_CONFIG=0
for arg in "$@"; do
  case "$arg" in
    --skip-analysis) SKIP_ANALYSIS=1 ;;
    --skip-config)   SKIP_CONFIG=1 ;;
  esac
done

# Must be in a git repo
repo_root=$(git rev-parse --show-toplevel 2>/dev/null)
if [[ -z "$repo_root" ]]; then
  echo "ERROR: Not in a git repository."
  exit 1
fi

repo_name=$(basename "$repo_root")
echo "Doyaken — Init: $repo_name"
echo ""

# ── 1. Create .doyaken/ skeleton ──────────────────────────────────────

mkdir -p "$repo_root/.doyaken"

# .gitignore for worktree artifacts (don't overwrite — user may have added custom entries)
doyaken_gitignore="$repo_root/.doyaken/.gitignore"
if [[ ! -f "$doyaken_gitignore" ]]; then
  cat > "$doyaken_gitignore" << 'GITIGNORE'
worktrees/
GITIGNORE
  dk_done "Created .doyaken/.gitignore"
else
  dk_ok ".doyaken/.gitignore already exists"
fi

# Minimal doyaken.md (will be overwritten by codebase analysis if run)
doyaken_md="$repo_root/.doyaken/doyaken.md"
if [[ ! -f "$doyaken_md" ]]; then
  cat > "$doyaken_md" << 'DOYAKENMD'
# Doyaken

This project uses Doyaken for workflow automation.

## Autonomous workflow

From the terminal, run `dk <ticket-number>` to start the full autonomous lifecycle (Plan → Implement → Verify → PR → Complete) in an isolated worktree. You can also run `dk "description"` for freeform tasks, or `dk --no-worktree <ticket-or-description>` to set up the normal lifecycle branch in the current checkout without creating a worktree.

## One-off prompt (no ticket)

Run `dkloop <prompt>` to execute a prompt in a loop until Claude confirms it's fully implemented. Works in the current directory — no worktree or ticket needed.

## Inside Claude Code CLI

If you're already in a Claude Code session, run `/doyaken` to begin the ticket lifecycle interactively.

## Commands

Run `dk help` in the terminal for all available commands.
DOYAKENMD
  dk_done "Created .doyaken/doyaken.md (minimal)"
else
  dk_ok ".doyaken/doyaken.md already exists"
fi

# AGENTS.md is the source of truth for generated Doyaken project context.
doyaken_agents_md="$repo_root/.doyaken/AGENTS.md"
if [[ -f "$doyaken_agents_md" ]] && grep -qF '@doyaken.md' "$doyaken_agents_md" 2>/dev/null; then
  dk_ok ".doyaken/AGENTS.md already imports doyaken.md"
elif [[ -f "$doyaken_agents_md" ]]; then
  # File exists but doesn't import doyaken.md — prepend the import.
  { printf '@doyaken.md\n\n'; cat "$doyaken_agents_md"; } > "${doyaken_agents_md}.tmp" && mv "${doyaken_agents_md}.tmp" "$doyaken_agents_md"
  dk_done "Added @import to existing .doyaken/AGENTS.md"
else
  printf '@doyaken.md\n' > "${doyaken_agents_md}.tmp" && mv "${doyaken_agents_md}.tmp" "$doyaken_agents_md"
  dk_done "Created .doyaken/AGENTS.md with @import"
fi

# CLAUDE.md remains as a compatibility pointer for Claude Code.
doyaken_claude_md="$repo_root/.doyaken/CLAUDE.md"
if [[ -f "$doyaken_claude_md" ]] && grep -qF '@AGENTS.md' "$doyaken_claude_md" 2>/dev/null; then
  dk_ok ".doyaken/CLAUDE.md already points to AGENTS.md"
elif [[ -f "$doyaken_claude_md" ]] && [[ "$(sed '/^[[:space:]]*$/d' "$doyaken_claude_md")" == "@doyaken.md" ]]; then
  printf '@AGENTS.md\n' > "${doyaken_claude_md}.tmp" && mv "${doyaken_claude_md}.tmp" "$doyaken_claude_md"
  dk_done "Updated .doyaken/CLAUDE.md to point to AGENTS.md"
elif [[ -f "$doyaken_claude_md" ]]; then
  # Preserve custom Claude instructions, but route generated context through AGENTS.md.
  { printf '@AGENTS.md\n\n'; cat "$doyaken_claude_md"; } > "${doyaken_claude_md}.tmp" && mv "${doyaken_claude_md}.tmp" "$doyaken_claude_md"
  dk_done "Added AGENTS.md pointer to existing .doyaken/CLAUDE.md"
else
  printf '@AGENTS.md\n' > "${doyaken_claude_md}.tmp" && mv "${doyaken_claude_md}.tmp" "$doyaken_claude_md"
  dk_done "Created .doyaken/CLAUDE.md pointing to AGENTS.md"
fi

echo ""
echo "Skeleton created."

# ── 2. Ensure global Doyaken tooling is available ─────────────────────

CODEX_SKILL_COUNT=0
if command -v codex &>/dev/null; then
  if ! dk_install_codex_skills; then
    dk_warn "Continuing init without complete Codex skill links"
  fi
  CODEX_SKILL_COUNT=$(dk_count_codex_doyaken_skills)
else
  dk_skip "Codex CLI not found; skipping Codex skills"
fi

if ! dk_install_ui_capture_tooling; then
  dk_warn "Continuing init without complete UI capture tooling"
fi

# ── 3. Codebase analysis via Claude Code CLI ──────────────────────────

if [[ $SKIP_ANALYSIS -eq 1 ]]; then
  echo ""
  echo "Skipped codebase analysis (--skip-analysis)."
  echo "To generate project-specific config later, run:"
  echo "  dk init --skip-config"
elif ! command -v claude &>/dev/null; then
  echo ""
  echo "Claude Code CLI not found. Skipping codebase analysis."
  echo "Install Claude Code CLI, then run:"
  echo "  dk init --skip-config"
else
  echo ""
  echo "Analyzing codebase with Claude Code CLI..."
  echo "This discovers your tech stack, quality gates, and conventions."
  echo ""
  printf '[....]  Starting analysis...'

  # -p runs a one-shot prompt; Claude writes files directly to .doyaken/
  # --verbose --output-format stream-json enables real-time progress.
  dk_provider_apply
  analysis_prompt=$(cat "$DOYAKEN_DIR/prompts/init-analysis.md")
  provider_prompt=$(dk_provider_prompt)
  INIT_PROVIDER_SESSION_ID="init-$(dk_unique_session_id)"
  dk_provider_cleanup_session_state "$INIT_PROVIDER_SESSION_ID"
  set +o pipefail
  DOYAKEN_SESSION_ID="$INIT_PROVIDER_SESSION_ID" dk_provider_claude -p "${analysis_prompt}${provider_prompt}" \
    --model "$DK_CLAUDE_MODEL" --effort "$DK_CLAUDE_EFFORT" \
    --dangerously-skip-permissions --permission-mode bypassPermissions \
    --verbose --output-format stream-json --include-partial-messages \
    | dk_progress_filter
  CLAUDE_EXIT=${PIPESTATUS[0]}
  set -o pipefail
  dk_provider_cleanup_session_state "$INIT_PROVIDER_SESSION_ID"
  INIT_PROVIDER_SESSION_ID=""
  if [[ $CLAUDE_EXIT -ne 0 ]]; then
    echo ""
    echo "WARNING: Codebase analysis exited with code $CLAUDE_EXIT."
    echo "The .doyaken/ skeleton was created but project-specific config may be incomplete."
    echo "You can re-run the analysis manually:"
    echo "  dk init --skip-config"
  fi
fi

# ── 4. Configure integrations ─────────────────────────────────────────

if [[ $SKIP_CONFIG -eq 0 ]]; then
  echo ""
  bash "$DOYAKEN_DIR/bin/config.sh"
else
  echo ""
  echo "Skipped integration config (--skip-config)."
  echo "To configure later, run: dk config"
fi

echo ""
echo "Init complete for: $repo_name"
echo ""
echo "What happened:"
echo "  - .doyaken/ created (worktrees, config, gitignored artifacts)"
echo "  - .doyaken/AGENTS.md imports .doyaken/doyaken.md"
echo "  - .doyaken/CLAUDE.md points to .doyaken/AGENTS.md"
if [[ "$CODEX_SKILL_COUNT" -gt 0 ]]; then
  echo "  - ${CODEX_SKILL_COUNT} Doyaken skill link(s) available in $(dk_codex_skills_dir) for Codex CLI"
fi
if [[ $SKIP_ANALYSIS -eq 0 ]] && command -v claude &>/dev/null; then
  echo "  - Claude analyzed the codebase and generated project-specific config"
fi
if [[ $SKIP_CONFIG -eq 0 ]]; then
  echo "  - Integrations configured (ticket tracker, optional MCPs)"
fi
echo ""
echo "Next: run 'dk <ticket-number>' to start a worktree, or 'dk --no-worktree <task>' to branch in-place"
