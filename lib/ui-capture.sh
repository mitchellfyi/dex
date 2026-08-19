# shellcheck shell=bash
# Dex UI capture helpers.
#
# These helpers keep browser automation tooling and generated artifacts outside
# user repositories. Playwright is installed into a Dex-managed tool cache,
# while screenshots/videos/traces are written under DX_ARTIFACT_DIR.

dx_tools_dir() {
  printf '%s\n' "${DX_TOOL_DIR:-$HOME/.claude/.dex-tools}"
}

dx_artifacts_dir() {
  printf '%s\n' "${DX_ARTIFACT_DIR:-$HOME/.claude/.dex-artifacts}"
}

dx_ui_capture_tools_dir() {
  printf '%s\n' "$(dx_tools_dir)/ui-capture"
}

dx_ui_capture_session_dir() {
  local session_id="$1"
  printf '%s\n' "$(dx_artifacts_dir)/ui/${session_id}"
}

dx_ui_capture_manifest_file() {
  local session_id="$1"
  printf '%s\n' "$(dx_ui_capture_session_dir "$session_id")/visual-evidence.md"
}

dx_ui_capture_run_dir() {
  local session_id="$1" run_name="${2:-capture}"
  local timestamp
  # Whole-second timestamps alone collide when two captures start in the same
  # second, silently merging their artifacts into one directory.
  timestamp=$(date +%Y%m%d-%H%M%S)
  printf '%s\n' "$(dx_ui_capture_session_dir "$session_id")/${timestamp}-$$-${run_name}"
}

dx_ui_capture_playwright_ready() {
  local tools_dir
  tools_dir=$(dx_ui_capture_tools_dir)
  [[ -d "$tools_dir/node_modules/playwright" ]] || return 1
  [[ -x "$tools_dir/node_modules/.bin/playwright" ]] || return 1
}

dx_install_ui_capture_playwright() {
  if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1 || ! command -v npx >/dev/null 2>&1; then
    dx_warn "Node.js, npm, and npx are required for UI capture; install Node.js and re-run 'dx install'"
    return 1
  fi

  local tools_dir
  tools_dir=$(dx_ui_capture_tools_dir)
  mkdir -p "$tools_dir"

  if [[ ! -f "$tools_dir/package.json" ]]; then
    local package_tmp="$tools_dir/package.json.tmp.$$"
    if ! printf '%s\n' '{"private":true,"name":"dex-ui-capture-tools","description":"Dex-managed Playwright tooling; do not edit manually."}' >| "$package_tmp" ||
       ! command mv -f "$package_tmp" "$tools_dir/package.json"; then
      command rm -f "$package_tmp" 2>/dev/null || true
      dx_warn "Could not write $tools_dir/package.json"
      return 1
    fi
  fi

  if dx_ui_capture_playwright_ready; then
    dx_ok "Playwright UI capture tooling already installed"
  else
    dx_info "Installing Playwright UI capture tooling into $(dx_ui_capture_tools_dir)"
    if ! (
      cd "$tools_dir" || exit 1
      npm install --no-audit --no-fund --save-exact playwright@latest @playwright/test@latest
    ); then
      dx_warn "Playwright install failed; UI capture will be unavailable"
      return 1
    fi
    dx_done "Installed Playwright UI capture tooling"
  fi

  dx_info "Ensuring Playwright Chromium browser is installed"
  if ! (
    cd "$tools_dir" || exit 1
    npx playwright install chromium
  ); then
    dx_warn "Playwright Chromium download failed; UI capture will be unavailable"
    return 1
  fi
  dx_done "Playwright Chromium browser ready"
}

# __dx_mcp_server_exists <cli> <name>
__dx_mcp_server_exists() {
  local cli="$1" name="$2"
  command -v "$cli" >/dev/null 2>&1 || return 1
  "$cli" mcp get "$name" >/dev/null 2>&1
}

dx_claude_mcp_server_exists() { __dx_mcp_server_exists claude "$1"; }

dx_codex_mcp_server_exists() { __dx_mcp_server_exists codex "$1"; }

# The browser MCP servers Dex installs, as "<name> <npm package>". Both agents
# get the same list; adding a third server is a line here, not another pair of
# near-identical blocks.
DX_UI_MCP_SERVERS='playwright @playwright/mcp@latest
chrome-devtools chrome-devtools-mcp@latest'

# __dx_install_ui_mcp_servers <label> <cli> [scope args...]
# Install every browser MCP server for one agent CLI, skipping ones already
# configured. Returns 1 if any install failed.
__dx_install_ui_mcp_servers() {
  local label="$1" cli="$2"
  shift 2
  local scope_args=("$@")

  if ! command -v "$cli" >/dev/null 2>&1; then
    dx_skip "${label} CLI not found; skipping ${label} MCP browser servers"
    return 0
  fi

  local failed=0 name package
  while read -r name package; do
    [[ -n "$name" ]] || continue
    if __dx_mcp_server_exists "$cli" "$name"; then
      dx_ok "${label} MCP server '${name}' already configured"
      continue
    fi
    dx_info "Installing ${label} MCP server '${name}'"
    if "$cli" mcp add ${scope_args[@]+"${scope_args[@]}"} "$name" -- npx -y "$package" >/dev/null; then
      dx_done "Installed ${label} MCP server '${name}'"
    else
      dx_warn "Could not install ${label} MCP server '${name}'"
      failed=1
    fi
  done <<EOF
$DX_UI_MCP_SERVERS
EOF

  return "$failed"
}

dx_install_claude_ui_mcp_servers() {
  __dx_install_ui_mcp_servers "Claude" claude --scope user
}

dx_install_codex_ui_mcp_servers() {
  __dx_install_ui_mcp_servers "Codex" codex
}

dx_install_ui_capture_tooling() {
  local failed=0

  dx_install_ui_capture_playwright || failed=1
  dx_install_claude_ui_mcp_servers || failed=1
  dx_install_codex_ui_mcp_servers || failed=1

  return "$failed"
}
