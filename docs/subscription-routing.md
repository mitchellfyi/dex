# Optional subscription routing

Dex can keep several Anthropic and OpenAI subscription accounts available to
one Claude Code session. It selects another account when a request hits a quota
limit, and can choose a different model for each lifecycle phase. Direct Claude
and Codex profiles remain available without CCR or its Node dependencies.

This integration is experimental. Local tests cover the real Claude Code CLI,
CCR and synthetic provider endpoints, including a provider change between two
turns in the same conversation. Real subscription login, refresh, quota and
model entitlement must also be checked against the accounts you intend to use.
Subscription endpoints and provider eligibility can change independently of Dex.

## First setup

Install Node.js 22 or newer and the official Claude Code CLI. OpenAI account
registration also needs the official Codex CLI as a login helper. Codex is not
used as the engineering runtime for this profile.

```sh
dx setup --router
```

The wizard installs a private, pinned CCR runtime, offers Anthropic or OpenAI,
asks for a friendly account name and starts the provider's native login. It
shows the identity returned by that login before registering it. Existing
Claude Code, Codex and standalone CCR configurations stay separate.

Choose a default model after discovery. Initially it serves all seven phases.
Setup selects `ccr-subscription` as your global Dex profile. Existing repository
defaults still take precedence; where needed, select this profile there too:

```sh
dx provider use --repo ccr-subscription
```

`dx setup` remembers your direct/routed choice. `dx setup --direct` returns a
CCR global default to direct Claude; an existing direct Codex default is kept.
Use `dx router setup` to configure routing without changing your default profile.

```sh
dx account add anthropic --name main
dx account add anthropic --name backup
dx account add openai --name chatgpt
dx accounts
```

Each login gets an isolated temporary native configuration. If the browser
selects an already registered account, Dex names that duplicate and keeps the
existing entry. Select the other identity in the provider's browser flow and
retry. OpenAI also supports `--device` for native device authentication.

The confirmed renewable credential moves to macOS Keychain on macOS or an
owner-only file on Linux. Dex removes its temporary native login. There are no
upstream API-key fields. `--yes` skips the identity confirmation for scripted
registration; the provider's login still requires the account owner.

## Accounts and quota

```sh
dx accounts --watch
dx accounts --json
dx account show main
dx account rename backup spare
dx account disable spare
dx account enable spare
dx account reauth main
dx account doctor main
dx account remove spare
```

The dashboard shows account state, provider-reported quota windows and reset
times. Missing readings remain unknown and old readings remain labelled stale.
With CCR running, the dashboard refreshes usage; the extension also polls every
minute. The Claude status line reads the cache without a network request.

Disabling excludes an account from new selections. Removing it also deletes its
stored credential after confirmation (`--yes` in a script). An already
authorised request may finish. Reauthentication must return the same identity;
a different identity requires a new entry.

## Models and phase policy

```sh
dx model list
dx model discover main
dx route configure anthropic/<model-id>
dx route configure openai/<model-id> --phase implement --effort high \
  --fallback anthropic/<model-id>
dx route configure anthropic/<model-id> --phase review
dx route policy
```

Replace the placeholders with IDs from `dx model list`. Phase names are
`setup`, `plan`, `implement`, `review`, `verify`, `pr` and `complete` (0–6).
A configuration without `--phase` resets all seven phases. Repeat `--fallback`
to extend the ordered model chain. Cross-provider fallback requires an explicit
chain; it is not enabled by merely registering an OpenAI account.

If discovery is unavailable, register a model supported by your subscription:

```sh
dx model add openai/<model-id> --context 128000 --tools --images
```

Only include `--images` when supported. Discovery records the provider's context
window when available; otherwise it labels a conservative 64,000-token budget.
You can replace that budget with an explicit supported value. When account
discovery succeeds, selection uses that account's returned model list.

The launcher gives Claude the smallest context budget in the configured phase
and fallback routes. A smaller model cannot be introduced into a running
conversation; configure it before starting a new session. Payload-size checks
are not tokenizers. Providers remain authoritative about token limits.

## Switching in one session

Continue launching Dex tasks normally with `ccr-subscription` selected.

```sh
dx route status
dx route use openai/<model-id> --session <session-id>
dx route use anthropic/<model-id> --scope phase --session <session-id>
dx route use auto --session <session-id>
dx route pin-account main --session <session-id>
dx route unpin-account --session <session-id>
```

Inside the routed agent, `/dxroute`, `/dxmodel` and `/dxaccount` use its current
session. Outside it, `--session` is required when several sessions are active.
Overrides last for the session by default; a phase override expires when the
lifecycle advances. `auto` restores the configured phase policy. It does not
invoke a model-selection agent.

Changes apply to the next request, including the next tool-loop request. They
cannot replace an answer already streaming. Native subagents inherit the
parent's route; separate Dex review/delegation processes get separate routing
session IDs. Model changes do not alter phase gates or review receipts.

A pin is strict: an unavailable pinned account pauses requests instead of
selecting another account. If every route is exhausted, use terminal commands
to inspect accounts or change the route. A slash skill may itself need an
available model to execute.

## Failures and recovery

For each model, Dex tries eligible accounts before moving to the next model.
It prefers the current account, then fresh quota headroom. It excludes disabled
identities, expired logins, exhausted windows and accounts in cooldown. A
model-specific quota error cools that model only.

An authentication rejection permits one refresh before account failover.
Rate limits and temporary server errors can fail over before response delivery.
Bad or forbidden requests do not rotate accounts. Unsupported cross-provider
content, such as document or tool-reference blocks, is rejected rather than
silently discarded.

