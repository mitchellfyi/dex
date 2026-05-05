---
name: "dkplan"
description: "Create an implementation plan from a ticket or user request after gathering project context."
---

# Skill: dkplan

Create an implementation plan from a ticket or user request.

## When to Use

- At the start of new work, after the SessionStart hook has confirmed readiness
- When asked to plan work for a feature, bug fix, or refactor

## Steps

### 1. Gather Context

Use the integrations configured in doyaken.md § Integrations. Skip any that are "not configured".

**Ticket tracker:**
- Read the ticket — title, description, acceptance criteria, relations, comments.
- If no tracker is configured: gather requirements from the user's request, branch name, and local documentation.

**Design tool** (if configured and ticket references design URLs):
- Fetch design context and screenshots for referenced designs.

**Error monitoring** (if configured and ticket relates to a bug):
- Search for related errors to understand the bug context and stack traces.

**Related work:**
- If the ticket has related/blocking issues, read those too.
- Check recent git history for related changes: `git log --oneline -20`

### 2. Understand the Codebase

1. Read the relevant `AGENTS.md`, `CLAUDE.md`, or `README.md` for each area affected.
2. Read any project-specific conventions or rules referenced in those files.
3. Explore affected code paths — identify files to modify, patterns to follow, similar features to reference.
4. Search for existing utilities, components, and helpers that can be reused.

**Understanding check** — before drafting the plan, answer these five questions (to yourself):

1. What is the exact input and output of this change?
2. What existing code will this interact with?
3. What are the failure modes?
4. What is explicitly out of scope?
5. What would a reviewer challenge about this approach?

If you cannot answer all five confidently, gather more context.

### 2.4 Surface Assumptions and Ask the User

**Bar: if you cannot answer with 100% confidence from the ticket, codebase, or related docs, ask the user.** Do not silently make decisions on the user's behalf — even when the decision seems obvious to you. The user's domain context, deadlines, downstream coordination, and prior decisions are invisible from inside the codebase.

Before defining the target state, list every:

- **Assumption** you're making about scope, behaviour, or constraints
- **Concern** about ambiguity, conflicting requirements, or risk
- **Unknown** you couldn't resolve from the materials at hand

For each one, ask: "Could I be wrong about this?" If your confidence is below 100%, surface it to the user.

**How to ask:**
- Use the `AskUserQuestion` tool to batch up to 4 related clarifying questions at once. Provide concrete options where possible (e.g., "Approach A vs Approach B"). `AskUserQuestion` is allowed in plan mode.
- Group related questions in a single call rather than asking serially.
- For genuinely free-form questions where options don't fit, ask in plain text.

**Acceptable to skip asking only when:**
- The assumption is universally true (e.g., "the codebase uses Git")
- The decision is fully reversible during implementation with no downstream cost (no contract change, no schema change, no visible behaviour shift)
- The unknown is implementation detail that can be deferred to TDD discovery without affecting the plan

**Always ask** when the unknown affects: scope, contract (types, schemas, APIs), naming of public symbols, behaviour the user can observe, performance budgets, security posture, or visible UX.

After the user answers, refine the plan. If new unknowns surface, ask again. Iterate until you can articulate every plan decision as either "the user said X" or "this is universally safe / fully reversible during implementation". Residual assumptions that survive this loop must be listed verbatim in Step 7 alongside the plan.

### 2.5 Define the Target State

Before drafting task lists, explicitly describe the end state:

1. **What does done look like?** List the specific files that exist/changed, functions that are callable, tests that pass, and behaviors that differ from today.
2. **Diff against current:** For each element, note: exists today (modify), doesn't exist (create), or exists but shouldn't (remove).
3. **Validate against acceptance criteria:** Walk each criterion and confirm the target state satisfies it. If any criterion is unmet by the target, the target is wrong — revise before proceeding.
4. **Make criteria verifiable:** Each acceptance criterion must include a **verification command** — a concrete assertion that can be checked mechanically:
   - Test-based: "Running `npm test -- --grep 'auth middleware'` passes"
   - File-based: "File `src/config.ts` exports `AuthConfig` type"
   - Behavior-based: "GET /api/health returns 200 with `{\"status\":\"ok\"}`"
   - Negative: "Running `grep -r 'TODO' src/` returns no matches"
   - Prose-only criteria ("works correctly", "is performant") must be rewritten as testable assertions.

The plan is then the ordered steps transforming current state into this target. Work backward: what must be true last? What must be true before that? Continue until you reach the current state.

This step exists because plans naturally construct backward from a target. Making the target explicit and validated prevents a common failure: a well-structured plan aimed at the wrong outcome.

