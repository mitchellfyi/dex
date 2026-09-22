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
- `review.tier.assessed`
- `review.tier.selected`
- `review.wave_budget.changed`
- `review.pass.started`
- `review.pass.finished`
- `review.tier.escalated`
- `review.completed`
- `review.paused`
- `artifact.created`
- `session.reaped`
- `session.reap.completed`
- `session.summary`
- `gate.queued`
- `gate.started`
- `gate.finished`
- `plan.created` and other event types emitted by future lifecycle helpers

## Session Process Ownership

Every process started inside a session carries that session's token, on a file
descriptor and in its environment, so one that detached itself with `nohup`,
`disown`, `setsid`, or a background launch is still identifiable after the
process tree no longer connects it to anything. When the session ends, the
reaper stops what it owns and says what it stopped.

| Event | When emitted | Data fields |
|-------|--------------|-------------|
| `session.reaped` | One per process the reaper stopped | `pid`, `ppid`, `age_seconds`, `rss_kb`, `cwd`, `command` (truncated to 200 characters), `method`, `reason` |
| `session.reap.completed` | Once per reap pass that found at least one owned process | `reason`, `scope`, `method`, `candidates`, `reaped`, `survived` |
| `session.summary` | Once per provider session, after the reap that ended it | `reason`, `phase`, `heavy_commands`, `heavy_seconds`, `queue_seconds`, `over_budget_commands`, `peak_rss_mb`, `peak_rss_samples`, `reaped`, `survived` |

`session.summary` completes the pair: the reap events say what was still
running, and the summary says what the session spent getting there, with the
reap's own counts carried into it so one event answers both. It is emitted
from the same `dx_session_finish_processes` call, after the reap, for the four
reasons that end a session. See § Session Telemetry for every field.

`method` names how the host identified the owned processes: `proc` for a Linux
`/proc/<pid>/fd` scan, `libproc` for the macOS descriptor lookup, `lsof` for
the fallback, `unavailable` when the host could supply none of them. Reading
it is how you tell a host that answered cheaply from one that needed `lsof`
installed.

`reason` records what ended the session: `session-end` (the SessionEnd hook),
`phase-exit` (the provider returned), `watchdog-kill` (the phase runtime budget
expired), `launcher-stopped` (the runtime supervisor found its launcher gone),
`control-cancel` (`dx control stop` or `dx control cancel`), or
`ps-reap-orphans` (`dx ps --reap-orphans`). `dx control pause` and
`dx control detach` reap nothing: pause is resumable and detach hands control
back, so neither ends the session's processes. Removing a session's state files
does not reap either — it keeps the token and says so, because the token is the
only way to find what the session still owns.

`scope` is `session` for a pass that stops everything the session owns, and
`detached` for one that spares the live provider's own process tree and stops
only what already escaped it. A reap pass never signals the caller's own
ancestry, so the hook running it, the provider above it, and the shell holding
the token survive long enough to finish.

A process that refuses to stop is reported as a survivor rather than logged as
reaped, it gets no `session.reaped` event, the summary counts it under
`survived`, and its session keeps its token and temp root so `dx ps` can find
it again. Only a pass with no survivors removes them.

A pass that found nothing emits nothing. `dx ps` shows the same ownership
without stopping anything.

## Heavy Gates

`dx run-gate` runs one heavy command — a project gate, a test suite, a build;
never a dev server, which starts directly and is session-owned — under
host-wide admission. Three events cover its life, so a run
journal shows how long the host made it wait as distinct from how long the work
itself took.

| Event | When emitted | Data fields |
|-------|--------------|-------------|
| `gate.queued` | Before the gate waits for a `heavy` lease | `gate`, `pool`, `limit`, `priority_wrapper` |
| `gate.started` | After admission, immediately before the command runs | `gate`, `pool`, `limit`, `queue_seconds`, `priority_wrapper`, `test_jobs`, `command`, `timeout_seconds` |
| `gate.finished` | After the command exits, whatever its status | `gate`, `pool`, `exit_code`, `duration_seconds`, `queue_seconds`, `priority_wrapper`, `test_jobs`, `checkout_fingerprint`, `working_fingerprint`, `stable`, `command`, `timeout_seconds`, `over_budget`, `receipt` |

`priority_wrapper` names the reduced-priority wrapper the command actually ran
under: `nice+taskpolicy` on macOS, `systemd-run` or `nice+ionice` on Linux,
`nice` where only that worked, `none` where the host would not even renice.
Each candidate is probed by running it, so the value records what happened
rather than what was configured.

`stable` is false when the working tree changed while the gate was running. The
result is still real and still recorded — a completed result is never
discarded — but it describes neither the tree before nor the tree now, so
`dx_gate_receipt_lookup` never matches it.

A gate cancelled while it waits emits `gate.queued` and nothing else. One
cancelled while it runs emits `gate.finished` with the signal's exit code,
because the command genuinely ended.

## Review Telemetry

