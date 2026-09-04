#!/usr/bin/env bash
# Record the exact Claude or Codex conversation ID for crash-safe resumption.
set -euo pipefail

# shellcheck disable=SC2034  # read by lib/common.sh while it is sourced
DX_COMMON_MODULES="session"
# shellcheck disable=SC1091
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

[[ -n "${DEX_SESSION_ID:-}" ]] || exit 0
dx_session_id_valid "$DEX_SESSION_ID" || exit 0

HOOK_INPUT=$(cat 2>/dev/null || true)
[[ -n "$HOOK_INPUT" ]] || exit 0

PROVIDER_SESSION_ID=$(printf '%s' "$HOOK_INPUT" | python3 -c '
import json
import sys

try:
    payload = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)

if payload.get("hook_event_name") != "SessionStart":
    raise SystemExit(0)
value = payload.get("session_id", "")
if isinstance(value, str):
    print(value)
' 2>/dev/null || true)
dx_agent_session_handle_valid "$PROVIDER_SESSION_ID" || exit 0

case "${DX_PROVIDER_ENGINE:-}" in
  codex-plugin) AGENT_KIND="codex" ;;
  claude|anthropic-gateway) AGENT_KIND="claude" ;;
  *) exit 0 ;;
esac

if ! dx_agent_session_handle_write \
    "$DEX_SESSION_ID" "$AGENT_KIND" "$PROVIDER_SESSION_ID"; then
  printf '%s\n' \
    "Dex could not save this provider session ID; a later crash may require the provider's session picker." >&2
fi

exit 0
