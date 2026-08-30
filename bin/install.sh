#!/usr/bin/env bash
# shellcheck disable=SC2088,SC1091
# dex install — one-time global setup
# SC2088 suppressed: tilde in display strings is intentionally literal (e.g., "~/.claude/skills").
set -euo pipefail

if [[ -z "${DEX_DIR:-}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  DEX_DIR="$(dirname "$SCRIPT_DIR")"
  export DEX_DIR
fi
source "$DEX_DIR/lib/common.sh"
CLAUDE_DIR="$HOME/.claude"
ZSHRC="$HOME/.zshrc"
INSTALL_FAILED=0

usage() {
  cat <<'USAGE'
Usage: dx install

Install Dex skills, hooks, tools, and shell integration for the current user.

Options:
  -h, --help  Show this help
USAGE
}

show_help=0
for arg in "$@"; do
  case "$arg" in
    -h|--help) show_help=1 ;;
    *)
      dx_error "Unknown install option: $arg"
      usage >&2
      exit 1
      ;;
  esac
done
if [[ $show_help -eq 1 ]]; then
  usage
  exit 0
fi

echo "Dex — Global Install"
echo ""

# Everything Dex does at run time needs these three; finding out at first
# `dx` run is a worse experience than hearing it now.
for required_tool in git python3 zsh; do
  if ! command -v "$required_tool" >/dev/null 2>&1; then
    dx_error "Missing required tool: $required_tool. Install it and rerun 'dx install'."
    exit 1
  fi
done
if ! command -v gh >/dev/null 2>&1; then
  dx_warn "GitHub CLI (gh) not found. PR creation, reviewer routing, and CI watching need it."
fi

# Ensure ~/.claude directory exists (Claude Code normally creates it, but we
# need it before creating symlinks)
mkdir -p "$CLAUDE_DIR"

# 1. Symlink skills
if [[ -L "$CLAUDE_DIR/skills" ]]; then
  current=$(readlink "$CLAUDE_DIR/skills")
  if [[ "$current" == "$DEX_DIR/skills" ]]; then
    dx_ok "~/.claude/skills → $DEX_DIR/skills"
  else
    dx_error "~/.claude/skills points to $current; remove it or choose a clean install target"
    exit 1
  fi
elif [[ -d "$CLAUDE_DIR/skills" ]]; then
  if ! dx_install_claude_skill_links "$CLAUDE_DIR/skills"; then
    dx_warn "Continuing install after incomplete Claude skill link setup"
    INSTALL_FAILED=1
  fi
else
  if ln -s "$DEX_DIR/skills" "$CLAUDE_DIR/skills"; then
    dx_done "Symlinked ~/.claude/skills → $DEX_DIR/skills"
  else
    dx_error "Failed to symlink ~/.claude/skills"
    INSTALL_FAILED=1
  fi
fi

# 2. Install conservative Claude/Codex tooling.
if ! dx_bootstrap_agent_tooling "" "install"; then
  dx_warn "Continuing install without complete Claude/Codex tooling bootstrap"
  INSTALL_FAILED=1
fi

# 3. Source dx.sh in ~/.zshrc
if grep -qE "$DX_ZSHRC_SOURCE_ACTIVE_PATTERN" "$ZSHRC" 2>/dev/null; then
  dx_ok "dx.sh already sourced in ~/.zshrc"
else
  {
    echo ""
    echo "# Dex"
    echo "export DEX_DIR=\"$DEX_DIR\""
    echo "source \"\$DEX_DIR/dx.sh\""
  } >> "$ZSHRC"
  dx_done "Added DEX_DIR export and source to ~/.zshrc"
fi

# Warn users whose login shell is not zsh; dx.sh requires zsh to function.
if [[ "${SHELL:-}" != */zsh ]]; then
  dx_warn "Your current shell is '${SHELL:-unknown}'. Dex requires zsh — dx.sh uses zsh-only syntax."
  dx_warn "Switch to zsh (chsh -s \$(which zsh)) or source ~/.zshrc from a zsh session to use Dex."
fi

# 4. Make scripts executable. The .py files stay as Git shipped them: every
# caller runs them through python3, and re-flipping shell_parse.py's mode
# would dirty the checkout.
if chmod +x "$DEX_DIR/hooks/"*.sh "$DEX_DIR/bin/"*.sh 2>/dev/null; then
  dx_done "Made scripts executable"
else
  dx_error "Failed to make Dex scripts executable"
  INSTALL_FAILED=1
fi

if [[ $INSTALL_FAILED -ne 0 ]]; then
  echo ""
  dx_error "Install incomplete. Fix the warnings above, then run 'dx install' again."
  exit 1
fi

echo ""
echo "Install complete. Run: source ~/.zshrc"
echo ""
echo "Next: cd to a repo and run 'dx init' to bootstrap it."
