# Optional subscription routing

Dex can keep several Anthropic and OpenAI subscription accounts available to
Claude Code and Codex sessions. It selects another account when a request hits a quota
limit, and can choose a different model for each lifecycle phase. Direct Claude
and Codex profiles remain available without CCR or its Node dependencies.

This integration is experimental. Local tests cover the real Claude Code CLI,
CCR and synthetic provider endpoints, including a provider change between two
turns in the same conversation. Real subscription login, refresh, quota and
model entitlement must also be checked against the accounts you intend to use.
Subscription endpoints and provider eligibility can change independently of Dex.

## Provisioned development hosts

Keep a host's routing policy in its infrastructure repository as well as its
live configuration. Include every phase's model, ordered fallbacks and effort,
native client routes, and the required model catalogue entries. Machine paths,
credentials and temporary session overrides stay outside Git. Reprovisioning
must preserve account state and deliberate local policy changes.

After a Dex update, verify the host installer and native-client hooks still
match the new behavior. Source updates do not replace router code already
loaded into memory. When a router restart is required, finish routed sessions
first, then run:

```sh
dx reload && dx router restart && dx router status && dx route policy
```

Policy changes and temporary session overrides are separate from source
updates. Inspect the affected session's route, remove temporary overrides once
the replacement is verified, and check the effective route again. Use the
infrastructure repository's parity and commissioning checks for generated
configuration, copied runtimes and service activation. Do not copy OAuth tokens
between active machines.

## First setup

Install Node.js 22 or newer and the official Claude Code CLI. OpenAI account
registration also needs the official Codex CLI as a login helper. Codex is not
used as the engineering runtime for Dex's `ccr-subscription` profile; native
Codex connects separately through the native setup below.
OpenAI model discovery reads the installed Codex version because the subscription
backend filters its catalogue by client version. Keep the CLI current when
refreshing the model list.

```sh
dx setup --router
```

The wizard installs a private, pinned CCR runtime, offers Anthropic or OpenAI,
asks for a friendly account name and starts the provider's native login. It
shows the identity returned by that login before registering it. Existing
Claude Code, Codex and standalone CCR configurations stay separate.

Choose a default model after discovery. Initially it serves all seven phases.
Setup and `dx router enable` select `ccr-subscription` as your global Dex profile. Existing repository
defaults still take precedence; where needed, select this profile there too:

```sh
dx provider use --repo ccr-subscription
```

`dx setup` remembers your direct/routed choice. `dx setup --direct` returns a
CCR global default to direct Claude; an existing direct Codex default is kept.
`dx router setup` also enables routing and selects the global CCR default.

## Keep native CLI access independent

Router setup routes Dex sessions through the `ccr-subscription` profile. Plain
`claude` and `codex` commands keep their own settings and subscription logins.
Keep this separation so you can use either CLI when the router is unavailable.

If you previously enabled global native routing, restore independent launches:

```sh
dx router native disable
claude auth status
codex login status
```

Start new CLI sessions from a terminal outside a routed agent. A shell opened
by a routed agent inherits that agent's routing environment. Disabling native
routing restores the settings Dex still owns, preserves your later edits, and
leaves Dex's account pool and routed workflows available. It works even when
the gateway is stopped. `dx install`, `dx init`, and `dx sync` keep it disabled.

Native Claude uses the account selected by `claude auth login`; native Codex
uses the account selected by `codex login`. Adding an account with
`dx account add` only changes Dex's account pool.

### Model selection and provider selection

The native `/model` menus select a model on the session's current connection.
They do not switch the endpoint or authentication between a native subscription
and CCR. A model labeled Claude or GPT in a routed session still uses CCR.
Switching to a genuinely independent connection requires a new launch.

For native operation, start `claude` or `codex` from your terminal with native
routing disabled. Their normal model menus remain available, subject to the
models your subscription supports. Router setup or `dx router enable` selects
the single `ccr-subscription` Dex profile, so an ordinary Dex session uses CCR:

```sh
dx --session "Your task"
```

In a routed Claude session, the picker has one named **CCR subscription** entry
for the automatic route, plus the models configured in that route, labeled
**via CCR**. Claude's own **Default** row can also appear. This lineup requires
Claude Code 2.1.242 or newer. Dex supplies it through temporary launch settings;
an explicit `--settings` picker takes precedence. Press `s` in Claude's picker
to select a model for this session only, so it does not become your saved native
default.

