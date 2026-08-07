# Dex Run Data

Dex writes local run data for provider-backed commands. Events are the
machine-readable timeline. Logs and artifacts are the human-readable debugging
and evidence trail.

## Storage

Each run gets a stable ID and a directory under:

```text
~/.dex/runs/<run_id>/
  spec.json
  events.jsonl
  logs.txt
  summary.json
  artifacts/
    manifest.json
    run-summary.md
    ...
```

`dx`, `dx run`, `dxreviewloop`, `dx init`, and `dx sync` print the current run ID
near startup. Main lifecycle runs also show it in the phase header.

Run data is written locally first. When a DexCode connection is active, Dex can
sync events and captured artifacts after the local write succeeds. Logs stay on
the worker. Event, log, artifact, and remote sync failures are non-fatal after
the run directory has been prepared.

Headless runs started with `dx run --spec` normalize the supplied run spec into
`spec.json` before emitting events. See [run-specs.md](run-specs.md) for the
headless startup contract.

## Mental Model

- Events are small structured state changes used by future timelines, reports,
  and notifications.
- Logs are timestamped text for a person debugging a run.
- Artifacts are files produced during a run, with manifest metadata so a UI can
  display them later.

Do not model every log line as an event. Emit events for state changes and
write detailed output to `logs.txt`.

## Event Schema

`events.jsonl` is append-only. Each line is one JSON object:

| Field | Type | Notes |
|-------|------|-------|
| `id` | string | Event ID, unique inside the journal |
| `run_id` | string | Stable run ID, also used as the directory name |
| `sequence` | number | Monotonic sequence for this run |
| `type` | string | Dotted event name such as `run.started` |
| `company_slug` | string | Owner parsed from `origin`, when available |
| `project_slug` | string | Repo name parsed from `origin` or the directory |
| `repo` | string | `owner/repo` when available, otherwise repo directory name |
| `phase` | string or null | Lifecycle phase number when the event belongs to a phase |
| `severity` | string | `info`, `warn`, or `error` |
| `message` | string | Short human-readable summary |
| `data` | object | Event-specific structured payload |
| `created_at` | string | UTC timestamp in ISO-8601 form |

Current lifecycle event types include:

- `run.started`
- `run.completed`
- `run.failed`
- `run.blocked`
- `phase.started`
- `phase.completed`
- `phase.failed`
- `review.tier.selected`
- `review.pass.started`
- `review.pass.finished`
- `review.tier.escalated`
- `review.completed`
- `review.paused`
- `artifact.created`
- `plan.created` and other event types emitted by future lifecycle helpers

## Review Telemetry

Lifecycle and standalone review loops append structured events to the run
journal. Lifecycle review uses the lifecycle run ID. A standalone
`dxreviewloop` prepares its own run before tier resolution and the first wave.
It emits `run.started`, ends with `run.completed` or `run.blocked`, writes a
summary, and prints the run ID so a paused review can be diagnosed without
reading agent transcripts.

| Event | When emitted | Data fields |
|-------|--------------|-------------|
| `review.tier.selected` | Before the first review wave | `tier`, `profile`, `required_clean`, `source`, `reason_codes` |
| `review.pass.started` | Immediately before a fresh wave starts | `tier`, `profile`, `iteration`, `clean_before`, `required_clean` |
| `review.pass.finished` | After the wave result is validated and counters update | `tier`, `profile`, `iteration`, `result_kind`, `findings`, `duration_seconds`, `clean_before`, `clean_after`, `scope_changed`, `provider_exit`, normalized `terminal_reason`; early failure events emit the applicable subset |
| `review.tier.escalated` | A verified risk signal raises the tier | `from_tier`, `tier`, `profile`, `required_clean`, `iteration` |
| `review.completed` | The consecutive clean gate succeeds | `tier`, `profile`, `required_clean`, `clean_passes`, `iterations`, `findings_fixed`, `total_duration_seconds`, `reason=clean_gate_reached` |
| `review.paused` | Review needs intervention | `tier`, `profile`, `required_clean`, `clean_passes`, `iterations`, `findings_fixed`, `total_duration_seconds`, normalized `reason` |

Tier selection is `small`/`normal`/`complex`, mapping to `light`/`standard`/
`thorough` review and 3/6/9 consecutive clean waves. These events make it
possible to compare pass duration, findings discovered after earlier clean
waves, clean-counter resets, escalation frequency, and churn without reading
agent transcripts.

