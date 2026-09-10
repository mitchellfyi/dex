---
name: dxaccount
description: Inspect or select subscription accounts for the current Dex routed session.
---

Run `bash "$DEX_DIR/bin/router.sh" accounts` to show account labels, quota
windows and reset times. Unknown or stale usage must remain labelled that way.

When explicitly asked to use an account, run
`bash "$DEX_DIR/bin/router.sh" route pin-account <name>` in the current session.
For automatic selection, run `route unpin-account`. A pin is strict: an
unavailable pinned account pauses requests instead of choosing another account.

Account registration needs the user's native browser or device login. Direct
them to `dx account add` in a terminal. Never inspect, copy, or print credentials.
