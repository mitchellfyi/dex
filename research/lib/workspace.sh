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
  git -C "$ws" config user.name "Doyaken Research"
  git -C "$ws" config user.email "research@doyaken.local"

  # Minimal gitignore so DK's output is clean
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

  log_info "Created workspace: $ws"
  echo "$ws"
}

# workspace_reset <scenario_name>
# Destroy and recreate the workspace.
workspace_reset() {
  workspace_create "$1"
}

# workspace_exists <scenario_name>
# Returns 0 if workspace exists, 1 otherwise.
workspace_exists() {
  local ws
  scenario_name_require_valid "$1" || return 1
  ws=$(workspace_dir "$1")
  [[ -d "$ws/.git" ]]
}

# workspace_destroy <scenario_name>
# Remove a workspace entirely.
workspace_destroy() {
  local ws
  scenario_name_require_valid "$1" || return 1
  ws=$(workspace_dir "$1")
  if [[ -d "$ws" ]]; then
    rm -rf "$ws"
    log_info "Destroyed workspace: $1"
  fi
}

# workspace_diff <scenario_name>
# Show the full diff of what DK created/modified in the workspace.
workspace_diff() {
  local ws
  ws=$(workspace_dir "$1")
  git -C "$ws" diff HEAD 2>/dev/null || true
  git -C "$ws" diff --cached HEAD 2>/dev/null || true
  # Also show untracked files content
  git -C "$ws" ls-files --others --exclude-standard 2>/dev/null | while read -r f; do
    echo "--- /dev/null"
    echo "+++ b/$f"
    cat "$ws/$f" 2>/dev/null || true
  done
}

# workspace_files_changed <scenario_name>
# List all files created or modified by DK.
workspace_files_changed() {
  local ws
  ws=$(workspace_dir "$1")
  {
    git -C "$ws" diff --name-only HEAD 2>/dev/null
    git -C "$ws" diff --cached --name-only HEAD 2>/dev/null
    git -C "$ws" ls-files --others --exclude-standard 2>/dev/null
  } | sort -u
}
