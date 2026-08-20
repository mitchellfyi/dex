# shellcheck shell=bash
# Dex helpers for conservative Claude/Codex tooling bootstrap.
#
# This module intentionally installs only Dex-owned links, official MCP
# servers, and a narrow allowlist of official Claude Code plugins.

DX_CLAUDE_OFFICIAL_MARKETPLACE_NAME="claude-plugins-official"
DX_CLAUDE_OFFICIAL_MARKETPLACE_SOURCE="anthropics/claude-plugins-official"
DX_OPENAI_CODEX_MARKETPLACE_NAME="openai-codex"
DX_OPENAI_CODEX_MARKETPLACE_SOURCE="openai/codex-plugin-cc"
DX_OPENAI_DOCS_MCP_NAME="openaiDeveloperDocs"
DX_OPENAI_DOCS_MCP_URL="https://developers.openai.com/mcp"

dx_claude_dir() {
  printf '%s\n' "$HOME/.claude"
}

# Per-skill link management is shared with the Codex path; the helpers live
# in lib/codex.sh.
dx_install_claude_skill_links() {
  __dx_install_skill_links "$1" "Claude Code"
}

dx_count_claude_dex_skill_links() {
  __dx_count_dex_skill_links "$1"
}

dx_install_claude_dex_link() {
  local kind="$1" target="$2"
  local claude_dir link current

  claude_dir=$(dx_claude_dir)
  link="$claude_dir/$kind"
  mkdir -p "$claude_dir"

  if [[ -L "$link" ]]; then
    current=$(readlink "$link")
    if [[ "$current" == "$target" ]]; then
      dx_ok "${HOME}/.claude/${kind} -> ${target}"
      return 0
    fi

    dx_warn "${HOME}/.claude/${kind} points to ${current}; leaving it unchanged"
    return 1
  fi

  if [[ -e "$link" ]]; then
    dx_warn "${HOME}/.claude/${kind} exists and is not a symlink; leaving it unchanged"
    return 1
  fi

  if ln -s "$target" "$link"; then
    dx_done "Symlinked ${HOME}/.claude/${kind} -> ${target}"
    return 0
  fi

  dx_warn "Failed to symlink ${HOME}/.claude/${kind}"
  return 1
}

dx_install_claude_dex_links() {
  local failed=0 claude_dir skills_link

  claude_dir=$(dx_claude_dir)
  skills_link="$claude_dir/skills"

  if [[ -d "$skills_link" && ! -L "$skills_link" ]]; then
    dx_install_claude_skill_links "$skills_link" || failed=1
  else
    dx_install_claude_dex_link "skills" "$DEX_DIR/skills" || failed=1
  fi

  return "$failed"
}

dx_check_claude_dex_links() {
  local failed=0 claude_dir link current installed expected
  claude_dir=$(dx_claude_dir)

  link="$claude_dir/skills"
  if [[ -L "$link" ]]; then
    current=$(readlink "$link")
    if [[ "$current" == "$DEX_DIR/skills" ]]; then
      dx_ok "${HOME}/.claude/skills -> ${DEX_DIR}/skills"
    else
      dx_warn "${HOME}/.claude/skills points to ${current}; expected ${DEX_DIR}/skills"
      failed=1
    fi
  elif [[ -d "$link" ]]; then
    installed=$(dx_count_claude_dex_skill_links "$link")
    expected=$(dx_count_dex_skills)
    if [[ "$installed" -eq "$expected" && "$expected" -gt 0 ]]; then
      dx_ok "${HOME}/.claude/skills has ${installed}/${expected} Dex skill link(s)"
    else
      dx_warn "${HOME}/.claude/skills has ${installed}/${expected} Dex skill link(s)"
      failed=1
    fi
  else
    dx_warn "${HOME}/.claude/skills is not linked to Dex"
    failed=1
  fi

  return "$failed"
}

