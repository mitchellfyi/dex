#!/usr/bin/env bash
# shellcheck disable=SC1091
# dex status — show installation status
set -euo pipefail

source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"
CLAUDE_DIR="$HOME/.claude"

__dx_status_has_dex_hooks() {
  local settings_file="$CLAUDE_DIR/settings.json"
  [[ -f "$settings_file" ]] || return 1
  grep -Fq "$DEX_DIR/hooks/" "$settings_file" 2>/dev/null && return 0
  grep -Fq "$HOME/work/dex/hooks/" "$settings_file" 2>/dev/null && return 0
  grep -Fq "\$HOME/work/dex/hooks/" "$settings_file" 2>/dev/null && return 0
  grep -Fq "\$DEX_DIR/hooks/" "$settings_file" 2>/dev/null && return 0
  grep -Eq 'export DEX_DIR=.*hooks/|/dex(-cli)?/hooks/(load-ticket-context\.sh|user-prompt-submit\.sh|guard-handler\.py|rtk-claude-hook\.sh|post-commit-guard\.sh|phase-loop\.sh|stop-sound\.sh|pre-compact\.sh|session-end\.sh)' "$settings_file" 2>/dev/null
}

echo "Dex — Status"
echo ""

# Global installation
echo "Global:"
if [[ -L "$CLAUDE_DIR/skills" ]]; then
  target=$(readlink "$CLAUDE_DIR/skills")
  if [[ "$target" == "$DEX_DIR/skills" ]]; then
    # Count only directories (each skill is a dir containing SKILL.md), not .DS_Store etc.
    count=$(find "$target" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    echo "  Skills:    $count skills symlinked"
  else
    echo "  Skills:    WRONG TARGET ($target)"
  fi
elif [[ -d "$CLAUDE_DIR/skills" ]]; then
  skill_count=$(dx_count_claude_dex_skill_links "$CLAUDE_DIR/skills")
  skill_expected=$(dx_count_dex_skills)
  if [[ "$skill_count" -eq "$skill_expected" && "$skill_expected" -gt 0 ]]; then
    echo "  Skills:    $skill_count/$skill_expected Dex skill link(s)"
  elif [[ "$skill_count" -gt 0 ]]; then
    echo "  Skills:    PARTIAL ($skill_count/$skill_expected Dex skill link(s))"
  else
    echo "  Skills:    NOT INSTALLED"
  fi
else
  echo "  Skills:    NOT INSTALLED"
fi

if __dx_status_has_dex_hooks; then
  echo "  Hooks:     installed in ~/.claude/settings.json"
else
  echo "  Hooks:     NOT INSTALLED"
fi

if command -v codex &>/dev/null; then
  codex_skill_count=$(dx_count_codex_dex_skills)
  codex_skill_expected=$(dx_count_dex_skills)
  if dx_codex_dex_skills_complete; then
    echo "  Codex:     $codex_skill_count/$codex_skill_expected Dex skill link(s)"
  elif [[ "$codex_skill_count" -gt 0 ]]; then
    echo "  Codex:     PARTIAL ($codex_skill_count/$codex_skill_expected Dex skill link(s))"
  else
    echo "  Codex:     skills NOT INSTALLED"
  fi
else
  echo "  Codex:     CLI not found"
fi

if dx_ui_capture_playwright_ready; then
  echo "  UI Tools:  Playwright installed ($(dx_ui_capture_tools_dir))"
else
  echo "  UI Tools:  Playwright not installed — run 'dx install'"
fi

if rtk_binary=$(dx_rtk_resolved_binary 2>/dev/null); then
  echo "  RTK:       installed ($rtk_binary)"
else
  echo "  RTK:       not installed or wrong binary — run 'dx install'"
fi

if command -v claude &>/dev/null; then
  if dx_claude_mcp_server_exists "playwright" && dx_claude_mcp_server_exists "chrome-devtools"; then
    echo "  Claude MCP: Playwright + Chrome DevTools configured"
  else
    echo "  Claude MCP: browser servers incomplete — run 'dx install'"
  fi
else
  echo "  Claude MCP: Claude Code CLI not found"
fi

if command -v codex &>/dev/null; then
  if dx_codex_mcp_server_exists "playwright" && dx_codex_mcp_server_exists "chrome-devtools"; then
    echo "  Codex MCP: Playwright + Chrome DevTools configured"
  else
    echo "  Codex MCP: browser servers incomplete — run 'dx install'"
  fi
fi

if grep -qE 'dex/dx\.sh|DEX_DIR.*/dx\.sh' "$HOME/.zshrc" 2>/dev/null; then
  echo "  Shell:     sourced in ~/.zshrc"
else
  echo "  Shell:     NOT INSTALLED"
fi

# Current project
echo ""
echo "Project:"
repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [[ -z "$repo_root" ]]; then
  echo "  Not in a git repository"
else
  repo_name=$(basename "$repo_root")
  echo "  Repo:      $repo_name ($repo_root)"

  if [[ -f "$repo_root/.dex/dex.md" ]]; then
    echo "  Init:      yes (.dex/dex.md exists)"
  else
    echo "  Init:      no — run 'dx init'"
  fi

  worktrees_dir="$repo_root/.dex/worktrees"
  if [[ -d "$worktrees_dir" ]]; then
    count=$(find "$worktrees_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    echo "  Worktrees: $count active"
  else
    echo "  Worktrees: none"
  fi
fi

# Changes available immediately?
echo ""
echo "Live updates:"
echo "  Skills, hooks, rules, prompts → changes take effect immediately"
echo "  Shell functions (dx.sh)       → run 'dx reload' to apply"
