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
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh" || exit 1
touch "$(dx_phase_started_file "${DEX_SESSION_ID:-$(dx_session_id)}" 1)"
```

This marker tells the Stop hook that the actual `dxplan` workflow is running.
Do not skip it when `DEX_SESSION_ID` is present.

Phase 0 (Setup) already renamed the branch locally, assigned the ticket, and
moved status to In Progress before Phase 1 began. A newly created local branch
intentionally stays unpushed until its first implementation commit; an existing
published branch is left as-is. Do not redo those steps here; only flag missing
setup back to the user if you notice it.

Read `prompts/issue-hygiene.md`. Phase 0 normally completed the full search, so
repeat it only when planning adds material context or freeform tracker intake
would write a new issue. Reconcile accepted clarifications, related scope, and
the existing open PR before approval. End the phase handoff with the exact
`Issue/PR work:` line from the contract.

### 1. Gather Context

Use the integrations configured in dex.md § Integrations. Skip any that are "not configured".

**Ticket tracker:**
- Read the ticket — title, description, acceptance criteria, relations, comments.
- For Linear tool/API discovery, read the Linear section of
  `prompts/triage-trackers.md`; this skill still governs lifecycle status and approval.
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
6. Map the change against the surrounding architecture: ownership boundaries,
   data flow, public contracts, configuration surfaces, and test strategy. Note
   where the request naturally fits and where it would fight the current design.

**Understanding check** — before drafting the plan, answer these five questions (to yourself):

1. What is the exact input and output of this change?
2. What existing code will this interact with?
3. What are the failure modes?
4. What is explicitly out of scope?
5. What would a reviewer challenge about this approach?

If you cannot answer all five confidently, gather more context.

### 2.3 Challenge the Obvious Approach

Do not accept the requested implementation shape at face value. The user owns
the desired outcome; your job is to test whether the first apparent solution is
the best way to reach it in this codebase.

For every non-trivial ticket, run this challenge pass before defining the
target state:

1. **Restate the outcome, not the proposed mechanism.** Separate what the user
   needs from any assumed implementation detail in the ticket or prompt.
2. **Find codebase prior art.** Search for existing patterns, extension points,
   shared helpers, nearby tests, and constraints that should shape the plan.
3. **Research current practice.** When the change involves a framework,
   language feature, dependency, platform API, security-sensitive behavior, data
   modeling, accessibility, performance, or deployment concern, use online
   research if available. Prefer official docs, standards, release notes,
   migration guides, maintainer-written material, and primary sources. Use
   secondary articles only to identify pitfalls, then verify claims against
   primary sources.
4. **Compare alternatives.** Consider at least the smallest viable change, the
   codebase-idiomatic change, and one clearly different approach. Reject
   options that add avoidable scope, contradict established local patterns, or
   depend on unverified assumptions.
5. **Check holistic fit.** Ask whether the approach improves or harms module
   boundaries, reuse, testability, operational behavior, security posture,
   accessibility, and future maintenance.
6. **Decide deliberately.** Choose the approach that best satisfies the outcome
   while fitting the existing system. If the best approach differs from the
   literal request, surface that tradeoff to the user before presenting the
   plan.

If online research tools are unavailable, say so in the plan and rely on local
docs, dependency source, installed package metadata, and codebase precedent. Do
not invent best-practice claims without a source.

### 2.4 Surface Assumptions and Ask the User

**Use confidence and consequence, not a 100% certainty threshold.** Resolve factual questions from the ticket, codebase, and related docs first. When that context supports a high-confidence recommendation within the requested scope, adopt it in the plan and briefly explain why. Do not ask the user merely to confirm a well-supported recommendation.

Before defining the target state, identify material:

- **Assumptions** you're making about scope, behaviour, or constraints
- **Concerns** about ambiguity, conflicting requirements, or risk
- **Unknowns** you couldn't resolve from the materials at hand

**Ask when a significant assumption, missing or conflicting requirement, or low-confidence interpretation could change the approach or outcome.** Pay particular attention to scope, public contracts, observable behaviour, performance budgets, security, visible UX, and choices that are costly to reverse. A familiar code pattern alone does not resolve missing product intent.

High confidence does not authorize overriding an explicit user choice, expanding scope, taking an otherwise unauthorized external action, or bypassing plan approval.

**How to ask:**

- Batch related questions using the available question tool, or ask in plain text. Include a recommendation and its rationale when you have one.
- After each answer, refine the plan and ask again only if material uncertainty remains or new consequential gaps appear. There is no required question count; a tool's batch limit is not a reason to leave a consequential gap unresolved.
- Defer implementation details to TDD discovery when they do not affect the plan or carry downstream cost.

Before presenting the final plan, resolve consequential gaps from context or user answers, or obtain explicit user deferral. In Step 6, distinguish supported recommendations you adopted from user decisions and deferred unknowns; do not hide unresolved requirements inside implementation details.

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

For non-trivial tickets (more than a config change, typo fix, or single-file edit), present **2-3 approaches** before detailing the chosen one. These options must come from Step 2.3's challenge pass, not from generic "small/medium/large" templates if those labels do not fit the actual work:

#### Approach Options (non-trivial tickets only)

| Approach | Description | Pros | Cons |
|----------|-------------|------|------|
| **Minimal** | Smallest change that meets requirements | Fast, low risk, easy to review | May need follow-up work |
| **Balanced** | Clean implementation following existing patterns | Maintainable, idiomatic | Takes longer |
| **Comprehensive** | Full solution with edge cases, optimisations, extensibility | Complete, future-proof | Largest scope, longest review |

Present the approaches briefly (2-3 sentences each), then recommend one with reasoning. The recommendation must cite both local fit (existing paths, patterns, or constraints) and any external source that materially shaped the decision. For trivial tickets, skip this and go straight to the task list.

**Research mandate** (non-trivial tickets): before finalizing the approach, search for common pitfalls related to the chosen technology or pattern. Check: official documentation, similar implementations in the codebase, known issues in dependencies you'll use. If the best practice has changed recently or depends on a current library/framework version, verify it online or from installed package docs before relying on it.

#### Task List

1. Write a numbered list of discrete work items. Each item should be:
   - Small enough to implement and test in one sitting
   - Clear about which files will be modified
   - Clear about which acceptance criteria it addresses
2. Include tasks for tests, documentation updates, and generated code refresh where applicable.
3. Note any dependencies between tasks (e.g., "migration must come before entity").
4. Identify risks, unknowns, or decisions that need user input.
5. Classify each change as additive (safe), modification (potentially breaking), or removal (breaking). Note migration needs for breaking changes.
6. Assign a **risk level** to each task. This informs the Phase 2 review-risk
   selection (`prompts/review-risk-assessment.md`) and tells the implementer
   where to concentrate care:
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
4. **BETTER-WAY CHECK** — Did you challenge the literal requested implementation against alternatives, current best practice, and holistic codebase fit? If the plan simply implements the first idea without comparison, go back to Step 2.3.
5. **DEPENDENCIES** — Are tasks correctly ordered? Would any task fail if run before another? Are shared types/interfaces created before consumers?
6. **SCOPE** — Is the plan minimal and focused? Remove any task not required by the acceptance criteria. Do not plan for hypothetical future work.
7. **RISKS** — Are unknowns identified? For each risk, is there a mitigation, fallback, or explicit user acceptance? Ask about unresolved consequential risks under Step 2.4; document understood risks and their mitigations in the plan.
8. **ASSUMPTIONS** — Are adopted recommendations supported by the requirements and inspected context, with a brief rationale? Have significant assumptions, requirement gaps, and low-confidence interpretations that could change the outcome been resolved or explicitly deferred by the user? Apply Step 2.4; do not ask solely because certainty is below 100%.

If any gate fails, fix the plan before proceeding.

### 5. Track Tasks

1. Call `TaskCreate` for each work item in the plan.
2. Store task IDs for tracking during implementation.

### 6. Present to User

Present the plan and stop for user approval by default.

Before presenting, invoke the `humanizer` skill on the user-facing plan text. Preserve all technical identifiers, commands, paths, and task structure exactly.

Include:
- The numbered plan with task descriptions
- Files that will be modified
- **Approach recommendation** — the chosen approach, alternatives rejected,
  why the choice fits this codebase, and any external sources that materially
  changed the plan
- **Decisions and assumptions** — briefly list supported recommendations adopted in Step 2.4 with their rationale, and distinguish any decisions supplied by the user
- **Residual unknowns or open decisions** — anything that survived Step 2.4 (e.g., implementation details deferred to TDD); flag explicitly so the user can correct course
- Risks identified, with mitigation/fallback or explicit user acceptance

No clarification questions are needed when the requirements and inspected context support the plan without consequential gaps. The user can still review your recommendations when approving the plan.

When running in plan mode (e.g., via `dx` Phase 1 or `dxloop`), present the plan via `ExitPlanMode`. The user approves or rejects through the plan mode UI.

Do not begin implementation until the user approves the plan unless the active
lifecycle records a reasoned `plan.approval` waiver. A waiver means the plan
was not human-approved: preserve that distinction in the phase outcome and do
not write the normal approval marker or claim approval.

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
- Run the duplicate search in `prompts/issue-hygiene.md` with the final proposed
  title and outcome before every write; update a matching issue instead of
  creating another one.
- Apply the `humanizer` skill to every ticket title/body before creating it.
  Preserve file paths, commands, acceptance criteria, task numbering, risk
  labels, and verification commands exactly.
- Parent and sub-issue descriptions should contain the outcome, bounded scope,
  acceptance criteria, and essential constraints. Keep each sub-issue small
  enough for a single `dx <ticket>` lifecycle. Publish the approved approach,
  decisions, dependencies, risks, and verification in plan comments under Step 8.
- Linear: use the configured MCP or authenticated API. Use parent/child
  relations when the integration supports them.
- GitHub Issues: create issues with `gh issue create`. Reference the parent
  issue in each child body. Use existing labels only; do not create labels.

After write-back:
- Present the created ticket URLs and ask which ticket to implement first if
  more than one was created.
- For the chosen ticket, update session metadata:
  ```bash
  source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh" || exit 1
  SID="${DEX_SESSION_ID:-$(dx_session_id)}"
  dx_meta_write "$SID" "tracker_key=<KEY-OR-URL>" "ticket_number=<NUMBER-IF-GITHUB>"
  ```
- If the tracker provides a branch name for the chosen ticket, prepare it with
  the shared branch helper. This resumes an eligible branch already on origin
  and otherwise keeps a new branch local until Phase 2 creates its first
  implementation commit:
  ```bash
  BRANCH_SOURCE=$(dx_ticket_branch_prepare "<tracker-branch-name>" "$(pwd)") || exit 1
  dx_meta_write "$SID" "current_branch=$(git branch --show-current)"
  ```
- Move only the chosen implementation ticket to In Progress. Leave backlog
  sub-issues untouched unless the user explicitly says otherwise.

Do not write the Phase 1 ready marker until this gate is complete or explicitly
skipped by the user.

### 8. Update Ticket (if tracker configured)

Before writing the plan summary, invoke the `humanizer` skill on the draft copy. Preserve task numbering, file paths, commands, ticket IDs, and acceptance criteria exactly.

After plan approval or headless execution authorization, post a concise plan
comment on the existing or newly selected ticket. For parent/sub-issues created
in Step 7, put the overall sequence on the parent and each child's approach on
that child. Follow the publication contract in `prompts/issue-hygiene.md`: record
meaningful decisions and their reasons, link detailed plans where available,
and avoid repeating an unchanged plan. Correct the description and acceptance
criteria where needed; keep the planning record in comments.

If no tracker is configured or tracker write-back was skipped under Step 7, keep
the plan in the conversation and task list. Report any unavailable comment
operation or supported fallback without claiming publication succeeded.

Report the resulting issue and PR changes with the exact `Issue/PR work:` line
from `prompts/issue-hygiene.md`.

### 9. Mark Phase 1 Ready

After `ExitPlanMode` is approved, or after the headless run spec authorizes plan
execution, complete the tracker intake gate and ticket update steps above when
they apply. Before writing the ready marker, save the approved requirements for
the independent Phase 3 reviewers. Write a version 1 JSON object to
`dx_review_criteria_file` with exactly these fields:

```json
{
  "version": 1,
  "source": "approved-plan",
  "objectives": ["<one approved outcome per one-line string>"],
  "acceptance_criteria": ["<every approved criterion, without dropping constraints>"],
  "verification_requirements": ["<each concrete command or observable verification requirement>"]
}
```

Use `"headless-run-spec"` as `source` only when a headless run spec authorized
the plan without interactive approval. Keep each array non-empty. Copy the
approved plan faithfully: do not add requirements, omit edge cases, use
placeholders, or include implementation notes that were not approved. Write via
a temporary file and atomic `mv`, then validate the artifact before marking the
phase ready:

```bash
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh" || exit 1
SESSION_ID="${DEX_SESSION_ID:-$(dx_session_id)}"
CRITERIA_FILE="$(dx_review_criteria_file "$SESSION_ID")"
dx_review_criteria_valid "$CRITERIA_FILE" || exit 1
touch "$(dx_phase_ready_file "$SESSION_ID" 1)"
```

On the first Stop after the ready marker exists, the lifecycle controller seals
the canonical criteria hash as approval revision 1. A later replacement cannot
advance until the user approves it and Phase 2 explicitly rotates that seal.

Then print only a brief confirmation if needed and stop once so the hook can audit the plan and inject Phase 2 in the same Claude session. Do **not** tell the user to run `/dximplement`, do **not** ask whether to continue, and do **not** wait for another user prompt.

## Notes

- Keep plans minimal — only what's needed for the current ticket.
- Don't plan for hypothetical future work.
- If the ticket is small (e.g., a typo fix or config change), the plan can be a single task.
- For freeform `dx "<task>"` requests with a configured tracker, the user
  chooses whether the approved plan becomes tracker work before implementation
  starts.