dx_refresh_claude_settings() {
  local quiet="${1:-1}"

  if [[ "$quiet" -eq 1 ]]; then
    bash "$DEX_DIR/bin/install-settings.sh" --quiet
  else
    bash "$DEX_DIR/bin/install-settings.sh"
  fi
}

dx_claude_settings_complete() {
  local settings_file="$HOME/.claude/settings.json"
  local template_file="$DEX_DIR/settings.json"
  local helper="$DEX_DIR/scripts/settings-json.py"

  command -v python3 >/dev/null 2>&1 || return 1
  [[ -f "$settings_file" && -f "$template_file" && -f "$helper" ]] || return 1

  python3 "$helper" settings-complete \
    "$settings_file" "$template_file" "$DEX_DIR" "$HOME" >/dev/null 2>&1
}

dx_check_claude_settings() {
  if dx_claude_settings_complete; then
    dx_ok "Claude hooks and worktree settings are complete"
    return 0
  fi

  if [[ -f "$HOME/.claude/settings.json" ]]; then
    dx_warn "Claude settings are incomplete; run 'dx tools bootstrap' to repair Dex-managed entries"
  else
    dx_warn "Claude settings are not installed; run 'dx tools bootstrap'"
  fi
  return 1
}

dx_claude_plugin_marketplace_configured() {
  local name="$1"
  command -v claude >/dev/null 2>&1 || return 1
  # Match the marketplace name as a whole field. A substring match reports an
  # unrelated entry that merely contains the name (a fork, say) as configured,
  # and the add step is then skipped so the later plugin install fails with a
  # confusing error.
  claude plugin marketplace list 2>/dev/null |
    awk -v want="$name" '{ for (i = 1; i <= NF; i++) if ($i == want) found = 1 }
                         END { exit found ? 0 : 1 }'
}

dx_ensure_official_claude_marketplace() {
  local name="$1" source="$2"

  case "${name}:${source}" in
    "${DX_CLAUDE_OFFICIAL_MARKETPLACE_NAME}:${DX_CLAUDE_OFFICIAL_MARKETPLACE_SOURCE}"|\
    "${DX_OPENAI_CODEX_MARKETPLACE_NAME}:${DX_OPENAI_CODEX_MARKETPLACE_SOURCE}") ;;
    *)
      dx_warn "Refusing non-official Claude plugin marketplace: ${source}"
      return 1
      ;;
  esac

  if ! command -v claude >/dev/null 2>&1; then
    dx_skip "Claude Code CLI not found; skipping Claude plugin marketplace ${name}"
    return 0
  fi

  if dx_claude_plugin_marketplace_configured "$name"; then
    dx_ok "Claude plugin marketplace '${name}' already configured"
    return 0
  fi

  dx_info "Adding Claude plugin marketplace '${name}'"
  if dx_run_with_timeout 120 claude plugin marketplace add --scope user "$source" >/dev/null; then
    dx_done "Added Claude plugin marketplace '${name}'"
    return 0
  fi

  dx_warn "Could not add Claude plugin marketplace '${name}'"
  return 1
}

dx_safe_official_claude_plugin_allowed() {
  local plugin_ref="$1"
  case "$plugin_ref" in
    codex@openai-codex|\
    frontend-design@claude-plugins-official|\
    typescript-lsp@claude-plugins-official|\
    pyright-lsp@claude-plugins-official|\
    rust-analyzer-lsp@claude-plugins-official|\
    gopls-lsp@claude-plugins-official) return 0 ;;
    *) return 1 ;;
  esac
}

dx_claude_plugin_status() {
  local plugin_ref="$1" plugin_json

  command -v claude >/dev/null 2>&1 || {
    printf '%s\n' "missing"
    return 0
  }

  if ! plugin_json=$(claude plugin list --json 2>/dev/null); then
    printf '%s\n' "unknown"
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    printf '%s\n' "$plugin_json" | python3 -c '
import json
import sys

target = sys.argv[1]
try:
    plugins = json.load(sys.stdin)
except Exception:
    print("unknown")
    raise SystemExit(0)

for plugin in plugins:
    if plugin.get("id") == target:
        print("enabled" if plugin.get("enabled") else "disabled")
        raise SystemExit(0)

print("missing")
' "$plugin_ref"
    return 0
  fi

  if grep -F "\"id\": \"$plugin_ref\"" >/dev/null 2>&1 <<< "$plugin_json"; then
    printf '%s\n' "unknown"
  else
    printf '%s\n' "missing"
  fi
}