Lifecycle and standalone review loops append structured events to the run
journal. Lifecycle review uses the lifecycle run ID. A standalone
`dxreviewloop` prepares its own run before tier resolution and the first wave.
It emits `run.started`, ends with `run.completed` or `run.blocked`, writes a
summary, and prints the run ID so a paused review can be diagnosed without
reading agent transcripts.

| Event | When emitted | Data fields |
|-------|--------------|-------------|
| `review.tier.assessed` | After a fresh read-only assessor returns a valid risk decision | `tier`, `source`, `reason_codes`, `floor`, `floor_reason` |
| `review.tier.selected` | Before the first review wave | `tier`, `profile`, `required_clean`, `source`, `reason_codes`, `policy_small`, `policy_normal`, `policy_complex`, `max_waves` |
| `review.wave_budget.changed` | A live override or tier escalation changes the outer-wave budget | `max_waves`, `iteration` |
| `review.pass.queued` | Before a wave waits for host capacity | `pass_id`, `tier`, `profile`, `iteration`, `capacity_limit` |
| `review.pass.started` | After host admission, immediately before a fresh wave starts | `pass_id`, `tier`, `profile`, `iteration`, `clean_before`, `required_clean`, `scope_fingerprint`, baseline fields, scout count/parallelism, capacity limit/active/wait, and test jobs |
| `review.pass.finished` | After the wave result is validated and counters update | Core result/evidence fields plus `provider_exit`, `provider_failure_class`, deterministic-baseline reuse, scout and capacity settings, queue time, test jobs, and wrapper-clocked context/check/scout/verifier/fix durations with completeness/source fields |
| `review.tier.escalated` | A verified risk signal raises the tier | `from_tier`, `tier`, `profile`, `required_clean`, `iteration` |
| `review.completed` | The effective consecutive clean target succeeds | `tier`, `profile`, `required_clean`, `trusted_required_clean`, `assurance_outcome` (`completed` or `waived`), `clean_passes`, `iterations`, `max_waves`, `findings_fixed`, `total_duration_seconds`, `reason=clean_gate_reached` |
| `review.paused` | Review needs intervention | `tier`, `profile`, `required_clean`, `clean_passes`, `iterations`, `max_waves`, `findings_fixed`, `total_duration_seconds`, normalized `reason` |

Tier selection is `trivial`/`small`/`normal`/`complex`, mapping to
`light`/`light`/`standard`/`thorough` review. The global consecutive clean-wave
requirements are 1 for `trivial` and `small`, 2 for `normal`, and 3 for
`complex`. A tier is also derived from the measured diff at wave time and can
raise, never lower, what the agent selected. Dex binds that policy to the
selection, review state, pass evidence, clean ledger, and final receipt. An
attributed `review.clean-passes` session override can select
a lower effective target without altering the global policy. Such a run still
performs the selected number of independent clean waves, but its completion
event and receipt outcome are marked `waived` rather than `completed`.
The operational outer-wave budget defaults to 2/3/6/9 for those tiers, and a
confirmation pass (`clean_before` at least 1) that stays clean does not spend it. A
`review.max-waves` override changes only that budget; exhausting it pauses the
loop without producing a completion receipt.

`review.pass.finished` carries `result_kind=notes` for a `NOTES:N` wave: no
verified finding above the finding bar, no fix, N notes recorded in the
findings ledger. It counts toward the clean gate exactly as `clean` does. The
loop pauses with `reason=no_convergence` when `findings` has not fallen across
three consecutive passes that each found something — the `CHURN:no-convergence`
stop. `dx review stats` reads these same events back per tier.

`result_kind=mechanical` marks a `MECHANICAL:N` wave: a deterministic autofix
inside one check's declared inputs. It is a fix, not clean credit — the streak
resets, the pass appends to the findings history and the churn detector, and the
deterministic tier floor is re-derived from the moved tree; one such wave per
loop does not spend the wave budget.

Evidence version 3 records the ordered hash, outcome, and substantive
context-pack references for every lifecycle criterion. It also binds the
manifest to the current policy and pass. Before granting clean credit, Dex
attests the manifest, context pack, result, profile, and findings fingerprint
together. It retains private, read-only copies of the manifest and context pack
for each clean row, then revalidates those copies and recomputes every
attestation before accepting the final receipt. Telemetry keeps only bounded
aggregate fields and an opaque evidence hash; finding text and per-criterion
evidence stay out of events so later waves remain independent.

These events make it possible to compare pass duration, findings discovered
after earlier clean waves, clean-counter resets, escalation frequency,
coverage, and churn without reading agent transcripts.

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

- token, secret, password, auth, and API-key assignments, including the
  `{"access_token": "…"}` form an API error body arrives in
- common GitHub, OpenAI, Slack, and bearer/basic auth token forms
- Dex's own `dc_live_`, `dc_worker_`, and `dc_run_` credentials, which need no
  surrounding key name to be recognized

