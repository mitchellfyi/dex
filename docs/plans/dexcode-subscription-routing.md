# DexCode subscription-routing handoff

Status: future web implementation. The Dex CLI integration is optional and must
remain usable without a DexCode account or connection.

The CLI owns provider authentication, credentials, account selection, and local
session control. DexCode must never receive provider credentials, refresh
tokens, local management tokens, or authentication links/device codes.

Version the account, quota, route, and event contracts alongside the CLI.
Account data belongs to the local machine's owner. Existing organisation worker
registration does not grant organisation-wide visibility into personal account
usage. Sharing requires an explicit owner choice and server-side access checks.

The future dashboard should show redacted account labels, quota windows and
freshness, effective routes, and routing events. Preserve unknown and stale
quota states. Remote controls require an authenticated, expiring, run-scoped
capability and an acknowledgement from the local owner process.

## Current local interfaces

Documents and the private protocol use `version: 1`. They are local interfaces,
not remotely exposed APIs.

| CLI/control | Relevant fields |
|---|---|
| `dx accounts --json` | `accounts[]`: opaque ID, name, provider, enabled/status, usage, usage_error, cooldown_until, model_cooldowns |
| `dx route status --json --session ID` | `session` plus `route`: phase, ordered models, effort and optional pinned account |
| `dx route policy --json` | Default model, catalogue and phase map (0–6) |
| `dx router status --json` | Enabled/installed state, pinned release, health and active sessions |
| Private Unix control | `{version:1, method, params}`; includes credential operations that must never be exposed remotely |

Usage has `observed_at` (Unix milliseconds), `source`, `confidence`, and
`windows[]`. Each window contains `name`, `remaining_ratio` (0–1), nullable
`resets_at` (Unix milliseconds) and optional `model_pool`. The current source is
`provider`; confidence is `provider-derived` or `unknown`. Readings older than
two minutes, or accompanied by `usage_error`, are stale. Do not combine unrelated
window percentages into a fictional total balance.

Local account exports also include the confirmed identity and a fingerprint
for duplicate detection. A future web adapter must project an explicit allowed
field set; forwarding the export wholesale is not acceptable. Prefer
owner-selected labels and opaque IDs over email addresses.

## Run events

The extension bridges run-associated events through `dx_event_emit`, which
owns sequence numbers and locking. Existing run synchronization can carry
these events without a separate router connection.

Current types are `route.session_started`, `route.changed`, `route.selected`,
`route.paused`, `account.failover`, `account.unavailable`, and
`router.request_failed`. Payloads use `router_session_id`, opaque account IDs,
model IDs, phase/scope and a bounded reason. They exclude identity labels,
provider response bodies, quota snapshots and credentials.

The web timeline can show route changes from these events. It must not infer
quota exhaustion from every temporary error or treat a response as evidence
that a lifecycle gate passed.

## Remote controls

Use an authenticated, expiring capability bound to a machine owner and one
running Dex session. The local owner process must acknowledge the applied
change. Do not expose CCR's management RPC or the local credential endpoint.

Map the narrow local actions: model override, restore phase policy, pin account
and unpin account. Overrides are phase- or session-scoped. Targets must be
explicit when several sessions are active. Changes apply at the next request;
an already streaming response keeps its original route.

The UI needs pending/applied/rejected states, model/account validation, context
budget errors, stale quota labels and revocation. Send users to their local
terminal for native OAuth login. Remote credential administration is outside
this contract.

## Artifacts and later scheduling

Artifacts remain local workspace/Dex artifacts. Hosting at dexcode.ai should
publish those files through the existing artifact boundary without depending
on a Claude account's remote artifact identity.

Phase routing is implemented locally. A classifier agent and automatic
capability scoring are deferred. If added, their output should rank eligible
routes under deterministic constraints while preserving user overrides, quota
availability and the current conversation's context budget.

See [subscription routing](../subscription-routing.md) for setup, dependency
maintenance and compatibility checks. Never upload the private router directory,
CCR databases or native login files as run artifacts.