dx_install_safe_official_claude_plugin() {
  local plugin_ref="$1" reason="${2:-official Dex tooling}"
  local plugin_status marketplace

  if ! dx_safe_official_claude_plugin_allowed "$plugin_ref"; then
    dx_warn "Refusing non-allowlisted Claude plugin: ${plugin_ref}"
    return 1
  fi

  if ! command -v claude >/dev/null 2>&1; then
    dx_skip "Claude Code CLI not found; skipping Claude plugin ${plugin_ref}"
    return 0
  fi

  plugin_status=$(dx_claude_plugin_status "$plugin_ref")
  case "$plugin_status" in
    enabled)
      dx_ok "Claude plugin '${plugin_ref}' already enabled"
      return 0
      ;;
    disabled)
      dx_info "Enabling Claude plugin '${plugin_ref}' (${reason})"
      if dx_run_with_timeout 120 claude plugin enable --scope user "$plugin_ref" >/dev/null; then
        dx_done "Enabled Claude plugin '${plugin_ref}'"
        return 0
      fi
      dx_warn "Could not enable Claude plugin '${plugin_ref}'"
      return 1
      ;;
    missing|unknown) ;;
  esac

  marketplace="${plugin_ref##*@}"
  if [[ "$marketplace" == "$DX_CLAUDE_OFFICIAL_MARKETPLACE_NAME" ]]; then
    dx_ensure_official_claude_marketplace "$DX_CLAUDE_OFFICIAL_MARKETPLACE_NAME" "$DX_CLAUDE_OFFICIAL_MARKETPLACE_SOURCE" || return 1
  elif [[ "$marketplace" == "$DX_OPENAI_CODEX_MARKETPLACE_NAME" ]]; then
    dx_ensure_official_claude_marketplace "$DX_OPENAI_CODEX_MARKETPLACE_NAME" "$DX_OPENAI_CODEX_MARKETPLACE_SOURCE" || return 1
  else
    dx_warn "Refusing plugin from non-official marketplace: ${plugin_ref}"
    return 1
  fi

  dx_info "Installing Claude plugin '${plugin_ref}' (${reason})"
  if dx_run_with_timeout 180 claude plugin install --scope user "$plugin_ref" >/dev/null; then
    dx_done "Installed Claude plugin '${plugin_ref}'"
    return 0
  fi

  dx_info "Updating Claude plugin marketplace '${marketplace}' and retrying '${plugin_ref}'"
  dx_run_with_timeout 180 claude plugin marketplace update "$marketplace" >/dev/null 2>&1 || true
  if dx_run_with_timeout 180 claude plugin install --scope user "$plugin_ref" >/dev/null; then
    dx_done "Installed Claude plugin '${plugin_ref}'"
    return 0
  fi

  dx_warn "Could not install Claude plugin '${plugin_ref}'"
  return 1
}

# `find -name` treats exact names and glob patterns identically, so one finder
# serves both spellings.
dx_find_project_file() {
  local root="$1" pattern="$2"
  [[ -n "$root" && -d "$root" ]] || return 1

  find "$root" -maxdepth 4 \
    \( -path "*/.git" -o -path "*/.dex/worktrees" -o -path "*/node_modules" -o -path "*/vendor" \) -prune \
    -o -type f -name "$pattern" -print -quit 2>/dev/null
}

dx_project_has_file() {
  local root="$1" pattern
  shift

  for pattern in "$@"; do
    [[ -n "$(dx_find_project_file "$root" "$pattern")" ]] && return 0
  done
  return 1
}