Review telemetry deliberately excludes raw agent rationale, result suffixes,
findings, findings fingerprints, file paths, branch names, prompts, diffs, and
context-pack contents. It stores validated reason codes and normalized result or
exit categories instead. Findings fingerprints stay in transient global Dex
state and exist only for deterministic repeated/alternating churn detection.
`operator-override` and `wave-escalation` are wrapper-reserved selection reason
codes; assessor decisions use the bounded codes from
`prompts/review-risk-assessment.md`.

Event redaction remains a backstop, not permission to emit arbitrary review
text. Events may be sent to the configured Factory collector, so review payloads
must be safe before `dx_event_emit` receives them.

## Logs

`logs.txt` stores timestamped human-readable lines. Dex writes lifecycle
messages there and tees filtered provider progress from `dx init` and `dx sync`
when provider analysis runs.

Dex applies basic redaction before writing to logs:

- token, secret, password, auth, and API-key assignments
- common GitHub, OpenAI, Slack, and bearer/basic auth token forms

This is a guardrail, not a full secret scanner. Logs stay local and must not be
committed to the product repo.

## Artifacts

`artifacts/manifest.json` lists local artifacts:

```json
{
  "schema_version": 1,
  "artifacts": [
    {
      "id": "art_abc123",
      "type": "run_summary",
      "path": "run-summary.md",
      "title": "Run summary",
      "size_bytes": 312,
      "sha256": "...",
      "metadata": {
        "status": "completed"
      },
      "created_at": "2026-05-27T12:34:56Z",
      "updated_at": "2026-05-27T12:34:56Z"
    }
  ]
}
```

Artifact paths are relative to `artifacts/`; absolute paths and `..` segments
are rejected. Registering an artifact emits `artifact.created`.

`summary.json` is the machine-readable final run summary. Dex also writes
`artifacts/run-summary.md` and records it in the manifest when summaries are
updated.

### DexCode artifact upload

An active DexCode connection or headless run token uploads each captured
artifact in three steps:

1. Register its metadata with `POST /api/v1/runs/<run_id>/artifacts`.
2. Upload the file bytes to the returned `upload.url` with `PUT`.
3. Confirm the byte count, content type, and SHA-256 digest with
   `POST /api/v1/runs/<run_id>/artifacts/<artifact_id>`.

The registration body contains `kind`, `title`, `filename`, and `content_type`.
The confirmation body has this shape:

```json
{
  "byte_size": 312,
  "content_type": "text/markdown",
  "sha256": "..."
}
```

Dex sends its Bearer token to the registration and confirmation endpoints. It
does not send that token to the signed upload URL. Upload URLs must use HTTP or
HTTPS and cannot contain credentials or a fragment.

For a headless run, Dex uses `DEX_FACTORY_URL` as the artifact API base. If the
run spec supplies only the standard `.../api/v1/runs/<run_id>/events/batch`
endpoint, Dex derives the same API base from that path.

After confirmation succeeds, the local manifest records
`dexcode_artifact_id`, `dexcode_artifact_sha256`, and a sync fingerprint.
Registering unchanged content and metadata again does not upload it twice. If
the file or remote-facing metadata changes, Dex uploads a fresh artifact and
replaces those fields with the new remote identity, digest, and fingerprint.

Artifact upload remains best effort. A registration, storage, or confirmation
failure leaves the local file and manifest intact so the run can continue.
Set `DEXCODE_SYNC=0` (or `false`, `no`, or `off`) to disable run and artifact
sync. `DEXCODE_CONTEXT_SYNC` accepts the same values for project context.
DexCode API requests time out after 15 seconds by default; set
`DEXCODE_HTTP_TIMEOUT_SECONDS` to a value from 1 to 3600 to change that limit.

Project-context requests are file-backed and size-limited. Each Markdown entry
includes `source_byte_size`, `body_byte_size`, and `truncated`; the top-level
`truncation` object records the candidate, included, omitted, and truncated
entry counts. Defaults are 20,000 bytes per entry, 524,288 bytes for the full
JSON request, and 100 entries. Adjust them with
`DEXCODE_CONTEXT_ENTRY_MAX_BYTES`, `DEXCODE_CONTEXT_TOTAL_MAX_BYTES`, and
`DEXCODE_CONTEXT_MAX_ENTRIES`. Dex still hashes the complete source file when
its body is truncated.

Use `dx login` to connect a machine, `dx whoami` to check its active
organisation, project, and sync settings, and `dx logout` to remove the local
connection. `dx login --timeout SECONDS` sets the browser-approval deadline;
it does not change the per-request timeout above.

## Factory Event Sync

Factory sync is opt-in. Dex always appends to `events.jsonl` first, then tries
to send unsynced events to the configured HTTP collector.

