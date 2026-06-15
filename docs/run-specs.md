# Dex Run Specs

Dex supports two startup modes:

```text
Manual mode
  A person starts Dex locally with a ticket number or task description.

Headless/spec mode
  A caller writes a JSON run spec, starts `dx run`, and Dex uses that spec for
  repo, source, harness, workflow, and sync context.
```

Headless mode does not replace the normal CLI. It validates the spec, prepares
the same local run journal under `~/.dex/runs/<run_id>/`, then launches the
existing lifecycle in the target repository.

## Commands

Run from a local file:

```bash
dx run --spec ./run-spec.json
```

Fetch from a Factory-style endpoint:

```bash
dx run --spec-url https://factory.example.com/api/v1/runs/run_123/spec \
  --run-token "$DEX_RUN_TOKEN"
```

Validate without preparing a run journal:

```bash
dx run --spec ./run-spec.json --validate-only
```

Validate and prepare the run journal without launching Claude:

```bash
dx run --spec ./run-spec.json --dry-run
```

`--run-token` is used as a Bearer token for remote spec fetches and is exported
as `DEX_RUN_TOKEN` for Factory event sync. If it is omitted, Dex falls back to
`DEX_RUN_TOKEN`, `DEX_FACTORY_RUN_TOKEN`, then `DEX_FACTORY_TOKEN`.

## Spec Shape

Run specs are plain JSON. They describe the run; they must not contain secrets.

```json
{
  "run_id": "run_01J_example",
  "company": {
    "slug": "materials-market",
    "name": "Materials Market"
  },
  "project": {
    "slug": "web",
    "name": "Web App"
  },
  "repository": {
    "provider": "github",
    "full_name": "org/repo",
    "default_branch": "main",
    "working_directory": "/srv/dex/repos/org/repo"
  },
  "source": {
    "type": "github_issue",
    "id": "123",
    "url": "https://github.com/org/repo/issues/123",
    "title": "Example task",
    "body": "Task details..."
  },
  "harness": {
    "name": "claude-code",
    "model": null
  },
  "workflow": {
    "name": "ticket_to_pr",
    "version": "v1",
    "requires_plan_approval": false,
    "requires_ui_evidence": "auto",
    "auto_merge": false
  },
  "sync": {
    "factory_url": "https://factory.example.com",
    "events_endpoint": "https://factory.example.com/api/v1/runs/run_01J_example/events/batch"
  }
}
```

Required fields:

| Field | Notes |
|-------|-------|
| `run_id` | Must start with `run_` and contain only letters, numbers, `.`, `_`, or `-`. |
| `repository.working_directory` | Existing git checkout where Dex should run. |
| `source.type` | Source kind, such as `github_issue` or `task`. |
| one source identifier | At least one of `source.id`, `source.url`, `source.title`, or `source.body`. |

Optional fields:

| Field | Notes |
|-------|-------|
| `harness.name` | `claude-code`, `claude`, or `codex`. Defaults to `claude-code`. |
| `harness.model` | Optional model override for the selected harness. |
| `workflow.requires_plan_approval` | Defaults to `true`. When `false`, the run spec authorizes Phase 1 after plan quality checks pass. |
| `workflow.requires_ui_evidence` | `auto`, `always`, `never`, `true`, or `false`. |
| `sync.factory_url` | Enables Factory event sync unless `DEX_FACTORY_SYNC` disables it. |
| `sync.events_endpoint` | Exact event endpoint. Takes precedence over `sync.factory_url`. |

Dex rejects keys whose names look like secrets, including token, secret,
password, credential, and API-key fields.

## Runtime Behavior

`dx run` normalizes the spec into:

```text
~/.dex/runs/<run_id>/spec.json
```

The normalized file preserves the nested spec and adds the flat fields used by
the existing event journal, such as `company_slug`, `project_slug`, `repo`,
`repo_path`, `workspace_mode`, and `input`.

Startup emits:

- `run.started` after the journal is prepared
- `run.failed` when fetch, validation, or workspace startup fails
- `run.blocked` for `--dry-run`, because the lifecycle was intentionally not
  launched

If the spec includes sync settings, event sync uses the existing Factory event
sync path. Sync failures do not fail the run; local events remain queued.

## Validation Failures

Invalid specs fail before the lifecycle launches. Dex still tries to create a
local run journal and emit `run.failed` with the failure stage:

- `fetch`
- `validation`
- `startup`

If the spec cannot supply a usable `run_id`, Dex creates a generated local run ID
for the failure journal.