`dx route policy` shows both clients' effective CCR routes. A client without
its own override is labeled **inherited from setup**. These are routing
policies for clients connected to CCR, not their independent native settings.

To disable new Dex routed sessions and restore global native CLI settings, run
`dx router disable`, then start `claude` or `codex` in a new terminal tab.
To restore only the CLI settings while keeping Dex routing enabled, use
`dx router native disable`. `dx router enable` starts CCR and selects it as the
global Dex default again, without enabling global CLI routing.
An existing routed session keeps its current connection; these commands do not
convert it to a native session. `dx router stop` stops the gateway once routed
sessions have finished.

## Optional global routing for native commands

To explicitly route plain CLI commands through Dex as well:

```sh
dx router native enable
claude
codex
```

Both clients request `dex/active`, which follows Dex's configured default route
and fallbacks. A standalone conversation uses the setup phase's route. Eligible
accounts for each model are tried before the next fallback model. This includes
Codex running a Claude model through CCR's Responses-to-Messages conversion.
`--model` and native model selectors can choose a configured model explicitly;
that request uses the chosen model's account pool.

Codex reads its model catalogue from the gateway. Dex answers with a `dex/active`
entry that mirrors the metadata of the first OpenAI model on the route, read
from the same ChatGPT catalogue that `dx model discover` uses, so Codex keeps
its `apply_patch` tool, skills instructions and reasoning levels. A route with
no OpenAI model gets GPT-5 family defaults. Codex still warns about missing
model metadata when the gateway is unreachable at startup.

These are ordinary native sessions with their existing conversation history,
permissions and CLI options. They do not start a Dex lifecycle. Authentication
helpers start CCR when needed and obtain a local capability tied to the client
process. Provider credentials remain in Dex's account store. `dx accounts --live`
shows the same pool used by these sessions and Dex workflows.

A Dex lifecycle launched while native routing is enabled hands its own session
capability to the same Claude helper instead of setting `ANTHROPIC_AUTH_TOKEN`,
so Claude does not warn about two authentication sources. Inside a routed
session, `/clear`, `/resume` or a fork moves that session to the new
conversation; the routing journal records `route.conversation_changed` and the
route, override and account pin carry over.

Setup requires Python 3.11+ and native clients that support command-based gateway
authentication, including the Codex `model_providers.<id>.auth` configuration.
It updates Claude's user settings and adds a managed `dex-ccr` provider to
Codex's user configuration. Unrelated settings are retained; `dx install`, `dx init` and
`dx sync` refresh the native configuration after you have enabled it. Explicit
client flags, another Codex profile, or higher-priority settings may override
these defaults. The client's `/model` picker can select any model from
`dx model list`, including one with a smaller context window than the route it
started on; see the context budget notes below.

```sh
dx router native status
dx router native disable
```

Disabling restores the previous values for settings Dex still owns and keeps
subsequent user edits. Start a new CLI session to use the restored defaults.
Native routing keeps the local gateway address stable across router restarts.

## Account errors and recovery

If Anthropic asks you to accept updated Consumer Terms and Privacy Policy,
sign in to `claude.ai` with that account and accept the prompt. Check its
identity with `claude auth status` for a native session or
`dx account show <name>` for a routed account. A successful login and unused
quota do not mean that terms have been accepted.

Dex recognizes this account-specific rejection, tries the next eligible
account, and shows `accept terms in claude.ai` in `dx accounts`. It waits one
minute before trying the affected account again, so accepting the terms needs
no router restart or reauthentication. Other HTTP 400 request errors still
stop the request rather than retrying it across accounts.

A 429 can mean the selected subscription has exhausted its weekly quota.
`dx accounts` shows the quota and reset time. A newly added Anthropic account
cannot replenish an OpenAI subscription or join a route containing only OpenAI
models. Native CLIs use their own logged-in accounts, whose quota may differ
from the accounts registered with Dex.

## Open the CCR dashboard

```sh
dx router ui
```

This starts the bundled CCR package and opens its browser dashboard. The command
currently requires idle routed sessions. Use the UI for diagnostics and Dex
commands for accounts and routing; Dex reapplies its managed CCR configuration
at startup.

## Add more accounts

Use `dx account add` for each additional subscription login. You can keep
multiple Anthropic accounts, multiple OpenAI accounts, or a mix. Rerunning
setup skips account registration once an account exists.

```sh
dx account add anthropic --name backup
dx account add openai --name chatgpt
dx accounts
```