dx_project_package_json_has_dependency() {
  local root="$1" dependency_regex="$2"
  local package_file

  [[ -n "$root" && -d "$root" ]] || return 1

  while IFS= read -r package_file; do
    if grep -Eiq "\"(${dependency_regex})\"[[:space:]]*:" "$package_file" 2>/dev/null; then
      return 0
    fi
  done < <(find "$root" -maxdepth 4 \
    \( -path "*/.git" -o -path "*/.dex/worktrees" -o -path "*/node_modules" -o -path "*/vendor" \) -prune \
    -o -type f -name "package.json" -print 2>/dev/null)

  return 1
}

dx_project_uses_javascript_or_typescript() {
  local root="$1"
  dx_project_has_file "$root" "package.json" "tsconfig.json" "jsconfig.json" && return 0
  dx_project_has_file "$root" "*.ts" "*.tsx" "*.js" "*.jsx" && return 0
  return 1
}

dx_project_uses_frontend() {
  local root="$1"

  dx_project_package_json_has_dependency "$root" 'react|react-dom|next|vue|@vue/[A-Za-z0-9._/-]+|svelte|@sveltejs/[A-Za-z0-9._/-]+|astro|nuxt|@angular/core|vite|preact|solid-js|@remix-run/[A-Za-z0-9._/-]+' && return 0
  dx_project_has_file "$root" "vite.config.ts" "vite.config.js" "next.config.js" "next.config.mjs" "next.config.ts" "svelte.config.js" "astro.config.mjs" "nuxt.config.ts" "tailwind.config.js" "tailwind.config.ts" && return 0
  dx_project_has_file "$root" "*.tsx" "*.jsx" "*.vue" "*.svelte" && return 0

  return 1
}

dx_project_uses_python() {
  local root="$1"
  dx_project_has_file "$root" "pyproject.toml" "setup.py" "requirements.txt" "Pipfile" && return 0
  dx_project_has_file "$root" "*.py" && return 0
  return 1
}

dx_project_uses_rust() {
  local root="$1"
  dx_project_has_file "$root" "Cargo.toml" && return 0
  return 1
}

dx_project_uses_go() {
  local root="$1"
  dx_project_has_file "$root" "go.mod" && return 0
  return 1
}

dx_safe_official_claude_plugins_for_project() {
  local root="${1:-}"

  if command -v codex >/dev/null 2>&1; then
    printf '%s\t%s\n' "codex@openai-codex" "OpenAI Codex slash commands inside Claude Code"
  fi

  [[ -n "$root" && -d "$root" ]] || return 0

  if dx_project_uses_frontend "$root"; then
    printf '%s\t%s\n' "frontend-design@claude-plugins-official" "frontend project design assistance"
  fi
  if dx_project_uses_javascript_or_typescript "$root"; then
    printf '%s\t%s\n' "typescript-lsp@claude-plugins-official" "TypeScript/JavaScript code intelligence"
  fi
  if dx_project_uses_python "$root"; then
    printf '%s\t%s\n' "pyright-lsp@claude-plugins-official" "Python code intelligence"
  fi
  if dx_project_uses_rust "$root"; then
    printf '%s\t%s\n' "rust-analyzer-lsp@claude-plugins-official" "Rust code intelligence"
  fi
  if dx_project_uses_go "$root"; then
    printf '%s\t%s\n' "gopls-lsp@claude-plugins-official" "Go code intelligence"
  fi
}

dx_check_safe_official_claude_plugins() {
  local root="${1:-}" failed=0 plugin_ref reason plugin_status

  if ! command -v claude >/dev/null 2>&1; then
    dx_skip "Claude Code CLI not found; skipping Claude plugin check"
    return 0
  fi

  while IFS=$'\t' read -r plugin_ref reason; do
    [[ -n "$plugin_ref" ]] || continue
    plugin_status=$(dx_claude_plugin_status "$plugin_ref")
    if [[ "$plugin_status" == "enabled" ]]; then
      dx_ok "Claude plugin '${plugin_ref}' enabled"
    else
      dx_warn "Claude plugin '${plugin_ref}' is ${plugin_status}; needed for ${reason}"
      failed=1
    fi
  done < <(dx_safe_official_claude_plugins_for_project "$root")

  return "$failed"
}

