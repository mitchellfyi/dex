# shellcheck shell=bash
# Doyaken UI capture helpers.
#
# These helpers keep browser automation tooling and generated artifacts outside
# user repositories. Playwright is installed into a Doyaken-managed tool cache,
# while screenshots/videos/traces are written under DK_ARTIFACT_DIR.

dk_tools_dir() {
  printf '%s\n' "${DK_TOOL_DIR:-$HOME/.claude/.doyaken-tools}"
}

dk_artifacts_dir() {
  printf '%s\n' "${DK_ARTIFACT_DIR:-$HOME/.claude/.doyaken-artifacts}"
}

dk_ui_capture_tools_dir() {
  printf '%s\n' "$(dk_tools_dir)/ui-capture"
}

dk_ui_capture_session_dir() {
  local session_id="$1"
  printf '%s\n' "$(dk_artifacts_dir)/ui/${session_id}"
}

dk_ui_capture_manifest_file() {
  local session_id="$1"
  printf '%s\n' "$(dk_ui_capture_session_dir "$session_id")/visual-evidence.md"
}

dk_ui_capture_run_dir() {
  local session_id="$1" run_name="${2:-capture}"
  local timestamp
  timestamp=$(date +%Y%m%d-%H%M%S)
  printf '%s\n' "$(dk_ui_capture_session_dir "$session_id")/${timestamp}-${run_name}"
}

dk_ui_capture_playwright_ready() {
  local tools_dir
  tools_dir=$(dk_ui_capture_tools_dir)
  [[ -d "$tools_dir/node_modules/playwright" ]] || return 1
  [[ -x "$tools_dir/node_modules/.bin/playwright" ]] || return 1
}

dk_install_ui_capture_playwright() {
  if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1 || ! command -v npx >/dev/null 2>&1; then
    dk_warn "Node.js, npm, and npx are required for UI capture; install Node.js and re-run 'dk install'"
    return 1
  fi

  local tools_dir
  tools_dir=$(dk_ui_capture_tools_dir)
  mkdir -p "$tools_dir"

  if [[ ! -f "$tools_dir/package.json" ]]; then
    printf '%s\n' '{"private":true,"name":"doyaken-ui-capture-tools","description":"Doyaken-managed Playwright tooling; do not edit manually."}' > "$tools_dir/package.json"
  fi

  if dk_ui_capture_playwright_ready; then
    dk_ok "Playwright UI capture tooling already installed"
  else
    dk_info "Installing Playwright UI capture tooling into $(dk_ui_capture_tools_dir)"
    (
      cd "$tools_dir" || exit 1
      npm install --no-audit --no-fund --save-exact playwright@latest @playwright/test@latest
    )
    dk_done "Installed Playwright UI capture tooling"
  fi

  dk_info "Ensuring Playwright Chromium browser is installed"
  (
    cd "$tools_dir" || exit 1
    npx playwright install chromium
  )
  dk_done "Playwright Chromium browser ready"
}

dk_claude_mcp_server_exists() {
  local name="$1"
  command -v claude >/dev/null 2>&1 || return 1
  claude mcp get "$name" >/dev/null 2>&1
}

dk_codex_mcp_server_exists() {
  local name="$1"
  command -v codex >/dev/null 2>&1 || return 1
  codex mcp get "$name" >/dev/null 2>&1
}

dk_install_claude_ui_mcp_servers() {
  if ! command -v claude >/dev/null 2>&1; then
    dk_skip "Claude Code CLI not found; skipping Claude MCP browser servers"
    return 0
  fi

  local failed=0
  if dk_claude_mcp_server_exists "playwright"; then
    dk_ok "Claude MCP server 'playwright' already configured"
  else
    dk_info "Installing Claude MCP server 'playwright'"
    if claude mcp add --scope user playwright -- npx -y @playwright/mcp@latest >/dev/null; then
      dk_done "Installed Claude MCP server 'playwright'"
    else
      dk_warn "Could not install Claude MCP server 'playwright'"
      failed=1
    fi
  fi

  if dk_claude_mcp_server_exists "chrome-devtools"; then
    dk_ok "Claude MCP server 'chrome-devtools' already configured"
  else
    dk_info "Installing Claude MCP server 'chrome-devtools'"
    if claude mcp add --scope user chrome-devtools -- npx -y chrome-devtools-mcp@latest >/dev/null; then
      dk_done "Installed Claude MCP server 'chrome-devtools'"
    else
      dk_warn "Could not install Claude MCP server 'chrome-devtools'"
      failed=1
    fi
  fi

  return "$failed"
}

dk_install_codex_ui_mcp_servers() {
  if ! command -v codex >/dev/null 2>&1; then
    dk_skip "Codex CLI not found; skipping Codex MCP browser servers"
    return 0
  fi

  local failed=0
  if dk_codex_mcp_server_exists "playwright"; then
    dk_ok "Codex MCP server 'playwright' already configured"
  else
    dk_info "Installing Codex MCP server 'playwright'"
    if codex mcp add playwright -- npx -y @playwright/mcp@latest >/dev/null; then
      dk_done "Installed Codex MCP server 'playwright'"
    else
      dk_warn "Could not install Codex MCP server 'playwright'"
      failed=1
    fi
  fi

  if dk_codex_mcp_server_exists "chrome-devtools"; then
    dk_ok "Codex MCP server 'chrome-devtools' already configured"
  else
    dk_info "Installing Codex MCP server 'chrome-devtools'"
    if codex mcp add chrome-devtools -- npx -y chrome-devtools-mcp@latest >/dev/null; then
      dk_done "Installed Codex MCP server 'chrome-devtools'"
    else
      dk_warn "Could not install Codex MCP server 'chrome-devtools'"
      failed=1
    fi
  fi

  return "$failed"
}

dk_install_ui_capture_tooling() {
  local failed=0

  dk_install_ui_capture_playwright || failed=1
  dk_install_claude_ui_mcp_servers || failed=1
  dk_install_codex_ui_mcp_servers || failed=1

  return "$failed"
}
