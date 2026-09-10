# shellcheck shell=bash
# Optional CCR integration. Direct provider launches never call Node here.

dx_router_node_check() {
  if ! command -v node >/dev/null 2>&1 || ! node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 22 ? 0 : 1)' >/dev/null 2>&1; then
    dx_error "Optional CCR routing requires Node.js 22 or newer. Direct Claude and Codex profiles remain available."
    return 1
  fi
}

dx_router_command() {
  dx_router_node_check || return 1
  node "$DEX_DIR/scripts/ccr/cli.cjs" "$@"
}

dx_router_launch() {
  dx_router_node_check || return 1
  local router_env=() router_env_name
  while IFS= read -r router_env_name; do
    [[ -n "$router_env_name" ]] && router_env+=(-u "$router_env_name")
  done < <(__dx_provider_env_unset_args)
  env "${router_env[@]}" \
    DX_CLAUDE_MODEL="${DX_CLAUDE_MODEL:-}" \
    DX_MODEL_OVERRIDE="${DX_MODEL_OVERRIDE:-}" \
    node "$DEX_DIR/scripts/ccr/cli.cjs" launch -- "$@"
}