dx_install_safe_official_claude_plugins() {
  local root="${1:-}" failed=0 plugin_ref reason

  if ! command -v claude >/dev/null 2>&1; then
    dx_skip "Claude Code CLI not found; skipping Claude plugins"
    return 0
  fi

  dx_ensure_official_claude_marketplace "$DX_CLAUDE_OFFICIAL_MARKETPLACE_NAME" "$DX_CLAUDE_OFFICIAL_MARKETPLACE_SOURCE" || failed=1
  if command -v codex >/dev/null 2>&1; then
    dx_ensure_official_claude_marketplace "$DX_OPENAI_CODEX_MARKETPLACE_NAME" "$DX_OPENAI_CODEX_MARKETPLACE_SOURCE" || failed=1
  fi

  while IFS=$'\t' read -r plugin_ref reason; do
    [[ -n "$plugin_ref" ]] || continue
    dx_install_safe_official_claude_plugin "$plugin_ref" "$reason" || failed=1
  done < <(dx_safe_official_claude_plugins_for_project "$root")

  return "$failed"
}

dx_install_claude_openai_docs_mcp_server() {
  if ! command -v claude >/dev/null 2>&1; then
    dx_skip "Claude Code CLI not found; skipping Claude OpenAI docs MCP"
    return 0
  fi

  if dx_claude_mcp_server_exists "$DX_OPENAI_DOCS_MCP_NAME"; then
    dx_ok "Claude MCP server '${DX_OPENAI_DOCS_MCP_NAME}' already configured"
    return 0
  fi

  dx_info "Installing Claude MCP server '${DX_OPENAI_DOCS_MCP_NAME}'"
  if dx_run_with_timeout 120 claude mcp add --transport http --scope user "$DX_OPENAI_DOCS_MCP_NAME" "$DX_OPENAI_DOCS_MCP_URL" >/dev/null; then
    dx_done "Installed Claude MCP server '${DX_OPENAI_DOCS_MCP_NAME}'"
    return 0
  fi

  dx_warn "Could not install Claude MCP server '${DX_OPENAI_DOCS_MCP_NAME}'"
  return 1
}

dx_install_codex_openai_docs_mcp_server() {
  if ! command -v codex >/dev/null 2>&1; then
    dx_skip "Codex CLI not found; skipping Codex OpenAI docs MCP"
    return 0
  fi

  if dx_codex_mcp_server_exists "$DX_OPENAI_DOCS_MCP_NAME"; then
    dx_ok "Codex MCP server '${DX_OPENAI_DOCS_MCP_NAME}' already configured"
    return 0
  fi

  dx_info "Installing Codex MCP server '${DX_OPENAI_DOCS_MCP_NAME}'"
  if dx_run_with_timeout 120 codex mcp add "$DX_OPENAI_DOCS_MCP_NAME" --url "$DX_OPENAI_DOCS_MCP_URL" >/dev/null; then
    dx_done "Installed Codex MCP server '${DX_OPENAI_DOCS_MCP_NAME}'"
    return 0
  fi

  dx_warn "Could not install Codex MCP server '${DX_OPENAI_DOCS_MCP_NAME}'"
  return 1
}

dx_install_openai_docs_mcp_servers() {
  local failed=0

  dx_install_claude_openai_docs_mcp_server || failed=1
  dx_install_codex_openai_docs_mcp_server || failed=1

  return "$failed"
}