Run `dx account add` with no arguments to choose the provider and name
interactively. Names such as `backup` and `chatgpt` identify accounts in the
CCR pool. The `ccr-subscription` profile selects that pool when launching Dex.
`dx provider list` shows profiles and their defaults, with `*` beside the
current selection; `dx accounts` shows the registered logins and quota.
Repository defaults take precedence over the global default, so use
`dx provider current` in the repository where you intend to run a task.

Each login gets an isolated temporary native configuration. If the browser
selects an already registered account, Dex names that duplicate and keeps the
existing entry. Select the other identity in the provider's browser flow and
retry. OpenAI also supports `--device` for native device authentication.

The confirmed renewable credential moves to macOS Keychain on macOS or an
owner-only file on Linux. Dex removes its temporary native login. There are no
upstream API-key fields. `--yes` skips the identity confirmation for scripted
registration; the provider's login still requires the account owner.
For `--json` registration, supply the provider, `--name` and `--yes`. Native
login and installation progress go to stderr, leaving stdout for the JSON
result. Run the setup wizard interactively without `--json`.

## Accounts and quota

In the examples below, replace `main` and `backup` with names from `dx accounts`.

```sh
dx accounts --live
dx accounts --json
dx account show main
dx account rename backup spare
dx account rank main 1
dx account disable spare
dx account enable spare
dx account reauth main
dx account doctor main
dx account remove spare
```

The account table shows one row per account and configured model, so primary
and fallback availability can be compared. An account with no model in the
configured routes has a dash in the Model column. Models currently in cooldown
also appear while they remain in the catalogue. Shared quota readings repeat
across model rows; they are one allowance. Model-specific windows appear only
on matching rows.

The 5-hour and weekly quota appear side by side. Each window has a percentage
left and a `Reset in` countdown, such as
`4h 51m` or `3d 12h`. Additional windows, including model-specific quotas, get
their own column pairs. A dash means that window was not reported; accounts
with no readings show `unknown`, and old readings remain labelled `stale`.
With CCR running, the dashboard refreshes usage; the extension also polls every
minute. The Claude status line reads the cache without a network request.

Use `dx accounts --live` (or `--watch`) to refresh every 30 seconds. The live
view replaces the table on the same screen and restores your terminal when
you press Ctrl+C. If the table exceeds the screen height, use `dx accounts`
to see all rows. The live view shows when it updated and identifies cached readings
when CCR is stopped or a refresh fails. Start CCR with `dx router start` to
resume provider refreshes. Live mode requires a terminal; use `--json` by itself
for a single machine-readable snapshot. The normal table includes a reminder
of the live option.

Model lists, phase policies, provider profiles and lifecycle session lists use
the same table layout. Columns wrap to fit the terminal; very narrow terminals
show labelled fields. Piped text keeps full column widths. Commands that support
`--json` continue to return their structured data without table formatting.

Disabling excludes an account from new selections. Removing it also deletes its
stored credential after confirmation (`--yes` in a script). An already
authorised request may finish. Reauthentication must return the same identity;
a different identity requires a new entry.

Account ranks are optional. Lower numbers are tried first for each model, ahead
of session affinity and reported quota headroom. `dx account rank main 1` moves
an account to that position and renumbers the rest of the pool. `dx accounts`
lists ranked accounts first in rank order, then unranked accounts in the order
they were registered; `--json` uses the same order. Once a ranked
account's quota or cooldown clears, the next request tries it before accounts
with lower priority. If no ranks are set, Dex keeps the default affinity and
quota-aware selection policy.

## Models and phase policy

```sh
dx model list
dx model discover main
dx route configure anthropic/<model-id>
dx route configure openai/<model-id> --phase implement --effort high \
  --fallback anthropic/<model-id>
dx route configure openai/<model-id> --client codex \
  --fallback openai/<fallback-model-id>
dx route configure anthropic/<model-id> --phase review
dx route policy
```

Replace the placeholders with IDs from `dx model list`. Phase names are
`setup`, `plan`, `implement`, `review`, `verify`, `pr` and `complete` (0–6).
A configuration without `--phase` resets all seven phases. Repeat `--fallback`
to extend the ordered model chain. Cross-provider fallback requires an explicit
chain; it is not enabled by merely registering an OpenAI account.

