# Maintenance ticket requests

Triage plans work. A maintenance request asks Dex to attempt it within the
configured mode, fix categories, and PR limit. Marking a ticket ready, editing
it, reopening it, or commenting does not request execution.

## Setup

New `.dex/dex.md` files use `issue_label=dex-execute` and keep all maintenance
modes at `report`. Installation does not create or apply labels. Create the
label in GitHub, then apply it deliberately to an open issue:

```sh
gh label create dex-execute --description 'Request one maintenance attempt.'
gh issue edit 123 --add-label dex-execute
```

The configured label must exist and differ from readiness labels and the
maintenance PR label. Dex rejects `triage:*` and its configured PR label;
repositories that use other readiness labels must keep them separate too.
The person applying the execution label needs current write, maintain, or
admin access. Scheduled runs check that original requester as well.

`issue_mode` controls direct label-triggered runs. `schedule_mode` controls
scheduled runs; `default_mode` controls unfocused manual workflow dispatch
unless its mode input overrides it. An attempt in `report` mode produces a
report, not an implementation. Requesting execution never promotes the mode
or expands allowed fix categories.

## Requests and attempts

| State or action | Behaviour |
|---|---|
| Apply the execution label | Create a pending request |
| Remove it before a claim | Cancel the pending request |
| Provider setup fails before a claim | Leave the request pending |
| Claim the request | Post one attempt record on the issue, with the Actions run link |
| Execution, publication, or the runner fails after a claim | Keep the attempt consumed |
| Repeated events or workflow reruns | Skip the consumed request |
| Remove and reapply the label | Request another attempt |

The label stays in place after a claim. Removing or reapplying it does not
stop an already claimed run; cancel that run in Actions when needed. If a
claim response is lost, Dex reads the issue before proceeding and requires
its own verified record. It never retries that write blindly. A record left
by an interrupted run still counts as an attempt, even if no agent started.

Request identity uses the repository, issue, and execution-label event ID.
Keep the claim comments: deleting or editing their request markers removes
the consumption evidence. This is an operational record, not protection
against someone who can alter issue history. All automatic claim-and-launch
paths must retain the installed workflow's shared repository concurrency
group. GitHub comment creation alone is not an atomic lock.

## Scheduled and manual work

Scheduled runs and unfocused workflow dispatch inspect pending requests,
oldest first, with issue number breaking ties. Eligibility is checked before
the queue limit (default 10). Each invocation selects and claims at most one
ticket. Unselected requests stay pending. A request cancelled or consumed
after selection is skipped at claim time.

An empty queue, paused intake, or unavailable request evidence still permits
independent repository maintenance. The report records why ticket intake
was skipped. Dex never falls back to an unrestricted open-issue queue.

For a deliberate local invocation:

```sh
dx maintain --issue 123 --mode report
```

This fetches the selected open issue and authorises that invocation without
requiring a label. It does not create, consume, or renew an automatic request.
Remove a pending execution label if local work replaces that request. Local
maintenance without `--issue` uses repository evidence. Context files alone
do not authorise work on tickets.

## Existing installations

Custom settings remain unchanged. Missing, blank, repeated, or `_none_`
`issue_label` settings pause automatic ticket intake with a setup notice.
Choose and create a dedicated label to enable it. Independent maintenance,
explicit local execution, and maintenance PR feedback remain available.

Existing workflow files retain their old behaviour until updated.
`dx maintain install-workflow` preserves differing files. Review local edits
before explicitly replacing one:

```sh
dx maintain install-workflow --force
```

The updated intake job needs issue-write permission to record claims. The
provider still receives no GitHub write credentials; publication remains in
the existing wrapper or publish job. Updating a workflow file does not enable
a disabled GitHub workflow. Review repository workflow settings separately.

Standalone triage retains normal interactive write access. Its planning
boundary is a prompt instruction, with explicit session-user redirection
available when the task changes to implementation.
