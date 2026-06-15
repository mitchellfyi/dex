# Dex Factory v1 Credential Boundary

Dex Factory v1 keeps provider, repository and machine credentials on the worker
that runs Dex. Factory stores run metadata and receives events; it does not hold
Claude Code, Codex, GitHub CLI or repository dependency credentials.

## Boundary

The worker owns:

- Claude Code authentication.
- Codex authentication.
- `git` and GitHub CLI authentication.
- Local repository checkouts.
- Project dependency access.
- Any local environment needed to run tests or build assets.

Factory owns:

- Companies, projects, repositories, workers and runs.
- Dex run specs.
- DexCode API tokens used by the Rails app ingestion contract.
- Run event, artifact and report records.
- Notification channel configuration, with Slack webhook secrets referenced by
  environment variable name rather than stored directly in the database.

## Run Tokens

Dex accepts a run token through `dx run --spec-url ... --run-token ...`. The
token is used as a Bearer token when fetching the run spec and posting events
to Factory.

For the current Rails app contract, the token is a scoped `Dexcode::ApiToken`
with `runs:write` for event sync and `artifacts:write` for artifact upload.
Per-run token restriction can be added later, but v1 must still treat tokens as
worker credentials:

- Do not write run tokens into event payloads.
- Do not write run tokens into logs or artifact metadata.
- Prefer short-lived tokens for remote starts.
- Revoke tokens when a worker is retired.

## Event Submission

Dex posts events to the Rails app contract documented in `docs/events.md`:

```text
POST /api/v1/runs/:run_id/events/batch
Authorization: Bearer <token>
```

Factory must treat each event `id` as an idempotency key. Retries are expected:
Dex writes locally first, advances the remote sync cursor only after a
successful response and may submit the same event batch again after a network
failure.

## Remote Worker Start

The v1 remote start model is SSH bootstrap:

```bash
ssh dex-worker@example.com "cd /srv/dex/repos/org/repo && dx run --spec-url https://factory.example.com/api/v1/runs/run_123/spec --run-token ..."
```

The SSH session starts the run. Dex event sync, not SSH output, is the source of
live state after startup.

Factory should enforce conservative scheduling:

- one active run per worker by default
- one active run per repository by default
- no automatic merge
- no provider credential storage in Factory

## Redaction And Logs

Dex already redacts obvious secret-looking values before writing local run logs.
That is a guardrail, not a guarantee. Factory and workers must treat events,
logs, artifacts and command summaries as potentially sensitive.

Never include these in event `message`, event `data`, logs or artifact metadata:

- OAuth tokens
- API keys
- Slack webhook URLs
- GitHub tokens
- Claude/Codex credentials
- private dependency credentials

## Future Evolution

The v1 boundary leaves room for:

- per-run token rows bound to one `run_id`
- GitHub App installation tokens
- managed secret references
- worker registration tokens
- per-company isolation controls
- a worker daemon that avoids passing tokens through SSH command arguments

Those are later hardening steps. The first production path should keep Factory
as an observer and starter, not a central credential store.