This is a guardrail, not a full secret scanner. Two shapes it will not catch: a
credential containing a space, and a bare high-entropy string with no key,
prefix, or header to anchor on. Logs stay local and must not be committed to the
product repo.

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

The registration body contains `kind`, `title`, `filename`, `content_type`,
`byte_size`, `sha256`, and the artifact's JSON-object `metadata`. Dex keeps
metadata larger than DexCode's 8 KiB limit in the local journal and uploads the
artifact with an empty metadata object.
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
Sending an artifact's bytes is not an API request and gets its own budget of
300 seconds, because a captured video or Playwright trace does not cross a home
upstream in fifteen. Set `DEXCODE_UPLOAD_TIMEOUT_SECONDS` (1 to 3600) to change
it; raising `DEXCODE_HTTP_TIMEOUT_SECONDS` past 300 raises uploads with it.

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
queued, the terminal `run.completed`, `run.failed`, or `run.blocked` event
must still reach DexCode during the final flush. Numeric
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

For local (non-headless) runs on a connected machine, Dex currently exports
the machine's DexCode CLI token as `DEX_RUN_TOKEN`/`DEX_FACTORY_TOKEN` so the
run's events can sync; unlike headless worker runs, those values are not
scoped to one run and are visible to the whole launched process tree.

Sync state lives beside the run journal:

```text
~/.dex/runs/<run_id>/.factory-sync/
  cursor
  offset
  status.json
  last-log
  .lock/
```

`cursor` stores the highest sequence that Factory accepted, and `offset` a
validated byte-offset hint into the journal so a flush can resume without a
full rescan. `status.json` stores the latest sync or configuration failure and
the next retry time; `last-log` rate-limits repeated failure log lines, and
`.lock/` serializes concurrent flush attempts. Failed
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

## Session Telemetry

A session that swamped the machine leaves nothing behind to look at unless
something wrote the numbers down while it ran. `dx run-gate` records what each
heavy command cost, the runtime supervisor samples how much memory the session
was holding, and one event at the end says what the whole thing came to. The
next regression is then a diff between two numbers rather than a machine that
swapped again for reasons nobody can reconstruct.

`session.summary` is listed with the reap events it completes, under
§ Session Process Ownership. What each of its fields means:

`reason` is the reap reason that ended the session — `session-end`,
`phase-exit`, `watchdog-kill` or `launcher-stopped`. The other two reap
reasons emit nothing: `dx control stop` stops only what already detached from
a session that is still running, and `dx ps --reap-orphans` cleans up after a
session that ended without anyone watching, which has no journal left to
write to.

`phase` is the lifecycle phase this session was running, as a string, or null
outside a lifecycle. The ownership token and `DX_SESSION_TMP` belong to one
provider session, which in a lifecycle is **one phase**, so the summary is per
phase and names it. A lifecycle produces one summary per phase it ran, not one
for the whole ticket.

`heavy_commands`, `heavy_seconds` and `queue_seconds` come from the gate
ledger the session keeps beside its token — one row per `dx run-gate` that
finished, so the same gate run twice counts twice. `over_budget_commands`
counts the ones that reached their deadline. Heavy work run outside a gate is
not counted, because nothing observed it.

`peak_rss_mb` is the largest total resident size the session's token-carrying
process tree reached, in whole megabytes. The runtime supervisor samples it on
the heartbeat it already runs (every 30 seconds by default;
`DEX_SESSION_RSS_SAMPLE_SECONDS` changes the interval), summing `ps -o rss=`
over exactly the PIDs the ownership scan produces, and keeps the running peak
in the session's `.process` directory. `peak_rss_samples` says how many
samples that peak is drawn from. A session with no supervisor, or a host that
will not report resident size, records `peak_rss_mb: null` and no samples: a
peak nobody measured must not read as a peak of zero.

`reaped` and `survived` repeat the reap pass's own counts, so one event
answers "what did this cost and did it clean up" without joining two.

The same numbers are printed once, as a line a human reads:

```
[info]  worktree-cc-700: session summary: phase 4, 3 heavy command(s) (812s running, 41s queued), peak RSS 1842 MB, 2 reaped, 0 survived
```

An unsampled host prints `peak RSS unavailable` in place of the megabytes, and
a session outside a lifecycle prints `phase -`. A session that never took
process ownership has nothing to summarise and prints nothing.

### Heavy-gate fields

The gate events carry the per-command half of the same picture. Their full
field lists are under § Heavy Gates; what the four telemetry fields there
mean:

| Field | On | Meaning |
|-------|----|---------|
| `command` | both | The gate's command line, truncated to 200 characters |
| `timeout_seconds` | both | The deadline the gate was given; `0` is no deadline, the default |
| `over_budget` | `gate.finished` | True when the gate reached that deadline. The real exit code and duration are recorded either way — a completed result is never discarded, and a stopped one is still a thing that happened |
| `receipt` | `gate.finished` | Path of the receipt this result was written to, empty when the write failed |
