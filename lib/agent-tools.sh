# shellcheck shell=bash
# Doyaken helpers for conservative Claude/Codex tooling bootstrap.
#
# This module intentionally installs only Doyaken-owned links, official MCP
# servers, and a narrow allowlist of official Claude Code plugins.

DK_CLAUDE_OFFICIAL_MARKETPLACE_NAME="claude-plugins-official"
DK_CLAUDE_OFFICIAL_MARKETPLACE_SOURCE="anthropics/claude-plugins-official"
DK_OPENAI_CODEX_MARKETPLACE_NAME="openai-codex"
DK_OPENAI_CODEX_MARKETPLACE_SOURCE="openai/codex-plugin-cc"
DK_OPENAI_DOCS_MCP_NAME="openaiDeveloperDocs"
DK_OPENAI_DOCS_MCP_URL="https://developers.openai.com/mcp"

dk_claude_dir() {
  printf '%s\n' "$HOME/.claude"
}

dk_claude_link_repairable() {
  local current="$1" kind="$2"
  case "$current" in
    */doyaken*/"$kind"|*/doyaken*/"$kind"/) return 0 ;;
    *) return 1 ;;
  esac
}

dk_repair_claude_doyaken_link() {
  local kind="$1" target="$2" mode="${3:-repair}"
  local claude_dir link current

  claude_dir=$(dk_claude_dir)
  link="$claude_dir/$kind"
  mkdir -p "$claude_dir"

  if [[ -L "$link" ]]; then
    current=$(readlink "$link")
    if [[ "$current" == "$target" ]]; then
      dk_ok "${HOME}/.claude/${kind} -> ${target}"
      return 0
    fi

    if [[ "$mode" == "force" ]] || dk_claude_link_repairable "$current" "$kind"; then
      if rm "$link" && ln -s "$target" "$link"; then
        dk_done "Updated ${HOME}/.claude/${kind} -> ${target}"
        return 0
      fi
      dk_warn "Failed to update ${HOME}/.claude/${kind}"
      return 1
    fi

    dk_warn "${HOME}/.claude/${kind} points to ${current}; leaving it unchanged"
    return 1
  fi

  if [[ -e "$link" ]]; then
    dk_warn "${HOME}/.claude/${kind} exists and is not a symlink; leaving it unchanged"
    return 1
  fi

  if ln -s "$target" "$link"; then
    dk_done "Symlinked ${HOME}/.claude/${kind} -> ${target}"
    return 0
  fi

  dk_warn "Failed to symlink ${HOME}/.claude/${kind}"
  return 1
}

dk_repair_claude_doyaken_links() {
  local mode="${1:-repair}"
  local failed=0

  dk_repair_claude_doyaken_link "skills" "$DOYAKEN_DIR/skills" "$mode" || failed=1
  dk_repair_claude_doyaken_link "agents" "$DOYAKEN_DIR/agents" "$mode" || failed=1

  return "$failed"
}

dk_check_claude_doyaken_links() {
  local failed=0 claude_dir kind target link current
  claude_dir=$(dk_claude_dir)

  for kind in skills agents; do
    target="$DOYAKEN_DIR/$kind"
    link="$claude_dir/$kind"
    if [[ -L "$link" ]]; then
      current=$(readlink "$link")
      if [[ "$current" == "$target" ]]; then
        dk_ok "${HOME}/.claude/${kind} -> ${target}"
      else
        dk_warn "${HOME}/.claude/${kind} points to ${current}; expected ${target}"
        failed=1
      fi
    else
      dk_warn "${HOME}/.claude/${kind} is not linked to Doyaken"
      failed=1
    fi
  done

  return "$failed"
}

dk_refresh_claude_settings() {
  local quiet="${1:-1}"

  if [[ "$quiet" -eq 1 ]]; then
    bash "$DOYAKEN_DIR/bin/install-settings.sh" --quiet
  else
    bash "$DOYAKEN_DIR/bin/install-settings.sh"
  fi
}

dk_claude_plugin_marketplace_configured() {
  local name="$1"
  command -v claude >/dev/null 2>&1 || return 1
  claude plugin marketplace list 2>/dev/null | grep -F "$name" >/dev/null 2>&1
}

