---
name: "dxplan"
description: "Create an implementation plan from a ticket or user request after gathering project context."
---

# Skill: dxplan

Create an implementation plan from a ticket or user request.

## When to Use

- At the start of new work, after the SessionStart hook has confirmed readiness
- When asked to plan work for a feature, bug fix, or refactor

## Steps

### 0. Mark Phase 1 Started

When running under `dx` Phase 1, write the Phase 1 started marker before
gathering context:

```bash
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"
touch "$(dx_phase_started_file "${DEX_SESSION_ID:-$(dx_session_id)}" 1)"
```

This marker tells the Stop hook that the actual `dxplan` workflow is running.
Do not skip it when `DEX_SESSION_ID` is present.

Phase 0 (Setup) already renamed the branch, assigned the ticket, pushed the
branch, and moved status to In Progress before Phase 1 began. Do not redo
those steps here; only flag missing setup back to the user if you notice it.

### 1. Gather Context

Use the integrations configured in dex.md § Integrations. Skip any that are "not configured".

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
3. If `.dex/memory/index.md` exists, read it and load only memory entries
   whose scope matches the ticket, affected paths, or planning phase. Treat
   memory as context to verify, not proof.
4. Explore affected code paths — identify files to modify, patterns to follow, similar features to reference.
5. Search for existing utilities, components, and helpers that can be reused.

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
- Use the `AskUserQuestion` tool to batch related clarifying questions. If the UI/tool limits each batch (for example, 3 questions), that is only a per-call limit, not a total planning limit.
- Ask as many batches as needed. After each answer, re-check assumptions, risks, and unknowns; if new ones appear, ask another batch before drafting or presenting the plan.
- Group related questions in one call when possible, but do not suppress lower-priority questions just because the current batch is full.
- For genuinely free-form questions where options don't fit, ask in plain text.

**Acceptable to skip asking only when:**
- The assumption is universally true (e.g., "the codebase uses Git")
- The decision is fully reversible during implementation with no downstream cost (no contract change, no schema change, no visible behaviour shift)
- The unknown is implementation detail that can be deferred to TDD discovery without affecting the plan

**Always ask** when the unknown affects: scope, contract (types, schemas, APIs), naming of public symbols, behaviour the user can observe, performance budgets, security posture, or visible UX.

After the user answers, refine the plan. If new unknowns surface, ask again. Iterate until you can articulate every plan decision as either "the user said X" or "this is universally safe / fully reversible during implementation". Do not stop at an arbitrary question count. Do not present the final plan until every material assumption has been answered, explicitly deferred by the user, or proven fully reversible during implementation. Residual assumptions that survive this loop must be listed verbatim in Step 6 alongside the plan.

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
6. Assign a **risk level** to each task. This drives review depth in `/dxreview`:
   - **HIGH** — security, auth, data access, migrations, new external integrations, financial logic
   - **MEDIUM** — business logic, refactors touching multiple files, API contract changes
   - **LOW** — config, docs, formatting, simple additive changes, test-only changes
7. For MEDIUM and HIGH risk tasks, include:
   - **review_focus** — what the reviewer should look for (e.g., "verify auth check on all new endpoints")
   - **testing_guidance** — what to test (e.g., "test both valid and expired tokens")
8. If scoped memory affected the plan, cite the memory ID or file in the task's
   rationale so implementation and review can re-check it.

### 4. Plan Quality Checklist

Before presenting the plan, verify it against these quality gates:

1. **COMPLETENESS** — Does the plan cover every acceptance criterion? Re-read the ticket/prompt requirements. For each one, confirm there is a task that addresses it. If any criterion is missing or only partially covered, add a task. Every criterion must have a verification command — prose-only criteria must be rewritten as testable assertions.
2. **EDGE CASES** — Have you considered failure modes? What happens with invalid/empty/boundary inputs? What happens when external services are unavailable? Are error messages helpful?
3. **RESEARCH** — Were common pitfalls for the chosen approach checked? Is there prior art in the codebase? Is a migration strategy documented for breaking changes?
4. **DEPENDENCIES** — Are tasks correctly ordered? Would any task fail if run before another? Are shared types/interfaces created before consumers?
5. **SCOPE** — Is the plan minimal and focused? Remove any task not required by the acceptance criteria. Do not plan for hypothetical future work.
6. **RISKS** — Are unknowns identified? For each risk, is there a mitigation, fallback, or explicit user acceptance? If any risk changes scope, behavior, contracts, security, performance, or visible UX, surface it to the user before presenting the plan.
7. **ASSUMPTIONS** — Has every <100%-confidence assumption been surfaced to the user via Step 2.4 and answered? List the assumptions you made; for each, name the source: "user said X" or "universally safe / fully reversible". If you cannot name a source, you skipped Step 2.4 — go back and ask another batch.

If any gate fails, fix the plan before proceeding.

### 5. Track Tasks

1. Call `TaskCreate` for each work item in the plan.
2. Store task IDs for tracking during implementation.

### 6. Present to User

**STOP and present the plan to the user.**