Use `--client claude` or `--client codex` to give a native client its own route
without changing lifecycle phases or the other client. `--client` and `--phase`
are mutually exclusive. When the model in the native client's settings matches
the primary model in its client route, Dex retains the configured fallbacks. A
different model selected with `/model` remains a strict one-model override.

For example, if both models appear in your account's catalogue, keep Fable 5.1
as the primary model and use Opus 5 when its accounts are unavailable:

```sh
dx route configure anthropic/claude-fable-5-1 --fallback anthropic/claude-opus-5
```

This applies to all seven phases and native Claude/Codex sessions using
`dex/active`, unless that client has its own route. Dex tries the accounts that
can serve Fable before trying Opus. A one-model override or account pin
restricts this automatic fallback.

### Review-wave model diversity

Consecutive review waves on the same route lead with different models. The
route's model list is rotated by the wave index — wave 1 leads with the first
fallback, wave 2 with the next, wrapping — so two or three consecutive clean
passes on a `normal` or `complex` route come from genuinely different reviewers
instead of the same model agreeing with itself. Quality rises through that
diversity rather than through a higher clean-pass count.

The rotation is a function of the wave index alone: it is deterministic,
resumes to the same order, and needs no new gate numbers. The fallback chain
within a wave keeps its order, so a provider failure still degrades in order.
A route with one model cannot be diverse, and does not break. The wave's own
process never chooses a model — its reviewer stays independent of the route —
and each wave's selected model is recorded in `route.selected` telemetry.

### Model profiles

A model profile names the role a model plays rather than the model itself:

```sh
dx profile set cheap openrouter/glm-5.3
dx profile set strong anthropic/claude-fable-5-1
dx route configure @cheap --phase implement
```

`@<profile>` resolves to the model currently assigned to that profile. Change
what `cheap` means once and every route that names `@cheap` follows; the
resolved model is recorded in each request's telemetry, so an experiment
compares models, not just labels. Phases, client routes and `--fallback` all
accept a profile. `dx profile list` shows each profile's model.

After Phase 6 records its terminal commit, the lifecycle marks the session
complete (phase 7). The conversation keeps the `complete` route for its final
summary and any follow-up. Review-wave passes and assessments launched by a
lifecycle run under their own session IDs but follow that lifecycle's phase.

If discovery is unavailable, register a model supported by your subscription:

```sh
dx model add openai/<model-id> --context 128000 --tools --images
```

Only include `--images` when supported. Discovery records the provider's default
and maximum context windows separately; otherwise it labels a conservative 64,000-token budget.

### Deferred tool loading

Claude Code can leave most tool schemas out of a request and fetch them on
demand, but only over a base URL it recognises as first-party. A routed launch
never is, so the client suppresses the optimisation and inlines every schema
into every request instead. Measured on this repository, that was 110,777 bytes
of tool schemas in a request of 67,988 tokens — 59% of a fresh session before
any work had been done.

Dex therefore sets `ENABLE_TOOL_SEARCH=true` for routed launches and native
settings. The same prompt then opened at 37,612 tokens: 30,376 fewer, a 45%
reduction, with 12 tools inlined instead of 83. Schemas arrive through the
ordinary `tools` array when the model asks for them — after one `ToolSearch`
call the array grew to 17 tools — so nothing depends on a provider
understanding Anthropic's own deferred-tool blocks, and every route keeps the
tools it had. Set the variable yourself to change or disable this; a routed
launch does not overwrite a value you exported, and `auto` or `auto:N` select
the client's threshold modes.

A `tool_reference` block pins a deferred definition and only Anthropic reads
it. Other providers have the schema already, from the tools array, so the block
is dropped on the way out rather than failing the request; the tool call it
accompanies is untouched. Content that genuinely cannot survive conversion —
`document`, `web_search_tool_result` — is still refused rather than silently
altered.

### Metered API-key providers

Anthropic and OpenAI accounts are subscriptions: a renewable OAuth login owned
by a native client, billed by your plan. OpenRouter is the other kind — a
metered provider billed per token, authenticated with an API key rather than a
login. Dex branches on that kind, not on the provider's name, so the two behave
differently only where they genuinely differ.

```sh
export DEX_OPENROUTER_API_KEY=sk-or-v1-...
dx account add openrouter --name openrouter
```

The key is read from that variable or typed at the prompt, and goes straight to
the OS credential store. There is deliberately no `--api-key` flag: a value in
argv is world-readable in `ps`. Only a truncated label identifying the key is
recorded alongside the account. A key does not expire and has nothing to
refresh, so `dx account reauth` replaces it rather than renewing it.