dk_ensure_official_claude_marketplace() {
  local name="$1" source="$2"

  case "${name}:${source}" in
    "${DK_CLAUDE_OFFICIAL_MARKETPLACE_NAME}:${DK_CLAUDE_OFFICIAL_MARKETPLACE_SOURCE}"|\
    "${DK_OPENAI_CODEX_MARKETPLACE_NAME}:${DK_OPENAI_CODEX_MARKETPLACE_SOURCE}") ;;
    *)
      dk_warn "Refusing non-official Claude plugin marketplace: ${source}"
      return 1
      ;;
  esac

  if ! command -v claude >/dev/null 2>&1; then
    dk_skip "Claude Code CLI not found; skipping Claude plugin marketplace ${name}"
    return 0
  fi

  if dk_claude_plugin_marketplace_configured "$name"; then
    dk_ok "Claude plugin marketplace '${name}' already configured"
    return 0
  fi

  dk_info "Adding Claude plugin marketplace '${name}'"
  if dk_run_with_timeout 120 claude plugin marketplace add --scope user "$source" >/dev/null; then
    dk_done "Added Claude plugin marketplace '${name}'"
    return 0
  fi

  dk_warn "Could not add Claude plugin marketplace '${name}'"
  return 1
}

dk_safe_official_claude_plugin_allowed() {
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

dk_claude_plugin_status() {
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

  if printf '%s\n' "$plugin_json" | grep -F "\"id\": \"$plugin_ref\"" >/dev/null 2>&1; then
    printf '%s\n' "unknown"
  else
    printf '%s\n' "missing"
  fi
}

dk_install_safe_official_claude_plugin() {
  local plugin_ref="$1" reason="${2:-official Doyaken tooling}"
  local status marketplace

  if ! dk_safe_official_claude_plugin_allowed "$plugin_ref"; then
    dk_warn "Refusing non-allowlisted Claude plugin: ${plugin_ref}"
    return 1
  fi

  if ! command -v claude >/dev/null 2>&1; then
    dk_skip "Claude Code CLI not found; skipping Claude plugin ${plugin_ref}"
    return 0
  fi

  status=$(dk_claude_plugin_status "$plugin_ref")
  case "$status" in
    enabled)
      dk_ok "Claude plugin '${plugin_ref}' already enabled"
      return 0
      ;;
    disabled)
      dk_info "Enabling Claude plugin '${plugin_ref}' (${reason})"
      if dk_run_with_timeout 120 claude plugin enable --scope user "$plugin_ref" >/dev/null; then
        dk_done "Enabled Claude plugin '${plugin_ref}'"
        return 0
      fi
      dk_warn "Could not enable Claude plugin '${plugin_ref}'"
      return 1
      ;;
    missing|unknown) ;;
  esac

  marketplace="${plugin_ref##*@}"
  if [[ "$marketplace" == "$DK_CLAUDE_OFFICIAL_MARKETPLACE_NAME" ]]; then
    dk_ensure_official_claude_marketplace "$DK_CLAUDE_OFFICIAL_MARKETPLACE_NAME" "$DK_CLAUDE_OFFICIAL_MARKETPLACE_SOURCE" || return 1
  elif [[ "$marketplace" == "$DK_OPENAI_CODEX_MARKETPLACE_NAME" ]]; then
    dk_ensure_official_claude_marketplace "$DK_OPENAI_CODEX_MARKETPLACE_NAME" "$DK_OPENAI_CODEX_MARKETPLACE_SOURCE" || return 1
  else
    dk_warn "Refusing plugin from non-official marketplace: ${plugin_ref}"
    return 1
  fi

  dk_info "Installing Claude plugin '${plugin_ref}' (${reason})"
  if dk_run_with_timeout 180 claude plugin install --scope user "$plugin_ref" >/dev/null; then
    dk_done "Installed Claude plugin '${plugin_ref}'"
    return 0
  fi

  dk_info "Updating Claude plugin marketplace '${marketplace}' and retrying '${plugin_ref}'"
  dk_run_with_timeout 180 claude plugin marketplace update "$marketplace" >/dev/null 2>&1 || true
  if dk_run_with_timeout 180 claude plugin install --scope user "$plugin_ref" >/dev/null; then
    dk_done "Installed Claude plugin '${plugin_ref}'"
    return 0
  fi

  dk_warn "Could not install Claude plugin '${plugin_ref}'"
  return 1
}