### 3. Draft the Plan

For non-trivial tickets (more than a config change, typo fix, or single-file edit), present **2-3 approaches** before detailing the chosen one:

#### Approach Options (non-trivial tickets only)

| Approach | Description | Pros | Cons |
|----------|-------------|------|------|
| **Minimal** | Smallest change that meets requirements | Fast, low risk, easy to review | May need follow-up work |
| **Balanced** | Clean implementation following existing patterns | Maintainable, idiomatic | Takes longer |
| **Comprehensive** | Full solution with edge cases, optimisations, extensibility | Complete, future-proof | Largest scope, longest review |

Present the approaches briefly (2-3 sentences each), then recommend one with reasoning. For trivial tickets, skip this and go straight to the task list.

**Research mandate** (non-trivial tickets): before finalizing the approach, search for common pitfalls related to the chosen technology or pattern. Check: official documentation, similar implementations in the codebase, known issues in dependencies you'll use.

#### Task List

1. Write a numbered list of discrete work items. Each item should be:
   - Small enough to implement and test in one sitting
   - Clear about which files will be modified
   - Clear about which acceptance criteria it addresses
2. Include tasks for tests, documentation updates, and generated code refresh where applicable.
3. Note any dependencies between tasks (e.g., "migration must come before entity").
4. Identify risks, unknowns, or decisions that need user input.
5. Classify each change as additive (safe), modification (potentially breaking), or removal (breaking). Note migration needs for breaking changes.
6. Assign a **risk level** to each task. This drives review depth in `/dkreview`:
   - **HIGH** — security, auth, data access, migrations, new external integrations, financial logic
   - **MEDIUM** — business logic, refactors touching multiple files, API contract changes
   - **LOW** — config, docs, formatting, simple additive changes, test-only changes
7. For MEDIUM and HIGH risk tasks, include:
   - **review_focus** — what the reviewer should look for (e.g., "verify auth check on all new endpoints")
   - **testing_guidance** — what to test (e.g., "test both valid and expired tokens")

### 4. Plan Quality Checklist

Before presenting the plan, verify it against these quality gates:

1. **COMPLETENESS** — Does the plan cover every acceptance criterion? Re-read the ticket/prompt requirements. For each one, confirm there is a task that addresses it. If any criterion is missing or only partially covered, add a task. Every criterion must have a verification command — prose-only criteria must be rewritten as testable assertions.
2. **EDGE CASES** — Have you considered failure modes? What happens with invalid/empty/boundary inputs? What happens when external services are unavailable? Are error messages helpful?
3. **RESEARCH** — Were common pitfalls for the chosen approach checked? Is there prior art in the codebase? Is a migration strategy documented for breaking changes?
4. **DEPENDENCIES** — Are tasks correctly ordered? Would any task fail if run before another? Are shared types/interfaces created before consumers?
5. **SCOPE** — Is the plan minimal and focused? Remove any task not required by the acceptance criteria. Do not plan for hypothetical future work.
6. **RISKS** — Are unknowns identified? For each risk, is there a mitigation or fallback?
7. **ASSUMPTIONS** — Has every <100%-confidence assumption been surfaced to the user via Step 2.4 and answered? List the assumptions you made; for each, name the source: "user said X" or "universally safe / fully reversible". If you cannot name a source, you skipped Step 2.4 — go back and ask.

If any gate fails, fix the plan before proceeding.

### 5. Track Tasks

1. Call `TaskCreate` for each work item in the plan.
2. Store task IDs for tracking during implementation.

### 6. Update Ticket (if tracker configured)

Add the plan summary to the ticket via the configured tracker. If no tracker is configured, skip — the plan exists in the conversation and task list.

### 7. Present to User

**STOP and present the plan to the user.**

Include:
- The numbered plan with task descriptions
- Files that will be modified
- **Assumptions surfaced and answered** — list each assumption resolved in Step 2.4 with a one-line note on what the user told you (so they can sanity-check)
- **Residual unknowns or open decisions** — anything that survived Step 2.4 (e.g., implementation details deferred to TDD); flag explicitly so the user can correct course
- Risks identified

If the previous step ended with no answered questions, double-check Step 2.4 — a non-trivial change with zero assumptions usually means assumptions were made silently.

When running in plan mode (e.g., via `dk` Phase 1 or `dkloop`), present the plan via `ExitPlanMode`. The user approves or rejects through the plan mode UI.

**Do not begin implementation until the user approves the plan.**

## Notes

- Keep plans minimal — only what's needed for the current ticket.
- Don't plan for hypothetical future work.
- If the ticket is small (e.g., a typo fix or config change), the plan can be a single task.
