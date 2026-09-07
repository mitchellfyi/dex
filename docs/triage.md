# Ticket triage

`dx triage` investigates the codebase and improves tickets in the configured
tracker. It clarifies product decisions, writes acceptance criteria, estimates
effort, checks duplicates, and plans dependencies and smaller PR-sized tickets.
It never implements code or creates PRs.

```sh
dx triage ENG-123
dx triage --single ENG-123
dx triage --project "Account settings"
dx --agent codex triage https://github.com/example/app/issues/123
dx --agent claude --model <model> triage ENG-123
dx triage
```

A ticket includes its descendants unless you pass `--single`. Project mode
includes open project tickets and their descendants; completed work and external
blockers supply context. With no target, the agent asks you to select one. Quote
project names or freeform descriptions containing spaces. Use `--` before a
description that starts with a dash.

`dx refine`, `dxrefine`, and `/dxrefine` are compatibility aliases for the new
workflow. `dxtriage` and `/dxtriage` also work. Refinement no longer forces multiple
children or requires an architecture file. `/dxplan` still handles the separate
implementation-planning phase; there is no `dx plan` alias.

## What happens in a session

The agent reads tracker conventions, relevant tickets and comments, and the
implementation. It searches open and closed tickets for duplicate and related
work before creating anything. It asks you about unresolved decisions. You can
answer or defer a question to the ticket; when deferring, identify the stakeholder
to tag. The agent posts only after both the deferral and recipient are clear.

Ticket improvements publish as the session progresses. New children and concrete
incidental findings can be filed after duplicate checks. Reorganising existing
tickets requires approval of a specific proposal, including relationship changes,
reparenting, merging, closing, or moving work. It also asks before expanding an
existing ticket outside your selected scope. Approval is retained for that proposal.

Descriptions contain the current outcome, scope, testable acceptance criteria,
and essential constraints. Completed plans and decisions go in concise comments,
with the approach, effort, delivery order, and verification where needed. Technical
details belong where the implementer needs them. Unrelated findings need
evidence and bounded scope; triage does not become a whole-repository audit.

The result links updated and created tickets, duplicates and related work, delivery
order, effort, outstanding approvals, and stakeholder questions. Parallel work and
actual blockers are separate from a suggested sequence. Missing permissions or
incomplete scope are reported explicitly.

## Readiness and estimates

Triage follows existing project rules, labels, statuses, templates, and estimate
scales. Without conventions it uses XS–XL with rationale and uncertainty in the
description. These sizes are relative, not delivery dates. Parent rollups do not
count the same work twice.

Equivalent existing readiness labels are reused. Otherwise Dex can create
`triage:needs-info` and `triage:ready`. Ready means sufficiently specified; a ready
ticket may still depend on unfinished work. A material unanswered decision or an
unverified implementation prevents readiness.

Readiness does not request implementation. The maintenance workflow uses a
separate execution label and allows one attempt per application. See
[the maintenance handoff](maintenance.md) before enabling ticket intake.

Default status handling leaves unanswered Linear intake in Triage and accepts
clarified intake into its existing default backlog. Other statuses and GitHub
open/closed state stay unchanged unless a project mapping or your approval says
otherwise. Triage preserves assignments, priority, and scheduling commitments;
new issues remain unassigned in the backlog. It does not create workflow states
or custom fields.

## Re-triage and limitations

Run the same command after replies arrive. The agent reads current descriptions
and discussions, incorporates clear answers, and updates the plan and readiness.
Conflicting replies need a decision; the newest comment does not automatically
win. Changed plans get a short comment explaining the change and linking the prior
plan and reply. Unchanged plans, unanswered questions, and stakeholder mentions
are not repeated.
There is no background watcher.

Use the repo's configured tracker and available authenticated tools. GitHub and
Linear capability notes are in [the tracker guide](../prompts/triage-trackers.md).
Its Linear section links official MCP, GraphQL schema/API, pagination, and product
docs. Agents discover the available tools and current schema before using them.
Native relationships and estimates are preferred; unsupported features use linked
prose where possible, with limitations reported. With no tracker, the agent returns
drafts in the session. It does not install integrations.

Shell launches use separate session state and suppress implementation lifecycle
hooks. Direct skill invocation inside an active or paused lifecycle requires a
separate session. Normal interactive mode permits tracker writes; the workflow's
no-implementation boundary is an agent instruction, not a filesystem sandbox.
Full write access remains available. Ticket text and discovered problems do not
authorise implementation; the session user can explicitly redirect the task.
If the host enforces plan mode, publishing waits until that mode ends.