dx_check_openai_docs_mcp_servers() {
  local failed=0

  if command -v claude >/dev/null 2>&1; then
    if dx_claude_mcp_server_exists "$DX_OPENAI_DOCS_MCP_NAME"; then
      dx_ok "Claude MCP server '${DX_OPENAI_DOCS_MCP_NAME}' configured"
    else
      dx_warn "Claude MCP server '${DX_OPENAI_DOCS_MCP_NAME}' is not configured"
      failed=1
    fi
  fi

  if command -v codex >/dev/null 2>&1; then
    if dx_codex_mcp_server_exists "$DX_OPENAI_DOCS_MCP_NAME"; then
      dx_ok "Codex MCP server '${DX_OPENAI_DOCS_MCP_NAME}' configured"
    else
      dx_warn "Codex MCP server '${DX_OPENAI_DOCS_MCP_NAME}' is not configured"
      failed=1
    fi
  fi

  return "$failed"
}

dx_check_ui_capture_tooling() {
  local failed=0

  if dx_ui_capture_playwright_ready; then
    dx_ok "Playwright UI capture tooling installed"
  else
    dx_warn "Playwright UI capture tooling is not installed"
    failed=1
  fi

  if command -v claude >/dev/null 2>&1; then
    if dx_claude_mcp_server_exists "playwright"; then
      dx_ok "Claude MCP server 'playwright' configured"
    else
      dx_warn "Claude MCP server 'playwright' is not configured"
      failed=1
    fi
    if dx_claude_mcp_server_exists "chrome-devtools"; then
      dx_ok "Claude MCP server 'chrome-devtools' configured"
    else
      dx_warn "Claude MCP server 'chrome-devtools' is not configured"
      failed=1
    fi
  fi

  if command -v codex >/dev/null 2>&1; then
    if dx_codex_mcp_server_exists "playwright"; then
      dx_ok "Codex MCP server 'playwright' configured"
    else
      dx_warn "Codex MCP server 'playwright' is not configured"
      failed=1
    fi
    if dx_codex_mcp_server_exists "chrome-devtools"; then
      dx_ok "Codex MCP server 'chrome-devtools' configured"
    else
      dx_warn "Codex MCP server 'chrome-devtools' is not configured"
      failed=1
    fi
  fi

  return "$failed"
}

dx_check_codex_skill_links() {
  local expected installed

  if ! command -v codex >/dev/null 2>&1; then
    dx_skip "Codex CLI not found; skipping Codex skill check"
    return 0
  fi

  expected=$(dx_count_dex_skills)
  installed=$(dx_count_codex_dex_skills)
  if [[ "$expected" -gt 0 && "$installed" -eq "$expected" ]]; then
    dx_ok "Dex Codex skills linked (${installed}/${expected})"
    return 0
  fi

  dx_warn "Dex Codex skills are not fully linked (${installed}/${expected})"
  return 1
}

dx_bootstrap_agent_tooling() {
  local root="${1:-}" mode="${2:-install}" failed=0

  if [[ "$mode" == "check" ]]; then
    dx_info "Checking Claude/Codex tooling bootstrap"
    dx_check_claude_dex_links || failed=1
    dx_check_claude_settings || failed=1
    dx_check_codex_skill_links || failed=1
    dx_check_ui_capture_tooling || failed=1
    dx_check_rtk_tooling || failed=1
    dx_check_openai_docs_mcp_servers || failed=1
    dx_check_safe_official_claude_plugins "$root" || failed=1
    return "$failed"
  fi

  dx_info "Installing Claude/Codex tooling bootstrap"
  dx_install_claude_dex_links || failed=1

  if command -v codex >/dev/null 2>&1; then
    dx_install_codex_skills || failed=1
  else
    dx_skip "Codex CLI not found; skipping Codex skills"
  fi

  dx_install_ui_capture_tooling || failed=1
  dx_install_rtk_tooling || failed=1
  dx_install_openai_docs_mcp_servers || failed=1
  dx_install_safe_official_claude_plugins "$root" || failed=1
  if dx_refresh_claude_settings 1; then
    if ! dx_claude_settings_complete; then
      dx_warn "Claude settings remain incomplete after repair"
      failed=1
    fi
  else
    failed=1
  fi

  return "$failed"
}
