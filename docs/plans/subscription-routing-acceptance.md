# Subscription routing implementation evidence

Recorded on 2026-09-10 for `feat/optional-ccr-routing`.

The implementation uses full musistudio CCR 3.1.0 with ai-gateway 1.0.21 and a
Dex extension. It does not fork or copy CCR's protocol translator. Routing is
optional; direct Claude and Codex remain supported.

The table records implementation and local verification. Provider responses
and OAuth credentials in automated tests are synthetic. A `MET` result here
does not claim that a real subscription account accepted a request.

| # | Criterion | Implementation (`file:line`) | Test (`test:line`) | Status |
|---|---|---|---|---|
| 1 | Direct profiles and help work without starting CCR | `lib/provider.sh:787`, `lib/router.sh:4` | `tests/ccr-cli.test.cjs:138`, existing direct-provider suites | MET |
| 2 | Optional pinned full CCR runs with the Dex extension | `scripts/ccr/adapter.cjs:27`, `scripts/ccr/extension.cjs:6` | `tests/ccr-runtime.test.cjs:57`; fresh-install CLI smoke below | MET |
| 3 | Native subscription login is isolated; API keys are rejected | `scripts/ccr/onboarding.cjs:25`, `scripts/ccr/accounts.cjs:35` | `tests/ccr-cli.test.cjs:100`, `tests/ccr-cli.test.cjs:116`, `tests/ccr-accounts.test.cjs:19` | MET |
| 4 | Friendly accounts support registration, duplicate detection, reauthentication and removal | `scripts/ccr/onboarding.cjs:43`, `scripts/ccr/onboarding.cjs:84` | `tests/ccr-cli.test.cjs:39`, `tests/ccr-cli.test.cjs:105` | MET |
| 5 | Credentials persist privately; concurrent refresh preserves rotated tokens | `scripts/ccr/accounts.cjs:23`, `scripts/ccr/accounts.cjs:93` | `tests/ccr-accounts.test.cjs:10`, `tests/ccr-accounts.test.cjs:34`; synthetic Keychain smoke below | MET |
| 6 | Quota includes freshness and unknown states, with a cached status line | `scripts/ccr/accounts.cjs:73`, `scripts/ccr/cli.cjs:82`, `scripts/router-status.py:20` | `tests/ccr-accounts.test.cjs:29`, `tests/ccr-cli.test.cjs:147`, `tests/ccr-runtime.test.cjs:84` | MET |
| 7 | Discovery updates the catalogue and account eligibility | `scripts/ccr/cli.cjs:132`, `scripts/ccr/onboarding.cjs:114` | `tests/ccr-cli.test.cjs:49`, `tests/ccr-cli.test.cjs:54` | MET |
| 8 | Same-model account fallback preserves the running conversation | `scripts/ccr/service.cjs:165`, `scripts/ccr/policy.cjs:52` | `tests/ccr-runtime.test.cjs:63` | MET |
| 9 | Manual provider/model changes apply within the same native Claude process | `scripts/ccr/service.cjs:115`, `scripts/ccr/launch.cjs:38` | `tests/ccr-runtime.test.cjs:96` (two native turns; equal conversation IDs) | MET |
| 10 | Explicit cross-provider fallback preserves tool-call/result translation | `scripts/ccr/core-plugin.cjs:4`, `scripts/ccr/service.cjs:165` | `tests/ccr-runtime.test.cjs:72`, `tests/ccr-runtime.test.cjs:120` | MET |
| 11 | All seven phases, scoped overrides and concurrent sessions route independently | `scripts/ccr/policy.cjs:16`, `scripts/ccr/cli.cjs:152` | `tests/ccr-cli.test.cjs:27`, `tests/ccr-policy.test.cjs:13`, `tests/ccr-service.test.cjs:26`, `tests/ccr-service.test.cjs:34` | MET |
| 12 | Pinning is strict; smaller context and unsupported content are rejected | `scripts/ccr/policy.cjs:34`, `scripts/ccr/policy.cjs:87` | `tests/ccr-policy.test.cjs:20`, `tests/ccr-policy.test.cjs:33`, `tests/ccr-service.test.cjs:71` | MET |
| 13 | Failures preserve state and never replay a partially delivered answer | `scripts/ccr/service.cjs:226` | `tests/ccr-service.test.cjs:42`, `tests/ccr-service.test.cjs:52`, `tests/ccr-service.test.cjs:63` | MET |
| 14 | Recovery keeps the endpoint and route; the native resume handle is captured | `scripts/ccr/adapter.cjs:96`, `hooks/capture-provider-session.sh:33` | `tests/ccr-runtime.test.cjs:86`, `tests/ccr-service.test.cjs:79`, `tests/ccr-cli.test.cjs:129` | MET |
| 15 | Run events exclude secrets and use the existing journal writer | `scripts/ccr/service.cjs:24`, `bin/router-runtime.sh:14` | `tests/ccr-runtime.test.cjs:81`, `tests/ccr-runtime.test.cjs:92` | MET |
| 16 | Cleanup failures do not retain temporary native files; JSON output stays parseable | `scripts/ccr/onboarding.cjs:73`, `scripts/ccr/cli.cjs:200` | `tests/ccr-cli.test.cjs:62`, `tests/ccr-cli.test.cjs:68`, `tests/ccr-cli.test.cjs:75` | MET |
| 17 | Local artifacts remain usable through tool results across providers | `scripts/ccr/core-plugin.cjs:4`, `lib/provider.sh:1425` | `tests/ccr-runtime.test.cjs:72`, `tests/ccr-service.test.cjs:71` | MET |
| 18 | Fresh conversations reset reused Dex session state; resumptions retain it | `scripts/ccr/launch.cjs:21`, `scripts/ccr/service.cjs:79` | `tests/ccr-service.test.cjs:79`, `tests/ccr-service.test.cjs:86` | MET |

