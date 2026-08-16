#!/usr/bin/env bash
# Research harness — workspace management
# Creates and resets isolated workspace directories for each scenario.

# shellcheck source=research/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# workspace_create <scenario_name>
# Create a fresh workspace directory with git init.
# Removes any existing workspace for this scenario first.
workspace_create() {
  local name="$1"
  local ws
  scenario_name_require_valid "$name" || return 1
  ws=$(workspace_dir "$name")

  if [[ -d "$ws" ]]; then
    log_info "Resetting workspace: $name"
    rm -rf "$ws"
  fi

  mkdir -p "$ws"
  git -C "$ws" init --quiet
  git -C "$ws" config user.name "Dex Research"
  git -C "$ws" config user.email "research@dex.local"

  # Minimal gitignore so DX's output is clean
  cat > "$ws/.gitignore" <<'GITIGNORE'
node_modules/
__pycache__/
.venv/
dist/
build/
*.pyc
.DS_Store
GITIGNORE

  git -C "$ws" add .gitignore
  git -C "$ws" commit --quiet -m "init: empty workspace"

  # Optional: copy the scenario's seed/ directory into the workspace so
  # scenarios can start with pre-existing code. Seed files are folded into the
  # baseline commit so workspace_diff / workspace_files_changed only report
  # what DX actually changed.
  local seed_dir
  seed_dir="$(scenario_dir "$name")/seed"
  if [[ -d "$seed_dir" ]]; then
    (cd "$seed_dir" && cp -R . "$ws/")
    if [[ -n "$(git -C "$ws" status --porcelain)" ]]; then
      git -C "$ws" add -A
      git -C "$ws" commit --quiet --amend --no-edit
      log_info "Seeded workspace from $seed_dir"
    fi
  fi

  log_info "Created workspace: $ws"
  echo "$ws"
}

# workspace_files_changed <scenario_name>
# List all files created or modified by DX.
workspace_files_changed() {
  local ws
  ws=$(workspace_dir "$1")
  {
    git -C "$ws" diff --name-only HEAD 2>/dev/null
    git -C "$ws" diff --cached --name-only HEAD 2>/dev/null
    git -C "$ws" ls-files --others --exclude-standard 2>/dev/null
  } | sort -u
}
