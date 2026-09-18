#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC2034
DX_COMMON_MODULES="output provider router"
# shellcheck disable=SC1091
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: dx router <setup|install|start|stop|restart|status|doctor|ui|enable|disable|update>
       dx router native <enable|disable|status>
       dx account add [anthropic|openai] [--name <name>] [--device] [--yes]
       dx account <show|rename|rank|enable|disable|reauth|remove|doctor> <name>
       dx account rank <name> <rank>
       dx accounts [--live|--watch|--json]
       dx model <list|current|discover <account>>
       dx model add <provider/model> --context <tokens> --tools [--images]
       dx route configure <provider/model> [--phase <0-6|name>|--client <claude|codex>] [--fallback <model>] [--effort <effort>]
       dx route <status|use <model|auto>|pin-account <name>|unpin-account> [--session <id>]
       dx route use <provider/model> [--scope <phase|session>]
       dx route policy

CCR is optional. It uses subscription OAuth accounts and a private local gateway.
Router setup and enable select ccr-subscription as the global Dex default.
Use 'dx router disable' to disable new routed sessions and restore native CLI settings.
Plain claude and codex keep their native subscriptions unless native routing is explicitly enabled.
Use 'dx router native disable' to restore independent CLI launches, then start new sessions.
The optional 'dx router native enable' changes both clients' global routing defaults.
Direct Claude and Codex profiles work without CCR or its Node dependencies.
Use --json for machine-readable output. Removing an account requires --yes outside a terminal.
Use dx accounts --live (or --watch) to update the table in place every 30 seconds.
Press Ctrl+C to exit the live view. Live mode requires a terminal and cannot use --json.
EOF
}

for router_arg in "$@"; do
  case "$router_arg" in -h|--help|help) usage; exit 0 ;; esac
done
[[ $# -gt 0 ]] || { usage; exit 0; }
dx_router_command "$@"
