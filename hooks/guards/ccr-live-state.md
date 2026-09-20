---
name: warn-ccr-live-state
enabled: true
event: bash
pattern: \b(?:node|python3?)\s+(?:-[a-z]*[epc]\b|--eval\b|--print\b|-(?=[\s<]|$)|<<)[\s\S]*?(?:scripts/ccr/(?:native|state|adapter|service|policy|accounts|ipc|launch|extension)\b|clientSettings|syncContext\b|saveBackend\b|native-client-settings|\.dex/router\b)
action: warn
---

An ad-hoc interpreter call is touching CCR router internals or the live
router state under `~/.dex/router/`.

That state decides whether the user can run claude and codex at all, so
writing to it outside the CLI has locked users out of their own agents: a
`node -e` enable call with a hand-built `{ gateway }` argument once installed
`ANTHROPIC_BASE_URL=undefined/plugins/dex` into the live
`~/.claude/settings.json`, and the drift it left in the ownership record made
both `dx router native enable` and `dx router native disable` refuse to run.

Reading state to diagnose is fine, and `dx router status` or `dx router
doctor` answers most questions without touching files. For anything else,
check which path this command is on:

- Tests and experiments sandbox the way `tests/ccr-*.test.cjs` do:
  `DEX_ROUTER_HOME=$(mktemp -d)` plus fixture `CLAUDE_CONFIG_DIR`/`CODEX_HOME`.
  This warning is expected there; proceed.
- Real changes go through the CLI (`dx router …` =
  `node scripts/ccr/cli.cjs router …`), which holds the config lock, reads the
  live gateway from `state.backend()`, and keeps `config.native.enabled` in
  step with the installed client files.
- Hand-built `{ gateway }` or config objects must never reach
  `clientSettings`, `syncContext`, or `saveBackend`.
- If the live state is already inconsistent, follow the recovery steps in
  `docs/subscription-routing.md` § Failures and recovery, and snapshot every
  file before touching anything.
