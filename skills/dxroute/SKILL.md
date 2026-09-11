---
name: dxroute
description: Inspect the active Dex subscription route, accounts, and model fallback policy.
---

Run `bash "$DEX_DIR/bin/router.sh" route status`. It selects the current routed
session through `DX_ROUTER_SESSION_ID`. If several sessions are active outside
a routed agent, use the user's selected `--session` identifier.

Explain the current model, account, phase policy, and any cooldown. For quota,
run `bash "$DEX_DIR/bin/router.sh" accounts`. Preserve unknown and stale readings.
If routing is disabled, explain that `dx router setup` is optional. Do not
install or enable it merely to show status. Never read credential files.