Metered catalogues are not discovered. Importing thousands of per-token models
would make an expensive one routable without anyone choosing it, so each model
is added explicitly:

```sh
dx model add openrouter/glm-5.3 --context 1048576 --max-context 1310720 \
  --tools --upstream z-ai/glm-5.3
```

`--upstream` is what the provider calls the model. An aggregator's own IDs carry
a vendor segment, so the Dex ID stays stable and short while the upstream ID is
recorded separately and used on the wire. Routes, phases and `dx route use`
always name the Dex ID.

A metered provider speaks chat completions, which no client speaks natively, so
its traffic always goes through conversion and cools down separately from native
traffic on the same account and model. Conversion drops the client's own
reasoning dialect, so Dex translates the configured effort into the wire
format's own field; `xhigh` and `max` clamp to its highest level rather than
being dropped.

Spend caps use the same path as subscription quota. A key with a limit reports
its remaining credit as a quota window, so a spent key is excluded from
selection and the route either falls back or stops with an explicit error. A key
with no limit reports no window, because there is no cap to exhaust — set a
limit on the key itself if you want Dex to stop at one.

Account rank orders accounts within a provider. Which provider is tried first is
the order of models on the route, so a metered model only serves traffic when a
route names it.
You can replace that budget with an explicit supported value. When account
discovery succeeds, selection uses that account's returned model list.

The Codex subscription catalogue can advertise a 272,000-token default and an
872,000-token maximum for the same model. The default is not its capacity limit,
and public API specifications can differ from the subscription endpoint.
Dex uses advertised maxima when available, capped at an 800,000-token operating
budget by default. Legacy entries keep their recorded limit until refreshed.
An explicit budget must fit every model on the configured routes; adding a
smaller fallback is rejected rather than silently shrinking it.

```sh
dx context refresh                 # Refresh existing models' metadata; no gateway restart
dx context budget 800000           # Validate and save the common operating budget
dx context doctor --session <id>   # Inspect launch budgets and compaction evidence
dx context doctor --session <id> --json
```

Refresh preserves manual model limits and does not add models or modify account
eligibility. `dx model list` shows both defaults and maxima. Metadata remains
available from an authenticated OpenAI account even when inference quota is
exhausted. `dx context doctor` can inspect stopped sessions and reports compact
before/after counts, the first subsequent real input count, tool/schema size,
and restored skill/instruction size without printing prompt or credential text.
Use `--transcript <jsonl>` to inspect an explicitly selected owned transcript.

Dex states the route's budget to each client and leaves the compaction
schedule to the client itself. Claude receives the budget in tokens as
`CLAUDE_CODE_AUTO_COMPACT_WINDOW` and decides when to compact within it; Codex's
auto-compaction limit is set to 80% of that budget, leaving room for tool output
and the compaction request itself. Earlier personal thresholds are retained.
Route configuration and model catalogue changes refresh the installed context
settings while preserving model choices and any earlier personal compaction
threshold. A personal threshold above the new budget must be lowered before the
route change can be saved.

Claude resolves a model's context window locally, before any request. A routed
launch points at the local gateway, so it is never first-party: a model name the
client already recognises resolves to that model's believed 200,000-token
window, and `CLAUDE_CODE_MAX_CONTEXT_TOKENS` is ignored for it. Only the
unrecognised `dex/active` id honours that variable. Dex therefore appends the
client's own `[1m]` long-context marker to every Claude-side model id it
installs — `dex/active`, the default Opus, Sonnet, Haiku and subagent models, and
each entry in the Dex model picker — which asks for the 1M window regardless of
how the name resolves. The marker is stripped again before the gateway routes
the request, so it never reaches the model catalogue. A `/model` choice you made
from the Dex picker is re-marked in place on the next route or catalogue change
rather than replaced; a model Dex does not offer is left alone.

Dex no longer sets `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`. It was pinned only because
a routed model resolved to a 200,000-token window and compacted at 160,000; with
the window stated directly, the percentage is yours again. Installations that
carry the old override have it removed on the next route or catalogue change,
unless you changed the value afterwards, in which case it stays.

`context-1m-2025-08-07` is still added to `ANTHROPIC_BETAS`, because Anthropic
gates 1M input on it upstream. That governs the provider request, not the
client's local window arithmetic. Betas you export yourself are preserved
alongside it, models without long-context support ignore it, and the gateway
forwards it only on Anthropic requests. Installations predating this field adopt
it on the next route or catalogue change; a value you set by hand afterwards
stays yours.

