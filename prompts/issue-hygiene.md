# Issue and PR Hygiene

Use this contract during Phase 0 whenever a tracker is configured. In later
phases, use it when a requirement, implementation discovery, review finding,
verification failure, or reviewer comment adds material context. Routine code
observations that do not warrant tracker work need only be reported as
unchanged.

## Search before writing

Before creating or substantially rewriting an issue:

1. Read the working issue's description, acceptance criteria, comments,
   relations, status, assignee, and linked branch or PR.
2. Search the configured tracker across open and closed issues using more than
   the proposed title. Search for the exact error or identifier, the affected
   component, the root cause, and the intended outcome. Read the strongest
   candidates and their comments before classifying them.
3. If the current branch has an existing open PR, read its title, body,
   comments, reviews, linked issues, and current state. In Phase 0, reconcile an
   existing PR but do not create one, mark it ready, request reviewers, or post
   review notifications.

Do not call issues duplicates because their titles resemble each other. Compare
root cause, affected behavior, acceptance criteria, and intended outcome.

## Classify and act

- **Duplicate:** Update an existing issue instead of creating a duplicate. Add
  missing evidence or decisions to the canonical issue and link the working
  issue when the tracker supports relationships. Do not silently close the
  ticket the user explicitly selected or switch the lifecycle to another
  ticket; ask first when that choice changes ownership or scope.
- **Related and in scope:** Work belongs in the same pull request when it is
  required for the accepted behavior, fixes the same root cause, and remains a
  bounded change. Update the working issue's description or acceptance
  criteria and the approved plan before implementing it. A material expansion
  still needs the normal plan-change approval and criteria-seal rotation.
- **Related but distinct:** Create a linked follow-up issue automatically when
  the evidence is concrete and the work has a different root cause, outcome,
  release boundary, or risk profile. Search again with the final proposed title
  before creating it. Put the new issue in Backlog/Todo and leave it unassigned
  unless work is starting now. Include evidence, impact, a bounded scope,
  acceptance criteria, verification notes, and a `discovered while <issue/PR>`
  link. Add the tracker relationship when supported and mention it in the
  current issue or PR.
- **Unclear:** Ask the user when evidence is speculative, the duplicate choice
  is ambiguous, or deciding between the same PR and a follow-up changes product
  behavior. Do not file low-confidence noise just to clear a checklist.

Never copy secrets, private customer data, exploit details, or sensitive logs
into a broadly visible issue. Escalate sensitive findings through the project's
approved security channel.

## Reconcile the working issue and PR

Comments often contain the current decision while the issue description and PR
body remain stale. Consolidate accepted clarifications into the working issue's
description and acceptance criteria. Preserve useful history, identifiers,
links, checkboxes, and attribution; cite the clarifying comment instead of
erasing where the decision came from.

For an existing open PR, update its title or body when accepted scope,
implementation, related issues, risk, or verification has materially changed.
Preserve its template, reviewer requests, discussion, and accurate existing
content. Preserve its draft/ready state unless the active lifecycle phase
explicitly requires a readiness transition; never move a ready PR back to
draft. Reply to review comments through the review workflow rather than
rewriting them. Run `humanizer` before posting issue descriptions, comments, PR
copy, or summaries.

Fresh isolated review children must not create or update external issues. They
report concrete out-of-scope candidates with evidence; the lifecycle owner
performs the duplicate search and tracker write once, after accepting the
finding. This prevents independent review waves from filing the same issue.

## Report every phase

Every phase handoff and completed-phase summary must contain one line in this
form, even when no tracker is configured or nothing changed:

`Issue/PR work: working issue <updated|unchanged|N/A>; duplicates <keys|none|N/A>; related <keys|none|N/A>; created <keys|none|N/A>; PR <updated|unchanged|N/A>.`

Use real identifiers and links when available. Do not claim an issue or PR was
updated unless the write succeeded.
