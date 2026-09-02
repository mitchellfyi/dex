#!/usr/bin/env bash
# shellcheck disable=SC1091
# dex status — show installation status
set -euo pipefail

source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"
CLAUDE_DIR="$HOME/.claude"

usage() {
  cat <<'USAGE'
Usage: dx status

Show the global Dex installation and current repository status.

Options:
  -h, --help  Show this help
USAGE
}

show_help=0
for arg in "$@"; do
  case "$arg" in
    -h|--help) show_help=1 ;;
    *)
      dx_error "Unknown status option: $arg"
      usage >&2
      exit 1
      ;;
  esac
done
if [[ $show_help -eq 1 ]]; then
  usage
  exit 0
fi

echo "Dex — Status"
echo ""

# Global installation
echo "Global:"
if [[ -L "$CLAUDE_DIR/skills" ]]; then
  target=$(readlink "$CLAUDE_DIR/skills")
  if [[ "$target" == "$DEX_DIR/skills" ]]; then
    # Count only directories (each skill is a dir containing SKILL.md), not .DS_Store etc.
    count=$(find "$target" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    echo "  Skills:     $count skills symlinked"
  else
    echo "  Skills:     WRONG TARGET ($target)"
  fi
elif [[ -d "$CLAUDE_DIR/skills" ]]; then
  skill_count=$(dx_count_claude_dex_skill_links "$CLAUDE_DIR/skills")
  skill_expected=$(dx_count_dex_skills)
  if [[ "$skill_count" -eq "$skill_expected" && "$skill_expected" -gt 0 ]]; then
    echo "  Skills:     $skill_count/$skill_expected Dex skill link(s)"
  elif [[ "$skill_count" -gt 0 ]]; then
    echo "  Skills:     PARTIAL ($skill_count/$skill_expected Dex skill link(s))"
  else
    echo "  Skills:     NOT INSTALLED"
  fi
else
  echo "  Skills:     NOT INSTALLED"
fi

if dx_claude_settings_complete; then
  echo "  Hooks:      installed in ~/.claude/settings.json"
elif [[ -f "$CLAUDE_DIR/settings.json" ]]; then
  echo "  Hooks:      INCOMPLETE — run 'dx tools bootstrap'"
else
  echo "  Hooks:      NOT INSTALLED"
fi

if command -v codex &>/dev/null; then
  codex_skill_count=$(dx_count_codex_dex_skills)
  codex_skill_expected=$(dx_count_dex_skills)
  if dx_codex_dex_skills_complete; then
    echo "  Codex:      $codex_skill_count/$codex_skill_expected Dex skill link(s)"
  elif [[ "$codex_skill_count" -gt 0 ]]; then
    echo "  Codex:      PARTIAL ($codex_skill_count/$codex_skill_expected Dex skill link(s))"
  else
    echo "  Codex:      skills NOT INSTALLED"
  fi
else
  echo "  Codex:      CLI not found"
fi

if dx_ui_capture_tooling_ready; then
  echo "  UI Tools:   browser, media, and local narration ready ($(dx_ui_capture_tools_dir))"
elif dx_ui_capture_playwright_ready && dx_ui_capture_media_ready; then
  echo "  UI Tools:   browser + media ready; local narration unavailable (captions still work)"
else
  echo "  UI Tools:   incomplete — run 'dx ui-capture install'"
fi

if ! dx_rtk_enabled; then
  echo "  RTK:        disabled (DX_RTK_ENABLED=0)"
elif rtk_binary=$(dx_rtk_resolved_binary 2>/dev/null); then
  echo "  RTK:        installed ($rtk_binary)"
else
  echo "  RTK:        not installed or wrong binary — run 'dx install'"
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
    echo "  Codex MCP:  Playwright + Chrome DevTools configured"
  else
    echo "  Codex MCP:  browser servers incomplete — run 'dx install'"
  fi
fi

if grep -qE "$DX_ZSHRC_SOURCE_ACTIVE_PATTERN" "$HOME/.zshrc" 2>/dev/null; then
  echo "  Shell:      sourced in ~/.zshrc"
else
  echo "  Shell:      NOT INSTALLED"
fi

# The rest of the toolchain Dex reaches for, so "is this set up right?" has
# one answer instead of a first failed run per missing tool.
missing_tools=""
for base_tool in git python3 zsh; do
  command -v "$base_tool" >/dev/null 2>&1 || missing_tools="$missing_tools $base_tool"
done
if [[ -n "$missing_tools" ]]; then
  echo "  Tools:      MISSING —${missing_tools}"
else
  echo "  Tools:      git, python3, zsh present"
fi
if command -v gh &>/dev/null; then
  echo "  GitHub CLI: $(gh --version 2>/dev/null | head -1 || echo present)"
  if dx_github_pr_attachments_supported; then
    echo "  PR Media:   automatic attachments ready"
  else
    echo "  PR Media:   unavailable — upgrade GitHub CLI for --attach"
  fi
else
  echo "  GitHub CLI: not found — PR creation, reviewers, and CI watching need it"
  echo "  PR Media:   unavailable — GitHub CLI is not installed"
fi
if ! command -v jq &>/dev/null; then
  echo "  jq:         not found (optional — 'dx config' skips MCP merges without it)"
fi

# Current project
echo ""
echo "Project:"
repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [[ -z "$repo_root" ]]; then
  echo "  Not in a git repository"
else
  repo_name=$(basename "$repo_root")
  echo "  Repo:       $repo_name ($repo_root)"

  if [[ -f "$repo_root/.dex/dex.md" ]]; then
    echo "  Init:       yes (.dex/dex.md exists)"
  else
    echo "  Init:       no — run 'dx init'"
  fi

  worktrees_dir="$repo_root/.dex/worktrees"
  if [[ -d "$worktrees_dir" ]]; then
    count=$(find "$worktrees_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    echo "  Worktrees:  $count active"
  else
    echo "  Worktrees:  none"
  fi

  current_session=$(dx_session_id)
  current_ui_proof=$(dx_ui_capture_status "$current_session")
  echo "  UI Proof:   $current_ui_proof"
  if [[ "$current_ui_proof" != "MISSING" ]]; then
    echo "  UI Details: $(dx_ui_capture_evidence_file "$current_session")"
  fi
fi

# Changes available immediately?
echo ""
echo "Live updates:"
echo "  Skills, hooks, rules, prompts → changes take effect immediately"
echo "  Shell functions and hooks     → run 'dx reload' to apply"