Once delivery starts, Dex never replays that response on another account. A
broken stream may require user continuation. A retry before delivery also
cannot prove that the upstream provider did no work; it is not an exactly-once
guarantee for remote execution.

The launcher attempts CCR recovery twice after repeated health failures, keeping
the endpoint, session capability and saved route. If Claude exits, ordinary Dex
conversation resumption remains available. Routing failures do not write phase
completion markers.

```sh
dx router status
dx router doctor
dx router start
dx router stop
dx router restart
dx router disable
```

Manual stop, restart, installation and catalogue changes require idle routed
sessions. Disabling affects new launches; active sessions can finish. Select
`claude-subscription` or `codex-subscription` through `dx provider use` to run
directly again.

## Dependency choice and upgrades

Dex uses the full
[musistudio/claude-code-router](https://github.com/musistudio/claude-code-router)
CLI with its wrapper/core plugin interfaces. The initial lock contains CCR
**3.1.0** and an exact override for **@the-next-ai/ai-gateway 1.0.21**. This is
a different project from other tools called “CC-Router”. Upstream CCR alone is
not Dex's subscription pool.

| Approach | Maintenance Dex would own | Decision |
|---|---|---|
| Full CCR plus extension | Account storage, refresh, session policy and a narrow adapter | Implemented |
| Fork CCR | Dex changes plus recurring CLI, gateway and UI merges | Avoided |
| Port selected CCR code | A gateway runtime, stream/tool conversion, patches and licence notices | Greater ownership than this feature warrants |
| Embed only the gateway package | Gateway lifecycle and missing management surfaces | Possible future adapter |

Dex owns account UX, independent identities, quota and deterministic selection.
CCR owns Anthropic/Responses protocol and stream conversion. Account selection
and phase changes do not rewrite CCR's global login or restart its core. CCR's
broader automatic routing is disabled to avoid a second fallback policy.

`dx router install` uses the checked-in lock in a versioned private directory.
It does not install globally or use an arbitrary `ccr` from `PATH`. CCR's SQLite
dependency may require a supported prebuilt binary or local build tools.
`dx router update` uses the tested release shipped with Dex, not upstream latest.

To upgrade, change the package pin, gateway override and adapter together;
regenerate/review the lock; run the real-runtime contract on Linux and macOS and
the native Claude smoke; check real OAuth separately. Activate the new version
only while sessions are idle. Keep the previous versioned runtime until the
upgrade is verified. This first release supports one version pair; reverting
to the prior Dex release is the rollback path. Do not change private runtime
dependency versions manually.

`dx router ui` opens CCR's existing dashboard for diagnostics while routed
sessions are idle. Browser authentication uses a short-lived local redirect
without printing the management token. Manage accounts and policy through Dex:
changes to its private CCR configuration are unsupported and may be replaced at
startup. The standalone `ccr` command continues using its own configuration.

## Storage and security

The machine directory is `~/.dex/router` (`DEX_ROUTER_HOME` can relocate it).
`config.json` stores policy, `accounts.json` stores metadata, and `sessions/`
stores routes and hashes of session capabilities. These are not repository
state and are not uploaded to DexCode.

Provider tokens stay in the credential store. Local transport credentials live
in its private `credentials/local-transport.json` and CCR's private database;
they cannot purchase provider API usage. Secrets are absent from native CLI
arguments and run telemetry. Claude's environment receives only its local
session capability.

Listeners bind to loopback. Extension control uses an owner-only Unix socket in
a short `/tmp` directory. Storage uses private permissions, atomic writes and
advisory locks. Process ownership uses Dex's existing stable process identities.
These controls separate local users; they do not protect against malicious code
already running as the same user.

CCR request-body capture is disabled and its raw console logs are discarded.
Dex records routing events locally and bridges run-associated events through
the existing journal writer, preserving sequence and locking. Events contain
opaque account IDs and model decisions, not identity labels, quota snapshots
or credentials. Existing run sync may carry those events. Personal usage sharing
requires a future explicit DexCode contract.

Artifacts use the existing local workspace and Dex artifact mechanisms. This
feature does not create, migrate or host Claude web artifacts. See the
[DexCode handoff](plans/dexcode-subscription-routing.md) for future web work.

## Verification

```sh
bash tests/ccr-routing-test.sh
npm ci --prefix scripts/ccr/runtime-package --no-audit --no-fund
DEX_CCR_INTEGRATION_RUNTIME=scripts/ccr/runtime-package bash tests/ccr-routing-test.sh
DEX_CCR_NATIVE_CLAUDE=1 DEX_CCR_INTEGRATION_RUNTIME=scripts/ccr/runtime-package \
  node --test tests/ccr-runtime.test.cjs
bash tests/check.sh
```

The last smoke uses an installed official Claude CLI, isolated configuration,
synthetic credentials and local providers. It checks two providers in one real
Claude conversation, account failover, recovery and journal redaction. It does
not log into subscriptions or consume their allowance. CI has a separate CCR
contract job on Linux and macOS; ordinary Dex tests do not install CCR.

Before relying on a real pool, verify native login, token refresh, discovered
models, quota readings and a tool-using request for each provider. Subscription
rules and permission to use third-party clients remain separate from technical
compatibility. OAuth is not a general-purpose provider API entitlement.

Browser proof: N/A. No CCR browser UI components are changed. Terminal and
protocol flows have isolated integration coverage.