## Verification performed

- The complete CCR suite passed: **46 tests, zero failures or skips**, with
  `DEX_CCR_NATIVE_CLAUDE=1` and the installed pinned CCR runtime. This includes
  two turns in the actual Claude CLI, switching from the Anthropic fixture to
  the OpenAI fixture while retaining its conversation ID.
- Ten existing regression suites passed: provider commands, Codex launch,
  standalone providers, headless providers, CLI help, guards, push guards,
  status line, session-runtime wiring and session-runtime portability.
- The first manifest CCR run exposed an overlong macOS socket path. After
  moving the socket to a short private directory, that manifest test passed.
- A fresh private install smoke ran `router install --json`, model registration,
  configuration of all seven phases, real CCR startup, a deep health check and
  shutdown. Its runtime directory and process were removed afterward.
- A synthetic macOS Keychain entry was created, read and deleted successfully.
- Static checks passed, including shell, Python and Node checks.

Browser proof: N/A. No browser-rendered components changed. CCR's existing
dashboard is a diagnostic surface; terminal commands own the new account UX.

## Inventory and verification boundary

The full-change inventory found and fixed runtime repair, startup timeout,
refresh classification, account-connector activation, streaming-fixture,
missing-credential, model-eligibility, cleanup, JSON-output and reused-session issues. Each
behavioral fix has focused coverage; the real-runtime suite was rerun afterward.

The implementation remains experimental until checked with real subscriptions.
Live native OAuth login, provider refresh acceptance, model entitlements and
quota readings were **not verified**. No existing provider credentials were
read and no subscription allowance was used. The isolated test exercises the
actual runtime and transport; it cannot establish provider entitlement or
permission to use third-party clients.

Hosting artifacts, remote DexCode account controls and a classifier model are
outside this release. See the [DexCode handoff](dexcode-subscription-routing.md).

Suggested review risk: `complex`; reasons: `security-sensitive,public-contract,concurrency,shell-hooks-ci,cross-module`.

## Linux startup follow-up, 2026-09-11

The first main CI run exposed CCR's compatibility-mode port assumption: its
health check uses the gateway port plus one, even when a different core port
is configured. Linux allocated nonconsecutive ephemeral ports and startup
failed. Dex now reserves the adjacent gateway/core pair together and allocates
a separate management port. The real-runtime contract reproduced the failure
in a Node 22 Linux container and passed after this change. All 46 routing tests,
including the native Claude smoke, also passed again on macOS.

## Live machine verification, 2026-09-11

The owner completed separate native Claude and ChatGPT subscription logins.
Dex registered both globally with renewable credentials in macOS Keychain.
The original native CLI logins remain separate. Model discovery returned 11
Anthropic models and eight OpenAI models. The live check exposed an old Codex
client version in discovery: the backend returned only two models for that
version. Discovery now reads the installed CLI version; a regression test
covers version filtering and an unavailable or malformed version response.

Provider quota reported the Claude account's weekly allowance exhausted, so
the configured fallback selected OpenAI before making an Anthropic request.
Three real turns ran in one Claude Code conversation, using GPT-5.6 Luna and
GPT-5.6 Sol, and retained a marker across a model switch. This does not prove
a live Anthropic response or rotation between two Anthropic accounts.

A separate real GPT-6 Astra turn executed a Bash tool and created and read a
local text artifact through Claude Code. The artifact content matched the
expected marker. The temporary verification directory was removed. DexCode
run `run_20260911T132629Z_69357_039c0fa4` reached completed state on the live
site with `route.session_started` and `route.selected` in its timeline.

The global `ccr-subscription` profile resolves outside a repository and in the
DexCode.ai checkout. Explicit repository defaults still take precedence. The
live quota payload also showed that OpenAI's primary window can be weekly;
the dashboard now uses the returned window duration and labels current
account-wide exhaustion instead of showing the account as ready.

Main CI found missing account/model help entries, typo-confirmation command
names and the router module in the AGENTS table. Those entries were added;
the existing documentation and public-command checks pass locally.

Both providers accepted an explicit OAuth refresh through the Dex broker and
returned renewable credentials, which were saved back to Keychain. Automatic
refresh at expiry remains covered by the synthetic tests. Two-account
Anthropic rotation is still unverified against live subscriptions.

After these fixes, all 49 routing tests passed with the pinned runtime and
native Claude smoke enabled, with no skips. Static checks passed again.

The final manual restart exposed a saved-configuration startup issue. CCR's
default `serve` command starts the old gateway before Dex replaces its ports
and transport key. Dex now starts management with `--no-gateway`, saves the
launch configuration and explicitly starts the gateway. The runtime contract
reproduced the failure, then passed a stop/start with saved configuration and
a real request after the fix. All 49 tests passed again, including native
Claude and recovery; the configured global router also restarted successfully.
