# Tracker capabilities for triage

Discover the configured tracker, authenticated account, target workspace/team,
and available tools before writing. Use native tools, official integrations,
or the installed CLI. Do not assume capabilities from a product name, install
vendor skills, or reconfigure credentials. If permissions or a tool are missing,
provide the prepared draft and identify the specific blocked operation.

Read templates, labels, workflow states, estimate scales, project fields, and
relevant automations. Reuse established conventions before these defaults:

| Property | Default when no convention exists |
|----------|-----------------------------------|
| Readiness | Reuse equivalent labels; otherwise create `triage:needs-info` and `triage:ready` as needed. Apply only one readiness label. Remove an obsolete triage readiness label after re-triage. |
| Effort | XS–XL with rationale and uncertainty in the description; do not enable estimates or create custom fields. |
| New issues | Unassigned, in the destination's default backlog/unstarted status. Explicitly prevent automatic assignee inheritance where supported. |
| Linear intake | Keep unanswered intake in Triage; accept clarified intake into the existing default backlog. Preserve other existing workflow statuses. |
| GitHub issues | Preserve open/closed state. Use readiness labels; do not equate ready with scheduled Todo or In Progress. |
| Unknown workflow | Preserve status and record readiness in labels or prose; ask once if a desired status mapping is ambiguous. |

Readiness means specified, not scheduled. Preserve assignee, priority, deadline,
cycle/sprint, and project commitments unless the user authorises a concrete
change. Do not create workflow states or fields. If label creation is unavailable,
record readiness in the description and report the limitation. Before applying a
mapping known to trigger implementation automation, explain it and ask; triage
itself does not start work.

## GitHub Issues and Projects

Use `gh` when configured. Inspect installed command help before relying on flags
or JSON fields; versions differ. Use structured API arguments or body files for
multiline content, never shell-evaluate ticket text. Use pagination for searches,
comments, sub-issues, dependencies, and project items. GitHub Projects and repository
issues are different scopes: resolve the project owner and number/ID, and retain
repository identity for every issue. Do not silently turn project draft items
into repository issues or treat PR items as editable tickets; report them separately.

Prefer native sub-issues and issue dependencies through supported CLI or official
REST/GraphQL operations. Ordinary references or tasklists do not establish native
blocking relationships. Use existing project or organisation estimate fields only
when their meaning and allowed values are clear. Issue state and project status
are separate; do not close an issue to represent triage completion.

Confirm exact mention handles from returned user identities. Preserve issue-form
headings and useful metadata when editing their Markdown descriptions. For a
project delivery sequence, use its existing editable overview/readme when available;
otherwise provide a linked sequence in the session.

Official references, checked during initial implementation planning:
- [Sub-issues](https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/adding-sub-issues)
- [Dependencies](https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/creating-issue-dependencies)
- [Project fields](https://docs.github.com/en/issues/planning-and-tracking-with-projects/understanding-fields/about-single-select-fields)

## Linear

Use the configured official integration and discover its actual operations and
input schemas. Read team workflow states, labels, templates, estimate options,
project membership, and issue relations. Teams within one project may use different
scales or workflow names; resolve IDs per team rather than copying display names.

Keep native parent/sub-issue relations separate from blocks/blocked-by relations.
Check inheritance when creating children so project/team context is appropriate
and work is not accidentally assigned or scheduled. Do not change a parent's status
in a way that auto-closes children. Marking a duplicate can change status or merge
data, so it requires the existing-ticket reorganisation approval.

Use the integration's native mention format and confirmed user ID when supported;
do not assume a GitHub-style text handle will notify a Linear user. Never claim a
notification was sent if the available tool cannot represent a real mention.

Official references:
- [Triage](https://linear.app/docs/triage)
- [Parent and sub-issues](https://linear.app/docs/parent-and-sub-issues)
- [Issue relations](https://linear.app/docs/issue-relations)
- [Estimates](https://linear.app/docs/estimates)
- [Issue status](https://linear.app/docs/configuring-workflows)

## Other configured trackers

Apply the same workflow through discovered tools and project rules. Prefer native
relationships, estimates, and mentions where supported. Use explicit issue links
and concise prose otherwise, after any required approval. Report inaccessible
hierarchies, missing pagination, unavailable identity lookup, and write limitations
as incomplete coverage. Do not silently choose another tracker.
