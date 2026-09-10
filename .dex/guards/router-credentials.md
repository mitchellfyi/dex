---
name: warn-router-credentials
enabled: true
event: file
pattern: (^|/)(\.dex/router/(credentials|logins)|ccr-home|ccr-data)(/|$)
action: warn
match: path
---

This path belongs to subscription credential storage or CCR's private runtime.
Use `dx account` commands to manage identities. Keep tokens, native login files
and CCR databases out of repository changes, logs and DexCode uploads. Tests
must use isolated directories and synthetic credentials.