Already-running clients retain their loaded settings; restart and resume the
conversation to load updated limits. The `dex/active` model catalogue also
bounds its advertised window and compaction threshold to the current route.
Session-specific `dx route use` and the client's `/model` picker can select a
smaller model without changing global client settings. Compact before switching
if the conversation is already too large for it.

Providers determine whether input fits their token limit. Dex preserves the
OpenAI `context_length_exceeded` error code and Claude’s `prompt is too long`
signal so native recovery can run. It limits HTTP requests to 32 MiB;
it does not infer token counts from JSON size. For an ordinary full window,
submit `/compact` on its own and wait for it to finish. If compaction thrashes,
use `dx context doctor` instead of repeating it: a large fixed tool/instruction
load can refill the window immediately. Correct the budget and loaded tools,
then resume the existing conversation in a new client. A larger upstream model
does not expand an already-running client's launch budget automatically.

The lifecycle Stop hook recognizes Claude's compaction-thrashing error and uses
the normal pause path. It preserves the phase and worktree, revokes completion
authorization, and prints the context diagnostic command instead of injecting
another audit. Human controls still take precedence. It does not clear history
or mark a phase complete.

Request events under `~/.dex/router/events.jsonl` include a correlation ID,
actual model/account, launch and advertised context limits, request/tool-schema
sizes, quota-reading age, response token counts and duration. A byte-preserving
bounded stream observer records usage without logging prompts, schemas or model
answers. Responses carry `x-dex-request-id`; provider request IDs are included
when exposed by the gateway. `dx router doctor` reports telemetry write failures.

## Scoped tools for routed sessions

Choose the existing MCP servers a Dex-launched Claude session needs:

```sh
dx context scope --include linear --include linear-server --include github \
  --include playwright --include codegraph --include openaiDeveloperDocs \
  --include devserver-db
dx context scope off
```

This opt-in policy builds a private, launch-scoped MCP configuration from user,
project and local registrations. It loads only named servers, prefers `linear`
over a duplicate `linear-server`, and disables additional account connectors for
that launch. It retains the original registrations. Explicit `--mcp-config` or
`--strict-mcp-config` arguments take precedence. Use `--builtin-tools` with a
comma-separated list to bound the built-in tool set too; an explicit `--tools`
argument takes precedence. The launch record contains server names and missing
environment-variable names, never credentials or server configuration bodies.

Native sessions outside Dex keep their own MCP configuration. A provisioned host
can register one worktree-aware database MCP instead of exposing every VM's
database to every client. Keep that adapter and its registration in the host's
infrastructure repository.

Frequently restored lifecycle skills use short entrypoints that load their
complete workflows from `prompts/workflows/`. The full contracts are retained;
only the active workflow needs to be re-read after compaction. This avoids
re-injecting every completed phase's full instructions indefinitely.

## Switching in one session

With `ccr-subscription` selected, choose session only or the full workflow
when running `dx "a prompt"`. Use `dx --session "a prompt"` for a plain
conversation through the account pool, or `dx --workflow "a task"` for the
full lifecycle. Ticket IDs continue to start their workflows directly.

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
invoke a model-selection agent. Model overrides inherit the configured phase or
native client's effort setting.

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
After a fallback succeeds, Dex keeps using it for that session and phase,
including after resume. It tries the remaining route again if that model becomes
unavailable. A phase or policy change, or `dx route use auto`, resets this
preference and tries the configured primary first. Explicit model overrides and
account pins remain strict.
Explicit account ranks take priority. Without ranks, Dex prefers the current
account and then fresh quota headroom. It excludes disabled identities, expired
logins, exhausted windows and accounts in cooldown. Rate limits
and temporary provider errors cool only the requested model on that account,
including when the provider does not identify the limit's scope. Other configured
fallback models can still be tried. Connection and login failures affect the
whole account. A fresh exhausted quota window shared by all models excludes the
whole account; a model-specific window excludes only matching models.

A metered provider adds two refusals of its own. `402 Payment Required` means
the account is out of credit and can serve nothing until it is topped up, so it
cools the whole account for 30 minutes and the request falls through to the next
model on the route. `403 Forbidden` is about permission for that model on that
account — a provider guardrail, a key scope — so it cools only that model for
5 minutes and another model on the same key is still tried. Neither is returned
to the client as the provider's own status: a client reading a bare 403 from its
API takes it for an authentication failure and tells you to log in again. When
nothing on the route can serve the request, Dex answers with
`subscription_accounts_unavailable` and says which account is out of credit and
what to do about it. A request the provider rejects on its own terms — malformed,
unsupported, too long — is still returned as-is, because no other model would
serve it either.