dk_find_project_file_by_name() {
  local root="$1" name="$2"
  [[ -n "$root" && -d "$root" ]] || return 1

  find "$root" -maxdepth 4 \
    \( -path "*/.git" -o -path "*/.doyaken/worktrees" -o -path "*/node_modules" -o -path "*/vendor" \) -prune \
    -o -type f -name "$name" -print -quit 2>/dev/null
}

dk_find_project_file_by_glob() {
  local root="$1" pattern="$2"
  [[ -n "$root" && -d "$root" ]] || return 1

  find "$root" -maxdepth 4 \
    \( -path "*/.git" -o -path "*/.doyaken/worktrees" -o -path "*/node_modules" -o -path "*/vendor" \) -prune \
    -o -type f -name "$pattern" -print -quit 2>/dev/null
}

dk_project_has_named_file() {
  local root="$1" name
  shift

  for name in "$@"; do
    [[ -n "$(dk_find_project_file_by_name "$root" "$name")" ]] && return 0
  done
  return 1
}

dk_project_has_glob_file() {
  local root="$1" pattern
  shift

  for pattern in "$@"; do
    [[ -n "$(dk_find_project_file_by_glob "$root" "$pattern")" ]] && return 0
  done
  return 1
}

dk_project_package_json_has_dependency() {
  local root="$1" dependency_regex="$2"
  local package_file

  [[ -n "$root" && -d "$root" ]] || return 1

  while IFS= read -r package_file; do
    if grep -Eiq "\"(${dependency_regex})\"[[:space:]]*:" "$package_file" 2>/dev/null; then
      return 0
    fi
  done < <(find "$root" -maxdepth 4 \
    \( -path "*/.git" -o -path "*/.doyaken/worktrees" -o -path "*/node_modules" -o -path "*/vendor" \) -prune \
    -o -type f -name "package.json" -print 2>/dev/null)

  return 1
}

dk_project_uses_javascript_or_typescript() {
  local root="$1"
  dk_project_has_named_file "$root" "package.json" "tsconfig.json" "jsconfig.json" && return 0
  dk_project_has_glob_file "$root" "*.ts" "*.tsx" "*.js" "*.jsx" && return 0
  return 1
}

dk_project_uses_frontend() {
  local root="$1"

  dk_project_package_json_has_dependency "$root" 'react|react-dom|next|vue|@vue/[A-Za-z0-9._/-]+|svelte|@sveltejs/[A-Za-z0-9._/-]+|astro|nuxt|@angular/core|vite|preact|solid-js|@remix-run/[A-Za-z0-9._/-]+' && return 0
  dk_project_has_named_file "$root" "vite.config.ts" "vite.config.js" "next.config.js" "next.config.mjs" "next.config.ts" "svelte.config.js" "astro.config.mjs" "nuxt.config.ts" "tailwind.config.js" "tailwind.config.ts" && return 0
  dk_project_has_glob_file "$root" "*.tsx" "*.jsx" "*.vue" "*.svelte" && return 0

  return 1
}

dk_project_uses_python() {
  local root="$1"
  dk_project_has_named_file "$root" "pyproject.toml" "setup.py" "requirements.txt" "Pipfile" && return 0
  dk_project_has_glob_file "$root" "*.py" && return 0
  return 1
}

dk_project_uses_rust() {
  local root="$1"
  dk_project_has_named_file "$root" "Cargo.toml" && return 0
  return 1
}

dk_project_uses_go() {
  local root="$1"
  dk_project_has_named_file "$root" "go.mod" && return 0
  return 1
}

dk_safe_official_claude_plugins_for_project() {
  local root="${1:-}"

  if command -v codex >/dev/null 2>&1; then
    printf '%s\t%s\n' "codex@openai-codex" "OpenAI Codex slash commands inside Claude Code"
  fi

  [[ -n "$root" && -d "$root" ]] || return 0

  if dk_project_uses_frontend "$root"; then
    printf '%s\t%s\n' "frontend-design@claude-plugins-official" "frontend project design assistance"
  fi
  if dk_project_uses_javascript_or_typescript "$root"; then
    printf '%s\t%s\n' "typescript-lsp@claude-plugins-official" "TypeScript/JavaScript code intelligence"
  fi
  if dk_project_uses_python "$root"; then
    printf '%s\t%s\n' "pyright-lsp@claude-plugins-official" "Python code intelligence"
  fi
  if dk_project_uses_rust "$root"; then
    printf '%s\t%s\n' "rust-analyzer-lsp@claude-plugins-official" "Rust code intelligence"
  fi
  if dk_project_uses_go "$root"; then
    printf '%s\t%s\n' "gopls-lsp@claude-plugins-official" "Go code intelligence"
  fi
}

