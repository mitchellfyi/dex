# Manual QA

Dex ends Phase 2 with a manual QA pass. The implementing agent starts the
change, drives every approved acceptance criterion and verification requirement
by hand, and records one evidenced row per criterion plus any exploratory
findings. The result is a report that the lifecycle header, `dx status` and the
PR summarize. It is advisory, like UI proof: the Stop hook does not gate on it,
and the Phase 2 audit prompt is what asks for it.

The pass is the `dxqa` skill; its procedure is `prompts/workflows/dxqa.md`. The
report is written only through `dx qa`.

## Statuses

| Status | Meaning |
|---|---|
| `PASSED` | Every criterion row is `MET` or `N_A`, and every medium or high finding is `fixed` or filed as a `follow-up`. |
| `FINDINGS` | A criterion row is `NOT_MET`, or a medium or high exploratory finding is parked as a `note`. |
| `BLOCKED` | A criterion row could not be driven, or the whole pass could not run. |
| `N_A` | Nothing in the change runs by hand. |
| `MISSING` | No report has been recorded. |

The tool derives the status from the rows. A `status` in the draft is ignored.

## Commands

```bash
dx qa report --input draft.json        # validate the draft, write qa-report.json and qa-report.md
dx qa show                             # the summary; --json prints the report
dx qa status                           # prints the status; exit 0 fresh, 3 stale, 1 missing
dx qa blocked --reason "..."           # the pass could not run
dx qa not-applicable --reason "..."    # nothing runs by hand
```

Each command takes `--session ID`; the default is the current lifecycle
session. The report lives at:

```text
~/.claude/.dex-artifacts/qa/<session>/
  qa-report.json    canonical; written only by dx qa
  qa-report.md      rendered from the JSON by the same command
  draft.json        the last accepted draft
  evidence/         screenshots, response bodies, captured output
```

Set `DX_ARTIFACT_DIR` to move the root. Nothing here is committed.

## The draft

The agent supplies `ui_surface`, `hands`, `criteria` and `exploratory`:

```json
{
  "version": 1,
  "ui_surface": "web",
  "hands": ["claude-in-chrome", "curl"],
  "criteria": [
    {"kind": "acceptance", "index": 1, "text": "Saving confirms the change", "outcome": "MET",
     "evidence": ["/Users/me/.claude/.dex-artifacts/qa/<session>/evidence/save.png"],
     "notes": "The saved banner appears after Save."}
  ],
  "exploratory": [
    {"id": "qa-1", "severity": "low", "title": "Focus ring is faint", "repro": "1. Tab to Save.",
     "expected": "A visible focus ring.", "actual": "A faint ring.", "evidence": [],
     "disposition": "note", "reference": ""}
  ]
}
```

Validation, in `scripts/qa-report.py`:

- exactly one row per `acceptance_criteria` entry and per
  `verification_requirements` entry of the session's approved criteria file,
  matched by `kind` and 1-based `index`, with `text` verbatim;
- `outcome` is `MET`, `NOT_MET`, `BLOCKED` or `N_A`; `MET` and `NOT_MET` rows
  need at least one evidence path that is a regular, non-empty, non-symlink
  file under the session's `evidence/` directory; `BLOCKED` and `N_A` rows
  need `notes`;
- exploratory items have a unique `id`, a `severity` of `high`, `medium` or
  `low`, a `title`, numbered `repro` steps, and a `disposition` of `fixed`,
  `follow-up` (with the tracker key as `reference`) or `note`;
- at most 128 criteria rows, 200 exploratory items, 4000 characters per string.

A rejected draft leaves the previous report in place.

The report records the criteria file and its approval hash, the checkout and
working-tree fingerprints the pass ran against, and the hands it used.
`dx qa status` exits 3 when the working tree has changed since the report, or
when the report cannot be checked against a tree at all; the summary prints
`Stale: yes` for the first case. Staleness is a warning the Phase 2 summary
and the PR line explain, not a block.

## Hands by surface

- Web: the Claude-in-Chrome browser tools, Playwright MCP, or Chrome DevTools
  MCP when the session has them; otherwise a `dx ui-capture` storyboard. A
  `satisfied` after-stage claim in the UI proof bundle is admissible evidence
  for the criterion it names.
- API: `curl` with credentials through `--config` on stdin; response bodies as
  evidence.
- CLI: the command's stdout, stderr and exit code.
- Native: the project's own driver, or `BLOCKED` with the reason.

## Dispositions

A `NOT_MET` criterion is a Phase 2 defect: fix it, re-drive it, update the row.
An exploratory finding is `fixed` when bounded and in scope, `follow-up` when
real but out of scope (filed through `prompts/issue-hygiene.md` after a
duplicate search), or `note` when speculative. The Phase 2 audit does not
complete with a `NOT_MET` row; `BLOCKED` and `N_A` need a reason that clears the
blocker rule.

## PR handoff

Phase 5 reads `dx qa status` and `dx qa show --json` and writes one line under
`## Testing Performed`:

```text
Manual verification: QA PASSED — 12/12 criteria MET; exploratory: 1 fixed, 1 follow-up (DEX-123); report: ~/.claude/.dex-artifacts/qa/<session>/qa-report.md
```

A stale report adds `(stale: the tree changed after the report — <what changed>)`.
A `MISSING` report is named as missing. The report is text and is never attached
as media.

## Retention

Dex marks the report completed when the lifecycle reaches terminal completion.
`dxclean` removes completed reports after the UI proof retention window,
`DX_UI_CAPTURE_RETENTION_DAYS` (30 days by default). Active reports are never
removed by age.

## Troubleshooting

| Symptom | Action |
|---|---|
| `dx qa report` says the session has no valid approved criteria | Phase 1 did not leave `review-criteria.json`, or it no longer validates. Repair the artifact, then rerun. |
| A row is rejected for evidence outside the session directory | Copy the file under `evidence/` and reference the copy. |
| A `MET` row is rejected for missing evidence | Save the screenshot, body, or output that shows the behaviour and reference it. |
| `dx qa status` exits 3 | The tree changed after the report. Re-drive the affected rows and run `dx qa report` again, or explain the change in the summary. |
| The pass cannot start the app | Resolve the port or service locally. Record `dx qa blocked --reason` only when the blocker is real and the reason clears the Phase 2 blocker rule. |
