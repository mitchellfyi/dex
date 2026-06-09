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
   - Is there prior art in the codebase that was considered?
   - If the change is breaking, is a migration strategy documented?

4. DEPENDENCIES — Are tasks correctly ordered?
   - Would any task fail if run before another?
   - Are database migrations scheduled before code that depends on them?
   - Are shared types/interfaces created before consumers?

5. SCOPE — Is the plan minimal and focused?
   - Remove any task that isn't required by the acceptance criteria.
   - Don't plan for hypothetical future work.
   - If a task could be split, is it small enough to implement and test in one sitting?

6. RISKS — Are unknowns identified?
   - For each risk, is there a mitigation strategy or fallback?
   - Are there questions that need answers before implementation can start?
   - If a risk affects scope, contracts, observable behaviour, performance, security, or visible UX, has the user answered or explicitly accepted it?

7. ASSUMPTIONS — Has every <100%-confidence assumption been surfaced to the user and answered?
   - List each assumption you made; for each, name the source: "user said X" or "universally safe / fully reversible during implementation".
   - If you cannot name a source for any assumption, you skipped the assumption-surfacing step. Use the `AskUserQuestion` tool now (it works in plan mode) to ask before proceeding.
   - If the tool/UI limits each question batch, ask another batch after the user answers. The batch limit is not a total limit.
   - Bar: if you cannot answer with 100% confidence from the ticket, codebase, or related docs, ask. Do NOT silently make decisions on the user's behalf — even when the decision seems obvious.
   - Always ask when the unknown affects scope, contracts (types/schemas/APIs), naming of public symbols, observable behaviour, performance budgets, security, or visible UX.

8. USER APPROVAL — Has the user explicitly approved this plan?
   - If this is a headless `dx run` session and the run spec has `workflow.requires_plan_approval: false`, the run spec is the approval source. Confirm the plan covers the spec and proceed after the normal plan quality checks pass.
   - Otherwise, if the user hasn't responded yet, wait. Do not proceed without approval.

If you find gaps in any of the above, fix them and re-present the plan.

**Completion criteria** — all must be true before you stop:
- All acceptance criteria are covered by tasks
- Edge cases are accounted for
- Every material risk has a mitigation, fallback, or explicit user acceptance
- Every <100%-confidence assumption has been surfaced and answered (or labelled "fully reversible during implementation")
- The user has explicitly approved the plan, or a headless run spec with `workflow.requires_plan_approval: false` authorizes it

When all criteria are met, stop. The Stop hook will verify your work and provide completion instructions.
