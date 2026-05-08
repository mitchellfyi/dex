#!/usr/bin/env bash
# shellcheck disable=SC1091
# doyaken status — show installation status
set -euo pipefail

source "${DOYAKEN_DIR:-$HOME/work/doyaken}/lib/common.sh"
CLAUDE_DIR="$HOME/.claude"

__dk_status_has_doyaken_hooks() {
  local settings_file="$CLAUDE_DIR/settings.json"
  [[ -f "$settings_file" ]] || return 1
  grep -Fq "$DOYAKEN_DIR/hooks/" "$settings_file" 2>/dev/null && return 0
  grep -Fq "$HOME/work/doyaken/hooks/" "$settings_file" 2>/dev/null && return 0
  grep -Fq "\$HOME/work/doyaken/hooks/" "$settings_file" 2>/dev/null && return 0
  grep -Fq "\$DOYAKEN_DIR/hooks/" "$settings_file" 2>/dev/null && return 0
  grep -Eq 'export DOYAKEN_DIR=.*hooks/|/doyaken(-cli)?/hooks/(load-ticket-context\.sh|user-prompt-submit\.sh|guard-handler\.py|post-commit-guard\.sh|phase-loop\.sh|pre-compact\.sh|session-end\.sh)' "$settings_file" 2>/dev/null
}

echo "Doyaken — Status"
echo ""

# Global installation
echo "Global:"
if [[ -L "$CLAUDE_DIR/skills" ]]; then
  target=$(readlink "$CLAUDE_DIR/skills")
  if [[ "$target" == "$DOYAKEN_DIR/skills" ]]; then
    # Count only directories (each skill is a dir containing SKILL.md), not .DS_Store etc.
    count=$(find "$target" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    echo "  Skills:    $count skills symlinked"
  else
    echo "  Skills:    WRONG TARGET ($target)"
  fi
else
  echo "  Skills:    NOT INSTALLED"
fi

if [[ -L "$CLAUDE_DIR/agents" ]]; then
  target=$(readlink "$CLAUDE_DIR/agents")
  if [[ "$target" == "$DOYAKEN_DIR/agents" ]]; then
    # Count only .md files (agent definitions), not .DS_Store or other artifacts
    count=$(find "$target" -mindepth 1 -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
    echo "  Agents:    $count agent(s) symlinked"
  else
    echo "  Agents:    WRONG TARGET ($target)"
  fi
else
  echo "  Agents:    NOT INSTALLED"
fi

if __dk_status_has_doyaken_hooks; then
  echo "  Hooks:     installed in ~/.claude/settings.json"
else
  echo "  Hooks:     NOT INSTALLED"
fi

if command -v codex &>/dev/null; then
  codex_skill_count=$(dk_count_codex_doyaken_skills)
  codex_skill_expected=$(dk_count_doyaken_skills)
  if dk_codex_doyaken_skills_complete; then
    echo "  Codex:     $codex_skill_count/$codex_skill_expected Doyaken skill link(s)"
  elif [[ "$codex_skill_count" -gt 0 ]]; then
    echo "  Codex:     PARTIAL ($codex_skill_count/$codex_skill_expected Doyaken skill link(s))"
  else
    echo "  Codex:     skills NOT INSTALLED"
  fi
else
  echo "  Codex:     CLI not found"
fi

if dk_ui_capture_playwright_ready; then
  echo "  UI Tools:  Playwright installed ($(dk_ui_capture_tools_dir))"
else
  echo "  UI Tools:  Playwright not installed — run 'dk install'"
fi

if command -v claude &>/dev/null; then
  if dk_claude_mcp_server_exists "playwright" && dk_claude_mcp_server_exists "chrome-devtools"; then
    echo "  Claude MCP: Playwright + Chrome DevTools configured"
  else
    echo "  Claude MCP: browser servers incomplete — run 'dk install'"
  fi
else
  echo "  Claude MCP: Claude Code CLI not found"
fi

if command -v codex &>/dev/null; then
  if dk_codex_mcp_server_exists "playwright" && dk_codex_mcp_server_exists "chrome-devtools"; then
    echo "  Codex MCP: Playwright + Chrome DevTools configured"
  else
    echo "  Codex MCP: browser servers incomplete — run 'dk install'"
  fi
fi

if grep -qE 'doyaken/dk\.sh|DOYAKEN_DIR.*/dk\.sh' "$HOME/.zshrc" 2>/dev/null; then
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

  if [[ -f "$repo_root/.doyaken/doyaken.md" ]]; then
    echo "  Init:      yes (.doyaken/doyaken.md exists)"
  else
    echo "  Init:      no — run 'dk init'"
  fi

  worktrees_dir="$repo_root/.doyaken/worktrees"
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
echo "  Shell functions (dk.sh)       → run 'dk reload' to apply"