Before presenting, invoke the `humanizer` skill on the user-facing plan text. Preserve all technical identifiers, commands, paths, and task structure exactly.

Include:
- The numbered plan with task descriptions
- Files that will be modified
- **Assumptions surfaced and answered** — list each assumption resolved in Step 2.4 with a one-line note on what the user told you (so they can sanity-check)
- **Residual unknowns or open decisions** — anything that survived Step 2.4 (e.g., implementation details deferred to TDD); flag explicitly so the user can correct course
- Risks identified, with mitigation/fallback or explicit user acceptance

If the previous step ended with no answered questions, double-check Step 2.4 — a non-trivial change with zero assumptions usually means assumptions were made silently.

When running in plan mode (e.g., via `dx` Phase 1 or `dxloop`), present the plan via `ExitPlanMode`. The user approves or rejects through the plan mode UI.

**Do not begin implementation until the user approves the plan.**

When running under terminal `dx` Phase 1, approval is the handoff signal to the Stop hook. For headless runs started by `dx run`, if `DEX_HEADLESS_RUN=1` and the run spec has `workflow.requires_plan_approval: false`, the run spec is the approval source; complete the same plan quality checks before continuing.

### 7. Tracker Intake Gate for Freeform Requests

If this Phase 1 plan came from a freeform `dx "<task>"` request rather than an
existing ticket id, run this gate after `ExitPlanMode` is approved and before
writing the Phase 1 ready marker.

First, check `.dex/dex.md § Integrations`:
- If the ticket tracker is `not configured`, skip this gate and continue.
- If the run is headless (`DEX_HEADLESS_RUN=1`), skip interactive write-back
  unless the run spec explicitly asks for tracker ticket creation.
- If a real ticket already exists for this work, record it in session metadata
  and proceed with that ticket rather than creating a duplicate.

Ask the user which path they want:
1. Continue implementation from the approved plan without creating tracker
   tickets.
2. Create a parent ticket for the approved plan, then continue implementation
   on that parent ticket.
3. Create a parent ticket plus proposed sub-issues, then ask which created
   issue should be implemented first.

When creating tracker items:
- Use the tracker configured in `.dex/dex.md § Integrations`.
- Apply the `humanizer` skill to every ticket title/body before creating it.
  Preserve file paths, commands, acceptance criteria, task numbering, risk
  labels, and verification commands exactly.
- Parent ticket body should include the approved plan summary, acceptance
  criteria, risks, and verification commands.
- Sub-issue bodies should be small enough for a single `dx <ticket>` lifecycle
  and include scope, dependencies, affected files, risk level, and verification
  commands.
- Linear: create issues through the configured Linear MCP. Use parent/child
  relations when the integration supports them.
- GitHub Issues: create issues with `gh issue create`. Reference the parent
  issue in each child body. Use existing labels only; do not create labels.

After write-back:
- Present the created ticket URLs and ask which ticket to implement first if
  more than one was created.
- For the chosen ticket, update session metadata:
  ```bash
  source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"
  SID="${DEX_SESSION_ID:-$(dx_session_id)}"
  dx_meta_write "$SID" "tracker_key=<KEY-OR-URL>" "ticket_number=<NUMBER-IF-GITHUB>"
  ```
- If the tracker provides a branch name for the chosen ticket, rename the
  current lifecycle branch to that branch, push it, and record it:
  ```bash
  git branch -m "$(git rev-parse --abbrev-ref HEAD)" "<tracker-branch-name>"
  git push -u origin "<tracker-branch-name>"
  dx_meta_write "$SID" "current_branch=<tracker-branch-name>"
  ```
- Move only the chosen implementation ticket to In Progress. Leave backlog
  sub-issues untouched unless the user explicitly says otherwise.

Do not write the Phase 1 ready marker until this gate is complete or explicitly
skipped by the user.

### 8. Update Ticket (if tracker configured)

Before writing the plan summary, invoke the `humanizer` skill on the draft copy. Preserve task numbering, file paths, commands, ticket IDs, and acceptance criteria exactly.

Add the plan summary to the existing or newly selected ticket via the configured tracker. If no tracker is configured, skip — the plan exists in the conversation and task list.

### 9. Mark Phase 1 Ready

After `ExitPlanMode` is approved, or after the headless run spec authorizes plan execution, complete the tracker intake gate and ticket update steps above when they apply. Then write the Phase 1 approval marker:

```bash
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"
touch "$(dx_phase_ready_file "${DEX_SESSION_ID:-$(dx_session_id)}" 1)"
```

Then print only a brief confirmation if needed and stop once so the hook can audit the plan and inject Phase 2 in the same Claude session. Do **not** tell the user to run `/dximplement`, do **not** ask whether to continue, and do **not** wait for another user prompt.

## Notes

- Keep plans minimal — only what's needed for the current ticket.
- Don't plan for hypothetical future work.
- If the ticket is small (e.g., a typo fix or config change), the plan can be a single task.
- For freeform `dx "<task>"` requests with a configured tracker, the user
  chooses whether the approved plan becomes tracker work before implementation
  starts.