dk_check_safe_official_claude_plugins() {
  local root="${1:-}" failed=0 plugin_ref reason status

  if ! command -v claude >/dev/null 2>&1; then
    dk_skip "Claude Code CLI not found; skipping Claude plugin check"
    return 0
  fi

  while IFS=$'\t' read -r plugin_ref reason; do
    [[ -n "$plugin_ref" ]] || continue
    status=$(dk_claude_plugin_status "$plugin_ref")
    if [[ "$status" == "enabled" ]]; then
      dk_ok "Claude plugin '${plugin_ref}' enabled"
    else
      dk_warn "Claude plugin '${plugin_ref}' is ${status}; needed for ${reason}"
      failed=1
    fi
  done < <(dk_safe_official_claude_plugins_for_project "$root")

  return "$failed"
}

dk_install_safe_official_claude_plugins() {
  local root="${1:-}" failed=0 plugin_ref reason

  if ! command -v claude >/dev/null 2>&1; then
    dk_skip "Claude Code CLI not found; skipping Claude plugins"
    return 0
  fi

  dk_ensure_official_claude_marketplace "$DK_CLAUDE_OFFICIAL_MARKETPLACE_NAME" "$DK_CLAUDE_OFFICIAL_MARKETPLACE_SOURCE" || failed=1
  if command -v codex >/dev/null 2>&1; then
    dk_ensure_official_claude_marketplace "$DK_OPENAI_CODEX_MARKETPLACE_NAME" "$DK_OPENAI_CODEX_MARKETPLACE_SOURCE" || failed=1
  fi

  while IFS=$'\t' read -r plugin_ref reason; do
    [[ -n "$plugin_ref" ]] || continue
    dk_install_safe_official_claude_plugin "$plugin_ref" "$reason" || failed=1
  done < <(dk_safe_official_claude_plugins_for_project "$root")

  return "$failed"
}

dk_install_claude_openai_docs_mcp_server() {
  if ! command -v claude >/dev/null 2>&1; then
    dk_skip "Claude Code CLI not found; skipping Claude OpenAI docs MCP"
    return 0
  fi

  if dk_claude_mcp_server_exists "$DK_OPENAI_DOCS_MCP_NAME"; then
    dk_ok "Claude MCP server '${DK_OPENAI_DOCS_MCP_NAME}' already configured"
    return 0
  fi

  dk_info "Installing Claude MCP server '${DK_OPENAI_DOCS_MCP_NAME}'"
  if dk_run_with_timeout 120 claude mcp add --transport http --scope user "$DK_OPENAI_DOCS_MCP_NAME" "$DK_OPENAI_DOCS_MCP_URL" >/dev/null; then
    dk_done "Installed Claude MCP server '${DK_OPENAI_DOCS_MCP_NAME}'"
    return 0
  fi

  dk_warn "Could not install Claude MCP server '${DK_OPENAI_DOCS_MCP_NAME}'"
  return 1
}

dk_install_codex_openai_docs_mcp_server() {
  if ! command -v codex >/dev/null 2>&1; then
    dk_skip "Codex CLI not found; skipping Codex OpenAI docs MCP"
    return 0
  fi

  if dk_codex_mcp_server_exists "$DK_OPENAI_DOCS_MCP_NAME"; then
    dk_ok "Codex MCP server '${DK_OPENAI_DOCS_MCP_NAME}' already configured"
    return 0
  fi

  dk_info "Installing Codex MCP server '${DK_OPENAI_DOCS_MCP_NAME}'"
  if dk_run_with_timeout 120 codex mcp add "$DK_OPENAI_DOCS_MCP_NAME" --url "$DK_OPENAI_DOCS_MCP_URL" >/dev/null; then
    dk_done "Installed Codex MCP server '${DK_OPENAI_DOCS_MCP_NAME}'"
    return 0
  fi

  dk_warn "Could not install Codex MCP server '${DK_OPENAI_DOCS_MCP_NAME}'"
  return 1
}

