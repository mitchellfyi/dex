# Manual QA workflow

Exercise the change by hand against the approved acceptance criteria and leave
a report a reviewer can read. A green suite shows the code does what its tests
describe; this pass shows the change works from the user's side. The report is
advisory evidence, like UI proof: the lifecycle header, `dx status` and the PR
summarize it, and no Stop-hook gate reads it.

## Before you start

Follow § Resource Discipline in `prompts/guardrails.md`. Start the application
directly, not under `dx run-gate`: a server would hold a heavy lease for as long
as it runs. This session owns every process it starts and stops them before the
phase ends. Reuse a port this session already owns; if a port you did not open
is busy, report it rather than fighting it. Keep every artifact under Dex's
artifact directory and never stage or commit it.

Read `prompts/issue-hygiene.md`. Out-of-scope findings become linked follow-ups
through it, and the phase summary ends with its `Issue/PR work:` line.

## Inputs

```bash
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh" || exit 1
session_id="${DEX_SESSION_ID:-$(dx_session_id)}"
criteria_file=$(dx_review_criteria_file "$session_id")
dx_review_criteria_valid "$criteria_file" || echo "no valid approved criteria"
dx_review_read_criteria_approval "$session_id" || echo "criteria are not sealed"
dx_ui_capture_summary "$session_id"
```

Every `acceptance_criteria` entry and every `verification_requirements` entry
in the criteria file gets a row. Read the ticket and the full diff, committed
and working tree. When the UI proof bundle carries a `criteria` table, a
`satisfied` after-stage claim is admissible evidence for that criterion's row;
cite the bundle's screenshot or `visual-evidence.md`.

Without a valid criteria file the pass cannot write a report. Record
`dx qa blocked --reason` with that fact and repair the Phase 1 artifact first.

## Start the change

Start the application, worker, or command the way the project documents it
(`.dex/dex.md`, the README, a Procfile, package scripts). Wait until it
answers. Seed only the data the flows need, through the project's own seeding
path when there is one. Test accounts come from environment variable names;
never write a credential into evidence or into the report.

## Hands

Use the first that is available for the surface:

- Web: the Claude-in-Chrome browser tools, Playwright MCP, or Chrome DevTools
  MCP when the session has them; otherwise a `dx ui-capture` storyboard, whose
  screenshots and recorded claims are evidence in their own right.
- API: `curl`, with credentials passed through `--config` on stdin and never on
  the command line. Save response bodies as evidence.
- CLI: run the command and capture stdout, stderr, and the exit code.
- Native: the project's own driver (XCUITest, Detox, Playwright for Electron).
  Without one, the row is `BLOCKED` with the reason.

Evidence lives under `dx_qa_evidence_dir "$session_id"`: one screenshot,
response body, or captured output per row, as a regular file.

## Drive each criterion

One criterion at a time: drive the path, save one evidence file, judge the
outcome, add the row.

- `MET`: the behaviour the criterion describes happened and the evidence shows it.
- `NOT_MET`: it did not. This is a Phase 2 defect.
- `BLOCKED`: the path could not be driven. Say what stopped it. A busy port you
  did not open, a missing local service, or an unavailable tool is a problem to
  resolve, not a reason.
- `N_A`: the criterion has no runnable surface. Say why.

Then explore around the change: a happy-path variant, one bad or edge input,
refresh and back, the empty state, a permission denial. Record each finding
with a severity, numbered repro steps, expected and actual behaviour, and
evidence where you have it.

## Dispositions

A `NOT_MET` criterion is fixed now, in Phase 2: fix it, re-drive it, update the
row. Never relabel it. An exploratory finding is `fixed` when it is in scope and
bounded; `follow-up` when it is real but out of scope, filed through
`prompts/issue-hygiene.md` after a duplicate search, with the tracker key as its
`reference`; `note` when it is speculative. If the pass exposes a test-coverage
gap, add the test before finishing.

## Write the report

Write the draft and let the tool derive the status. A drafted `status` is
ignored.

```bash
draft="$(dx_qa_session_dir "$session_id")/draft-input.json"
mkdir -p "$(dirname "$draft")"
cat > "$draft" <<'JSON'
{
  "version": 1,
  "ui_surface": "web",
  "hands": ["claude-in-chrome"],
  "criteria": [
    {"kind": "acceptance", "index": 1, "text": "<the approved criterion, verbatim>", "outcome": "MET",
     "evidence": ["/absolute/path/under/the/qa/session/evidence/save.png"], "notes": "what was driven and seen"}
  ],
  "exploratory": []
}
JSON
dx qa report --input "$draft"
dx qa show
```

`dx qa report` refuses a draft with a missing row, a criterion text that differs
from the approved one, evidence outside the session directory, or a `MET` row
without evidence. `PASSED` means every row is `MET` or `N_A` and every medium
or high finding is `fixed` or filed as a `follow-up`. `FINDINGS` means a
`NOT_MET` row or a medium or high finding parked as a `note`: go back to the
dispositions. `BLOCKED` means a row could not be driven.

`dx qa blocked --reason` and `dx qa not-applicable --reason` record a whole pass
that could not run, or one with nothing to run by hand. The reason has to clear
the same bar as any other blocker.

## Clean up and report

Reset seeded data, stop everything this pass started, and confirm `dx ps`
shows nothing of yours. Finish with the `QA:` line from `dx qa show`, the path
of `qa-report.md`, and the `Issue/PR work:` line.
