#!/usr/bin/env bash
# shellcheck disable=SC2088,SC1091
# doyaken install — one-time global setup
# SC2088 suppressed: tilde in display strings is intentionally literal (e.g., "~/.claude/skills").
set -euo pipefail

if [[ -z "${DOYAKEN_DIR:-}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  DOYAKEN_DIR="$(dirname "$SCRIPT_DIR")"
  export DOYAKEN_DIR
fi
source "$DOYAKEN_DIR/lib/common.sh"
CLAUDE_DIR="$HOME/.claude"
ZSHRC="$HOME/.zshrc"

echo "Doyaken — Global Install"
echo ""

# Ensure ~/.claude directory exists (Claude Code normally creates it, but we
# need it before creating symlinks in steps 1-2)
mkdir -p "$CLAUDE_DIR"

# 1. Symlink skills
if [[ -L "$CLAUDE_DIR/skills" ]]; then
  current=$(readlink "$CLAUDE_DIR/skills")
	  if [[ "$current" == "$DOYAKEN_DIR/skills" ]]; then
	    dk_ok "~/.claude/skills → $DOYAKEN_DIR/skills"
	  else
	    rm "$CLAUDE_DIR/skills"
	    if ln -s "$DOYAKEN_DIR/skills" "$CLAUDE_DIR/skills"; then
	      dk_done "Updated ~/.claude/skills → $DOYAKEN_DIR/skills (was: $current)"
	    else
	      dk_error "Failed to symlink ~/.claude/skills"
	    fi
	  fi
elif [[ -d "$CLAUDE_DIR/skills" ]]; then
  dk_warn "~/.claude/skills exists as a directory — back up and re-run:"
  echo "       mv ~/.claude/skills ~/.claude/skills.bak && dk install"
else
  if ln -s "$DOYAKEN_DIR/skills" "$CLAUDE_DIR/skills"; then
    dk_done "Symlinked ~/.claude/skills → $DOYAKEN_DIR/skills"
  else
    dk_error "Failed to symlink ~/.claude/skills"
  fi
fi

# 2. Symlink agents
if [[ -L "$CLAUDE_DIR/agents" ]]; then
  current=$(readlink "$CLAUDE_DIR/agents")
	  if [[ "$current" == "$DOYAKEN_DIR/agents" ]]; then
	    dk_ok "~/.claude/agents → $DOYAKEN_DIR/agents"
	  else
	    rm "$CLAUDE_DIR/agents"
	    if ln -s "$DOYAKEN_DIR/agents" "$CLAUDE_DIR/agents"; then
	      dk_done "Updated ~/.claude/agents → $DOYAKEN_DIR/agents (was: $current)"
	    else
	      dk_error "Failed to symlink ~/.claude/agents"
	    fi
	  fi
elif [[ -d "$CLAUDE_DIR/agents" ]]; then
  dk_warn "~/.claude/agents exists as a directory — back up and re-run:"
  echo "       mv ~/.claude/agents ~/.claude/agents.bak && dk install"
else
  if ln -s "$DOYAKEN_DIR/agents" "$CLAUDE_DIR/agents"; then
    dk_done "Symlinked ~/.claude/agents → $DOYAKEN_DIR/agents"
  else
    dk_error "Failed to symlink ~/.claude/agents"
  fi
fi

# 3. Install or repair conservative Claude/Codex tooling.
if ! dk_bootstrap_agent_tooling "" "repair"; then
  dk_warn "Continuing install without complete Claude/Codex tooling bootstrap"
fi

# 4. Source dk.sh in ~/.zshrc
if grep -qE 'doyaken/dk\.sh|DOYAKEN_DIR.*/dk\.sh' "$ZSHRC" 2>/dev/null; then
  # Ensure DOYAKEN_DIR export exists (upgrade path: older installs lack it)
  if ! grep -qE '^export DOYAKEN_DIR=' "$ZSHRC" 2>/dev/null; then
    # Insert the export line before the existing source line.
    # Uses awk instead of sed -i to avoid BSD/GNU sed portability issues.
    _DKDIR="$DOYAKEN_DIR" awk '
      /doyaken\/dk\.sh|DOYAKEN_DIR.*\/dk\.sh/ && !inserted { print "export DOYAKEN_DIR=\"" ENVIRON["_DKDIR"] "\""; inserted=1 }
      { print }
    ' "$ZSHRC" > "${ZSHRC}.tmp" && mv "${ZSHRC}.tmp" "$ZSHRC"
    dk_done "Added DOYAKEN_DIR export to ~/.zshrc (upgrade)"
  else
    dk_ok "dk.sh already sourced in ~/.zshrc"
  fi
else
  # Check for old Doyaken source lines (different path)
  if grep -qE 'doyaken.*dk\.sh|DOYAKEN_DIR.*/dk\.sh' "$ZSHRC" 2>/dev/null; then
    dk_info "Found old Doyaken dk.sh source line — replacing..."
    # grep -v exits 1 when no lines survive filtering, which is valid when
    # .zshrc only contained old Doyaken lines.
    grep -vE 'doyaken.*dk\.sh|DOYAKEN_DIR.*/dk\.sh|export DOYAKEN_DIR=' "$ZSHRC" > "${ZSHRC}.tmp" || true
    mv "${ZSHRC}.tmp" "$ZSHRC"
  fi
  {
    echo ""
    echo "# Doyaken"
    echo "export DOYAKEN_DIR=\"$DOYAKEN_DIR\""
    echo "source \"\$DOYAKEN_DIR/dk.sh\""
  } >> "$ZSHRC"
  dk_done "Added DOYAKEN_DIR export and source to ~/.zshrc"
fi

# 5. Make scripts executable
chmod +x "$DOYAKEN_DIR/hooks/"*.sh "$DOYAKEN_DIR/hooks/"*.py "$DOYAKEN_DIR/bin/"*.sh 2>/dev/null
dk_done "Made scripts executable"

echo ""
echo "Install complete. Run: source ~/.zshrc"
echo ""
echo "Next: cd to a repo and run 'dk init' to bootstrap it."