A request that CCR converts between wire formats (Codex Responses to a Claude
model, or Claude Messages to an OpenAI model) cools down separately from native
traffic. A converted Codex request that is rejected does not block a Claude
Code session using the same account and model; the account table lists such
cooldowns with the protocol, for example `claude-opus-5@responses`. When every
model on a route needs conversion, the error says so and names the
`dx route configure` command that adds a native model. Failover events in the
routing journal keep a short excerpt of the provider's own error.

When no route is available, the error names each model and account with its
reason: rate limit, temporary provider error, exhausted quota, disabled account,
missing model access or a login needing renewal. It includes the earliest known
retry time and sends a matching HTTP `Retry-After` header. Unknown quota reset
times and login failures do not get an invented countdown. Reauthentication is
suggested only for a login failure. The account table also names models in
cooldown and shows short waits in seconds.

When quota or rate limits block every otherwise eligible account, Dex returns
HTTP 429 with a `rate_limit_error`, so Claude Code does not append its generic
temporary-server-error advice. The message shows a readable wait, such as `2d`,
while `Retry-After` retains the exact number of seconds. It also names registered
providers missing from the route's fallback chain. Temporary provider and
connection failures still return HTTP 503.

An authentication rejection permits one refresh before account failover.
Rate limits and temporary server errors can fail over before response delivery.
Bad or forbidden requests do not rotate accounts. Unsupported cross-provider
content, such as document or tool-reference blocks, is rejected rather than
silently discarded.

When a Claude conversation falls back to OpenAI, Dex preserves plaintext
thinking as reasoning summaries and removes CCR's generated reasoning item IDs.
This lets existing conversations continue through the stateless Responses
endpoint. In either client's wire format, signed or encrypted reasoning stays
in the saved conversation and is sent only to its original provider. Requests
to the other provider retain readable reasoning, messages, and tool calls and
results. Switching back restores the original provider's reasoning blocks.
Configured effort is applied in the client's request format before CCR converts
it for the selected provider.

Request rejections identify the model, HTTP status, and any provider error code
and field path. Dex records those fields in `router.request_rejected` events;
provider messages and request bodies are excluded from those diagnostics.
The status line shows the rejected model after a failure. Successful route
information is labelled `last:` because it describes the last accepted request.

Once delivery starts, Dex never replays that response on another account. A
broken stream may require user continuation. A retry before delivery also
cannot prove that the upstream provider did no work; it is not an exactly-once
guarantee for remote execution.

The launcher attempts CCR recovery twice after repeated health failures, keeping
the endpoint, session capability and saved route. If Claude exits, ordinary Dex
conversation resumption remains available. Routing failures do not write phase
completion markers.

Routine health checks avoid scanning every session's process identity. Before
recovery, the launcher confirms the failure with a longer timeout. Recovery
attempts and outcomes go to the routing journal; they do not write over Claude's
input area. If recovery remains unsuccessful when Claude exits, Dex prints a
warning after the client has released the terminal. Launchers already running
when Dex is updated keep their previous watchdog until that session exits.

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
DEX_CCR_NATIVE_CLIENTS=1 DEX_CCR_INTEGRATION_RUNTIME=scripts/ccr/runtime-package \
  node --test tests/ccr-runtime.test.cjs
bash tests/check.sh
```

The native smokes use installed official CLIs, isolated configuration,
synthetic credentials and local providers. They check two providers in one real
Claude conversation, native Codex routing, account failover, recovery and journal redaction. They do
not log into subscriptions or consume their allowance. CI has a separate CCR
contract job on Linux and macOS; ordinary Dex tests do not install CCR.

Before relying on a real pool, verify native login, token refresh, discovered
models, quota readings and a tool-using request for each provider. Subscription
rules and permission to use third-party clients remain separate from technical
compatibility. OAuth is not a general-purpose provider API entitlement.

Browser proof: N/A. No CCR browser UI components are changed. Terminal and
protocol flows have isolated integration coverage.

See the [implementation evidence](plans/subscription-routing-acceptance.md)
for the verified scope and the remaining live-subscription checks.
