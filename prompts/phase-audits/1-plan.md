> **Note:** Phase 1 uses `--dangerously-skip-permissions` plus
> `--permission-mode bypassPermissions` with Claude calling `EnterPlanMode` as
> its first action. Plan quality checks are built into the
> /dxplan skill (Step 4: Plan Quality Checklist) and enforced before
> ExitPlanMode is called. After the user approves the plan, this Stop hook audit
> verifies the approved plan and authorizes the same-session handoff to Phase 2.
> This audit only runs after dxplan writes the Phase 1 approval marker.

Before stopping, critically audit your plan:

1. COMPLETENESS — Does the plan cover every acceptance criterion from the ticket?
   - Re-read the ticket requirements. For each one, confirm there is a task that addresses it.
   - If any criterion is missing or only partially covered, add a task now.

2. EDGE CASES — Have you considered failure modes?
   - What happens when inputs are invalid, empty, or at boundary values?
   - What happens when external services are unavailable?
   - Are error messages helpful and specific?
   - If the plan doesn't account for these, add tasks or notes.

3. RESEARCH — Did the plan consider alternatives?
   - Were common pitfalls for the chosen approach researched?
   - Did online research use official docs, standards, release notes,
     maintainer material, or other primary sources when current best practice
     matters?
   - Is there prior art in the codebase that was considered?
   - If the change is breaking, is a migration strategy documented?

4. BETTER-WAY CHECK — Did the plan challenge the first apparent implementation?
   - Does it separate the user's desired outcome from the proposed mechanism?
   - Were at least the smallest viable change, the codebase-idiomatic change,
     and one clearly different approach considered for non-trivial work?
   - Does the recommendation explain why it fits the existing architecture,
     ownership boundaries, tests, operational behavior, security posture, and
     future maintenance?
   - If the best approach differs from the literal request, was that tradeoff
     surfaced to the user before approval?

5. DEPENDENCIES — Are tasks correctly ordered?
   - Would any task fail if run before another?
   - Are database migrations scheduled before code that depends on them?
   - Are shared types/interfaces created before consumers?

6. SCOPE — Is the plan minimal and focused?
   - Remove any task that isn't required by the acceptance criteria.
   - Don't plan for hypothetical future work.
   - If a task could be split, is it small enough to implement and test in one sitting?

7. RISKS — Are unknowns identified?
   - For each risk, is there a mitigation strategy or fallback?
   - Are there questions that need answers before implementation can start?
   - If a risk affects scope, contracts, observable behaviour, performance, security, or visible UX, has the user answered or explicitly accepted it?

8. ASSUMPTIONS — Has every <100%-confidence assumption been surfaced to the user and answered?
   - List each assumption you made; for each, name the source: "user said X", "docs/code prove X", "user explicitly deferred X", or "universally safe / fully reversible during implementation".
   - If you cannot name a source for any assumption, you skipped the assumption-surfacing step. Use the `AskUserQuestion` tool now (it works in plan mode) to ask before proceeding.
   - If the tool/UI limits each question batch, ask another batch after the user answers. The batch limit is not a total limit, and there is no preferred maximum number of batches.
   - Keep asking until every material assumption, concern, and unknown is answered, resolved from authoritative context, explicitly deferred by the user, or proven fully reversible during implementation. Do not present the plan with unresolved assumptions hidden inside implementation details.
   - Bar: if you cannot answer with 100% confidence from the ticket, codebase, or related docs, ask. Do NOT silently make decisions on the user's behalf — even when the decision seems obvious.
   - Always ask when the unknown affects scope, contracts (types/schemas/APIs), naming of public symbols, observable behaviour, performance budgets, security, or visible UX.

9. USER APPROVAL — Has the user explicitly approved this plan?
   - If this is a headless `dx run` session and the run spec has `workflow.requires_plan_approval: false`, the run spec is the approval source. Confirm the plan covers the spec and proceed after the normal plan quality checks pass.
   - Otherwise, if the user hasn't responded yet, wait. Do not proceed without approval.

10. FREEFORM TRACKER INTAKE — If this is a freeform `dx "<task>"` request and
   `.dex/dex.md § Integrations` has an enabled ticket tracker, did you complete
   or explicitly skip the tracker intake gate from `skills/dxplan/SKILL.md`?
   - The acceptable outcomes are: user chose to continue without tracker
     write-back; a parent ticket was created and selected; or a parent plus
     sub-issues were created and the user selected the first implementation
     ticket.
   - If a ticket was selected, confirm session metadata records its tracker key
     or GitHub issue number, and the chosen ticket is In Progress.
   - If this is not a freeform request, no tracker is configured, or the run is
     headless without explicit tracker write-back authorization, mark this check
     not applicable.

If you find gaps in any of the above, fix them and re-present the plan.

**Completion criteria** — all must be true before you stop:
- All acceptance criteria are covered by tasks
- Edge cases are accounted for
- The plan challenged the first apparent implementation and explains why the
  chosen approach fits the codebase better than rejected alternatives
- Current best-practice claims are backed by primary sources or explicitly
  marked as unavailable when online research tools were not available
- Every material risk has a mitigation, fallback, or explicit user acceptance
- Every <100%-confidence assumption has been surfaced and answered, resolved
  from authoritative context, explicitly deferred by the user, or labelled
  "fully reversible during implementation"
- The user has explicitly approved the plan, or a headless run spec with `workflow.requires_plan_approval: false` authorizes it
- Freeform tracker intake is complete, explicitly skipped, or not applicable

When all criteria are met, stop. The Stop hook will verify your work and provide completion instructions.