dk_install_openai_docs_mcp_servers() {
  local failed=0

  dk_install_claude_openai_docs_mcp_server || failed=1
  dk_install_codex_openai_docs_mcp_server || failed=1

  return "$failed"
}

dk_check_openai_docs_mcp_servers() {
  local failed=0

  if command -v claude >/dev/null 2>&1; then
    if dk_claude_mcp_server_exists "$DK_OPENAI_DOCS_MCP_NAME"; then
      dk_ok "Claude MCP server '${DK_OPENAI_DOCS_MCP_NAME}' configured"
    else
      dk_warn "Claude MCP server '${DK_OPENAI_DOCS_MCP_NAME}' is not configured"
      failed=1
    fi
  fi

  if command -v codex >/dev/null 2>&1; then
    if dk_codex_mcp_server_exists "$DK_OPENAI_DOCS_MCP_NAME"; then
      dk_ok "Codex MCP server '${DK_OPENAI_DOCS_MCP_NAME}' configured"
    else
      dk_warn "Codex MCP server '${DK_OPENAI_DOCS_MCP_NAME}' is not configured"
      failed=1
    fi
  fi

  return "$failed"
}

dk_check_ui_capture_tooling() {
  local failed=0

  if dk_ui_capture_playwright_ready; then
    dk_ok "Playwright UI capture tooling installed"
  else
    dk_warn "Playwright UI capture tooling is not installed"
    failed=1
  fi

  if command -v claude >/dev/null 2>&1; then
    if dk_claude_mcp_server_exists "playwright"; then
      dk_ok "Claude MCP server 'playwright' configured"
    else
      dk_warn "Claude MCP server 'playwright' is not configured"
      failed=1
    fi
    if dk_claude_mcp_server_exists "chrome-devtools"; then
      dk_ok "Claude MCP server 'chrome-devtools' configured"
    else
      dk_warn "Claude MCP server 'chrome-devtools' is not configured"
      failed=1
    fi
  fi

  if command -v codex >/dev/null 2>&1; then
    if dk_codex_mcp_server_exists "playwright"; then
      dk_ok "Codex MCP server 'playwright' configured"
    else
      dk_warn "Codex MCP server 'playwright' is not configured"
      failed=1
    fi
    if dk_codex_mcp_server_exists "chrome-devtools"; then
      dk_ok "Codex MCP server 'chrome-devtools' configured"
    else
      dk_warn "Codex MCP server 'chrome-devtools' is not configured"
      failed=1
    fi
  fi

  return "$failed"
}

dk_check_codex_skill_links() {
  local expected installed

  if ! command -v codex >/dev/null 2>&1; then
    dk_skip "Codex CLI not found; skipping Codex skill check"
    return 0
  fi

  expected=$(dk_count_doyaken_skills)
  installed=$(dk_count_codex_doyaken_skills)
  if [[ "$expected" -gt 0 && "$installed" -eq "$expected" ]]; then
    dk_ok "Doyaken Codex skills linked (${installed}/${expected})"
    return 0
  fi

  dk_warn "Doyaken Codex skills are not fully linked (${installed}/${expected})"
  return 1
}

dk_bootstrap_agent_tooling() {
  local root="${1:-}" mode="${2:-repair}" failed=0

  if [[ "$mode" == "check" ]]; then
    dk_info "Checking Claude/Codex tooling bootstrap"
    dk_check_claude_doyaken_links || failed=1
    dk_check_codex_skill_links || failed=1
    dk_check_ui_capture_tooling || failed=1
    dk_check_openai_docs_mcp_servers || failed=1
    dk_check_safe_official_claude_plugins "$root" || failed=1
    return "$failed"
  fi

  dk_info "Checking and repairing Claude/Codex tooling bootstrap"
  dk_repair_claude_doyaken_links "repair" || failed=1

  if command -v codex >/dev/null 2>&1; then
    dk_install_codex_skills || failed=1
  else
    dk_skip "Codex CLI not found; skipping Codex skills"
  fi

  dk_install_ui_capture_tooling || failed=1
  dk_install_openai_docs_mcp_servers || failed=1
  dk_install_safe_official_claude_plugins "$root" || failed=1
  dk_refresh_claude_settings 1 || failed=1

  return "$failed"
}