When DexCode login is configured, `dx whoami` shows the connected organisation,
project, API URL, sync URL, and whether session, event, and project-context sync
are enabled. This is the quickest local check that new runs will be associated
with the intended DexCode project before starting a long lifecycle.

Minimum configuration:

```bash
export DEX_FACTORY_SYNC=true
export DEX_FACTORY_URL=https://factory.example.com
export DEX_FACTORY_TOKEN=...
```

Dex posts event batches to:

```text
POST <DEX_FACTORY_URL>/api/v1/runs/<run_id>/events/batch
Authorization: Bearer <token>
Content-Type: application/json
```

The request body is:

```json
{
  "events": [
    {
      "id": "evt_000001_abcd1234",
      "run_id": "run_20260527T123456Z_1234_abcd",
      "sequence": 1,
      "type": "run.started",
      "message": "Dex run started",
      "data": {},
      "created_at": "2026-05-27T12:34:56Z"
    }
  ]
}
```

Factory should treat `event.id` as the idempotency key. If a request fails, Dex
does not advance its local sync cursor, so the same events may be submitted
again on a later retry.

Each sync attempt drains queued events in bounded batches rather than sending
only one batch. This matters at the end of a run: if earlier events are still
queued, the terminal `run.completed`, `run.failed`, `run.blocked` or
`run.cancelled` event must still reach DexCode during the final flush. Numeric
token-count fields such as `total_input_tokens` and `total_output_tokens` are
kept as telemetry; actual token, credential and authorization fields are still
redacted before they are written or synced.

Configuration variables:

| Variable | Default | Notes |
|----------|---------|-------|
| `DEX_FACTORY_SYNC` | auto | `true`, `1`, `yes`, or `on` enables sync. `false`, `0`, `no`, or `off` disables it. If unset, a configured Factory URL or endpoint enables sync. |
| `DEX_FACTORY_URL` | unset | Base Factory URL. Dex appends `/api/v1/runs/<run_id>/events/batch`. |
| `DEX_FACTORY_EVENTS_ENDPOINT` | unset | Exact event endpoint. Supports `{run_id}` replacement and takes precedence over `DEX_FACTORY_URL`. |
| `DEX_RUN_TOKEN` | unset | Run token from `dx run`; takes precedence for headless event and artifact sync. |
| `DEX_FACTORY_RUN_TOKEN` | unset | Run-scoped Bearer token fallback. |
| `DEX_FACTORY_TOKEN` | unset | Machine-level Bearer token fallback for event submission. |
| `DEX_FACTORY_BATCH_SIZE` | `50` | Maximum events per HTTP request. |
| `DEX_FACTORY_MAX_BATCHES_PER_FLUSH` | `20` | Maximum queued batches to send in one flush. |
| `DEX_FACTORY_TIMEOUT_SECONDS` | `5` | HTTP request timeout. |
| `DEX_FACTORY_RETRY_BASE_SECONDS` | `1` | Initial backoff after a failed request. |
| `DEX_FACTORY_RETRY_MAX_SECONDS` | `60` | Maximum backoff between retry attempts. |

Sync state lives beside the run journal:

```text
~/.dex/runs/<run_id>/.factory-sync/
  cursor
  status.json
```

`cursor` stores the highest sequence that Factory accepted. `status.json`
stores the latest sync or configuration failure and the next retry time. Failed
sync attempts are logged to `logs.txt` with rate limiting so a broken collector
does not flood the run log.

Retries happen when another event is emitted or when a caller explicitly runs:

```bash
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"
dx_factory_sync_pending_events <run_id>
```

Network errors, HTTP errors, missing tokens, and missing Factory configuration
do not fail the Dex run. They leave local events queued until sync is configured
and a retry succeeds.

## Reading Data

Inspect the latest run manually:

```bash
run_id=$(ls -t ~/.dex/runs | head -1)
tail -n 20 "$HOME/.dex/runs/$run_id/events.jsonl"
tail -n 20 "$HOME/.dex/runs/$run_id/logs.txt"
python3 -m json.tool "$HOME/.dex/runs/$run_id/artifacts/manifest.json"
```

Pretty-print a journal with Python:

```bash
python3 -m json.tool ~/.dex/runs/<run_id>/summary.json
python3 - ~/.dex/runs/<run_id>/events.jsonl <<'PY'
import json
import sys

for line in open(sys.argv[1], encoding="utf-8"):
    event = json.loads(line)
    print(event["sequence"], event["type"], event["phase"], event["message"])
PY
```
