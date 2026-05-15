# DKSync Memory Plan

Doyaken should become a repo-resident maintenance agent that learns the
codebase, turns repeated experience into reviewable knowledge, and uses that
knowledge to run safer autonomous work.

This document scopes the first part of that idea: durable repo memory and the
`dk sync` learning flow. The aim is not to make Doyaken remember everything. The
aim is to preserve only knowledge that is important, permanent, durable,
evidenced, and useful to future agents.

`dk sync` should be usable by humans and by agents. Humans run it intentionally
after setup or after significant repo changes. Agents can trigger the same
learning flow from prompts or lifecycle phases when they discover durable
patterns, but those agent-triggered runs must still produce a reviewable diff
before anything becomes trusted repo memory.

## Product Shape

Doyaken has two modes that should reinforce each other:

- A tool developers run day to day to plan, implement, review, and complete
  tickets.
- An autonomous workflow that can run in the background as trust increases.

Memory is the bridge between those modes. Day-to-day work produces observations
about the repo. `dk sync` promotes the durable lessons into repo-owned context.
Background agents then use that context to operate more safely and with less
human review burden.

## Goals

- Make `dk init` and `dk sync` share the same learning pipeline.
- Treat `dk sync` as the developer-friendly way to refresh project context after
  init.
- Store agent-friendly project knowledge in focused files, not a broad wiki.
- Distinguish untrusted observations from trusted repo memory.
- Promote repeated lessons into rules, guards, skills, or memory only when there
  is evidence.
- Capture repo-wide engineering philosophy and decision frameworks, not
  individual personality profiles.
- Support Claude hooks as a first-class path while keeping a provider-neutral
  prompt fallback for Codex and other agents.

## Non-Goals

- Do not store everything the agent sees.
- Do not write personal memories such as "reviewer X dislikes Y".
- Do not make unreviewed observations active instructions.
- Do not create a large developer wiki in the first version.
- Do not rely only on Claude hooks for correctness.
- Do not let background learning silently change active project behavior without
  a reviewable diff.

## Command Model

`dk init` should run the learning pipeline for a repo that does not yet have
Doyaken project context.

`dk sync` should run the same pipeline for a repo that already has Doyaken
context. It is an alias in spirit, but the user intent is different:

| Command | User Intent | Expected Behavior |
|---------|-------------|-------------------|
| `dk init` | Set this repo up for Doyaken | Create missing `.doyaken/` files, discover quality gates, generate initial rules and context |
| `dk sync` | Refresh what Doyaken knows | Re-read current repo state, recent work, reviews, CI, and update candidate memory/rules |
| `/dksync` | Refresh inside an agent session | Run the same learning prompt in-session, usually producing a reviewable diff |

Implementation should keep one underlying pipeline and expose both command
names. That avoids drift while giving developers a natural command to run after
setup.

For testability and safe rollout, the implementation should also support:

- `--dry-run`: print the proposed promotions and retrieval changes without
  writing files.
- `--state-dir <path>`: read observations and episodes from an explicit test
  directory.
- `--since <ref|date>`: limit repository and review-history scanning.
- `--no-pr`: write local changes only, even for scheduled runs.
- `--trace-retrieval <prompt-or-path>`: explain which memory entries would load
  for a task or changed file set.
- `--include-working-tree`: allow uncommitted working-tree changes to be used as
  promotion evidence. Default is false; uncommitted changes normally produce
  candidate observations only.

These flags are not product polish. They are how we prove the trust boundary
between raw observations and durable memory.

## Memory Vocabulary

| Term | Trusted? | Stored Where | Purpose |
|------|----------|--------------|---------|
| Observation | No | External run state or draft report | A raw fact noticed during work, review, CI, or repo scanning |
| Episode | No | External run state | A summary of one run, ticket, failure, review cycle, or sync pass |
| Candidate Learning | Partially | Draft PR / generated diff | A proposed durable lesson with evidence attached |
| Durable Memory | Yes | `.doyaken/memory/domains/*.md` | Stable repo knowledge future agents may use |
| Rule | Yes | `.doyaken/rules/*.md` | Scoped instruction that should affect future work |
| Guard | Yes | `.doyaken/guards/*.md` | Enforceable rule for dangerous or repeated failure patterns |
| Skill | Yes | Doyaken skill or future project skill | Repeatable workflow that should be invoked intentionally |

The promotion path should be:

```
observation -> episode -> candidate learning -> durable memory/rule/guard/skill
```

Each promotion step requires stronger evidence. Raw observations can be useful,
but they are shallow and should not be trusted.

## Proposed Repo Files

The first version should prefer compact, retrieval-friendly files:

```
.doyaken/
  doyaken.md
  AGENTS.md
  rules/
    architecture.md
    testing.md
    review.md
  guards/
    ...
  memory/
    index.md
    domains/
      architecture-decisions.md
      review-quality.md
      verification-ci.md
      workflow-operations.md
```

`memory/index.md` should be a map, not a dump. It should tell the agent which
memory files matter for which paths, languages, commands, or workflows.

Memory should be organized around domains chosen for retrieval. The agent may
create repo-specific domains, but each domain must describe a coherent decision
area future agents will recognize. Good domains include `review-quality`,
`verification-ci`, `architecture-decisions`, `security-guards`,
`workflow-operations`, or subsystem names such as `auth`, `migrations`, or
`frontend-ui`. Avoid catch-all files such as `general.md`, `misc.md`, or
`learnings.md`.

The index should use a compact domain table:

```markdown
| Domain | File | Loads For | Status |
|--------|------|-----------|--------|
| auth | domains/auth.md | backend/auth/**, backend/routes/**; plan/review auth changes | active |
```

Raw run state should stay outside the repo, for example under
`~/.claude/.doyaken-learning/` or a future provider-neutral Doyaken state
directory such as `$DK_LEARNING_DIR`. If a raw episode becomes useful, `dk sync`
should summarize it into a candidate learning in a branch or draft PR.

Doyaken should not create `.doyaken/learnings.md`. Fresh repos should use the
new memory system from the start: raw session observations live in external run
state, and durable lessons live in `.doyaken/memory/` only after sync promotes
them.

## Memory Entry Shape

Durable memory entries should be structured enough for agents to retrieve and
challenge:

```markdown
## M-001: Auth changes require object-level authorization tests

Domain: auth
Status: active
Scope: backend/auth/**, backend/routes/**
Applies to phases: plan, implement, review
Applies to paths: backend/auth/**, backend/routes/**
Last verified: 2026-05-15
Recheck when: auth middleware, route ownership, or role policy changes

Lesson:
State-changing auth routes must include tests that prove the caller owns or is
allowed to mutate the target object. Login alone is not enough.

Evidence:
- PR #123 fixed an account ownership bypass in backend/routes/accounts.py.
- PR #147 review comments requested the same missing object-level check.
- Existing tests in backend/auth/test_policies.py use this pattern.

Future agent behavior:
- During planning, add an acceptance criterion for object-level authorization.
- During review, flag auth route changes without ownership tests.
- Prefer adding tests before changing the route.
```

Important constraints:

- Every entry needs evidence.
- Every entry needs scope.
- Every entry needs a recheck condition.
- Entries should be retired or rewritten when the codebase changes.

## Promotion Policy

`dk sync` should promote a lesson only when it passes all of these gates:

| Gate | Required Evidence | Reject When |
|------|-------------------|-------------|
| Recurrence | Seen across multiple PRs, commits, files, failures, or review cycles | The observation is a one-off |
| Currentness | Still matches current code, tests, docs, and CI | The codebase has moved on |
| Scope | Applies to a clear path, subsystem, command, or workflow | It is vague or repo-wide without proof |
| Actionability | Future agents can change planning, review, tests, or guards because of it | It is interesting but does not affect behavior |
| Verifiability | Evidence can be rechecked from repo files, git history, CI, or review artifacts | It relies on memory or opinion |
| Safety | It does not encode personal profiles, secrets, or speculative strategy | It describes individual preferences or sensitive data |

Promotion targets should be chosen conservatively:

- Use `.doyaken/memory/domains/*.md` for durable context and decision frameworks.
- Use `.doyaken/rules/*.md` when future agents should actively follow the
  lesson while planning, implementing, or reviewing.
- Use `.doyaken/guards/*.md` only when a pattern is enforceable with a narrow
  detector and acceptable false-positive rate.
- Use a skill only when there is a repeatable workflow with multiple steps,
  inputs, outputs, and quality gates.

Rejected observations should still be listed in the sync report. This lets a
human see that the agent considered them without letting them silently become
instructions.

## Sync Pipeline

`dk sync` should run as a loop with explicit phases:

1. **Orient**
   - Read `.doyaken/AGENTS.md`, `.doyaken/doyaken.md`, existing rules,
     review-rules, guards, and memory index.
   - Detect repo languages, quality gates, CI, package managers, and test
     commands.

2. **Observe**
   - Inspect recent commits, recent `fix:` history, changed hot spots, CI
     failures, review comments, merged PRs, and recurring manual interventions.
   - Record raw observations outside trusted memory.

3. **Cluster**
   - Group repeated observations into candidate lessons.
   - Prefer lessons that recur across multiple files, PRs, or failures.

4. **Verify**
   - Check candidate lessons against the codebase.
   - Read surrounding files, grep for patterns, inspect tests, and compare with
     current rules.
   - Drop lessons that are one-off, speculative, stale, or contradicted by the
     repo.

5. **Promote**
   - Update `.doyaken/memory/domains/*.md` for durable context.
   - Update `.doyaken/rules/*.md` for instructions future agents should follow.
   - Propose `.doyaken/guards/*.md` only when the pattern is enforceable.
   - Propose skill changes only when a repeatable workflow is clear.

6. **Review**
   - Produce a reviewable diff.
   - Explain what was promoted, what was rejected, and why.
   - Prefer a draft PR for unattended or scheduled sync runs.

7. **Load**
   - Ensure future Doyaken prompts can load only the relevant memory slices.
   - Update the memory index when new files or scopes are added.

## Agent Trigger Points

Agent-triggered sync should happen at durable learning points, not after every
tool call:

- After `dk init`, to create initial memory scaffolding when enough repo context
  exists.
- After a lifecycle run that changed `.doyaken/rules/`, `.doyaken/guards/`, or
  project quality gates.
- After repeated review comments or CI failures reveal the same class of issue.
- After a background maintenance run finds a durable repo lesson.
- Before scheduled overnight maintenance, so the background agent starts from
  fresh context.

Agent-triggered sync should not block normal ticket progress unless the current
task explicitly changed project conventions or safety boundaries. In ordinary
ticket work, the agent should record an observation and leave promotion to a
later `dk sync`.

## Hooks And Fallbacks

Claude hooks should be used when available because they are efficient and
already fit Doyaken's architecture:

- `SessionStart`: load relevant memory index entries for the current branch,
  ticket, and changed files.
- `UserPromptSubmit`: add narrow context for the prompt and record that a manual
  intervention occurred.
- `PreCompact`: remind the agent how to reload scoped repo memory.
- `Stop` or `SessionEnd`: summarize the episode into untrusted run state.
- `PreToolUse`: enforce guards, not fuzzy memory.

Codex and other providers do not support the same hook model. Doyaken should
therefore also support prompt-level pseudo-hooks:

- A pre-prompt section that says how to retrieve scoped memory.
- A post-task audit section that says how to record candidate observations.
- A sync prompt that promotes observations only through a reviewable diff.

The fallback should be less efficient, but behaviorally equivalent where it
matters.

## Retrieval Rules

Future agents should not load all memory by default. They should:

- Read `.doyaken/memory/index.md`.
- Match the task, changed files, language, and phase to relevant scopes.
- Load only the relevant domain files under `.doyaken/memory/domains/`.
- Treat memory as useful context, not as proof.
- Re-verify old lessons against current code before making a finding.

This keeps memory helpful without turning it into stale prompt ballast.

`--trace-retrieval` should produce a small load report so humans can verify the
right memories are surfaced:

```markdown
# Doyaken Memory Load Report

Task: update backend/routes/accounts.py
Phase: review

Loaded:
- M-001 from .doyaken/memory/domains/auth.md
  Reason: scope matches backend/routes/** and phase review

Skipped:
- M-004 from .doyaken/memory/domains/workflow-operations.md
  Reason: workflow scope is release automation, not backend routes

Rejected:
- M-007 from .doyaken/memory/domains/architecture-decisions.md
  Reason: status is needs-recheck
```

This report is part of the product contract. It gives developers a concrete way
to inspect whether memory is helping or polluting the agent context.

## Review Philosophy

Memory about people should roll up into repo-wide engineering judgment:

- Acceptable: "This repo values small, reviewable PRs with explicit verification
  evidence."
- Acceptable: "Auth and permissions changes need threat-model notes and tests."
- Acceptable: "Review history shows repeated migration rollback issues, so
  migration plans need rollback coverage."
- Not acceptable: "Reviewer Alice dislikes abstractions."
- Not acceptable: "Reviewer Bob always asks for tests."

The durable output should describe how the repo works, not profile individuals.

## First Version Requirements

V1 should be considered useful when:

- `dk init` and `dk sync` share one learning pipeline.
- `dk sync` can run on this repo and produce a reviewable diff.
- The diff is limited to `.doyaken/` context files unless explicitly configured.
- Raw observations are not loaded as trusted memory.
- At least one memory file and one rule file can be generated or refreshed.
- Existing Doyaken phases can read relevant memory without loading everything.
- The flow works without Claude hooks by using prompt-level pre/post
  instructions.
- `dk sync --dry-run` can explain proposed promotions and rejected observations.
- `dk sync --trace-retrieval` can explain which memories would load for a task,
  path, or phase.

## Manual Test Plan

The memory system needs manual testing before automated tests can be trusted,
because the hard part is judgment: what gets promoted, what stays untrusted, and
what context future agents actually receive.

Manual testing should use a fixture repo and an explicit learning state
directory. Do not test first against a real production repo, because that makes
it hard to tell whether a promotion is correct or just plausible.

### Fixture Setup

Create a small git repo with enough structure to exercise scoped memory:

```bash
tmpdir=$(mktemp -d)
cd "$tmpdir"
git init
mkdir -p backend/routes backend/auth tests .doyaken/rules .doyaken/memory
touch backend/routes/accounts.py backend/auth/policies.py tests/test_auth.py
cat > .doyaken/AGENTS.md <<'EOF'
@doyaken.md
EOF
cat > .doyaken/doyaken.md <<'EOF'
# Doyaken Test Repo

## Quality Gates
| Check | Command | Scope |
|-------|---------|-------|
| Test | pytest | all |

## Rules
@rules/backend.md
EOF
cat > .doyaken/rules/backend.md <<'EOF'
# Backend Rules

Routes live in backend/routes and authorization helpers live in backend/auth.
EOF
git add .
git commit -m "chore: seed fixture repo"
```

Seed an explicit learning directory with controlled episodes. Use markdown so a
human can inspect it easily:

```bash
export DK_LEARNING_DIR="$tmpdir/learning-state"
mkdir -p "$DK_LEARNING_DIR/episodes"
```

Create episodes for three categories:

- Two or more episodes where auth route changes missed object-level
  authorization tests, with evidence pointing to `backend/routes/**` and
  `tests/test_auth.py`.
- One episode containing a style preference or naming nit that appears only
  once.
- One stale episode that contradicts current repo evidence.

The expected result is that only the repeated, current, scoped auth lesson is
promoted.

### Scenario Matrix

Run each scenario in isolation and inspect the proposed diff or dry-run report:

| Scenario | Input | Expected Result |
|----------|-------|-----------------|
| Initial sync | Fixture repo with no episodes | Creates or refreshes minimal memory index; no speculative lessons |
| Repeated auth lesson | Two auth episodes with matching evidence | Promotes one durable memory entry and, if useful, updates backend rules |
| One-off style note | Single naming preference episode | Lists under rejected observations; no memory/rule change |
| Stale lesson | Episode contradicted by current files | Lists as rejected or `needs-recheck`; does not load as active memory |
| Missing evidence | Episode claims a pattern but paths/commits cannot be verified | Rejected with missing-evidence reason |
| Uncommitted evidence | Lesson appears only in the working tree | Rejected unless `--include-working-tree` is set |
| Guard candidate | Repeated enforceable unsafe pattern | Proposes a guard only if the detector can be narrow |
| Skill candidate | Repeated multi-step workflow | Reports candidate skill; does not create global skill without explicit review |
| Idempotency | Run sync twice with same inputs | Second run produces no meaningful diff |
| Hookless fallback | Run provider-neutral prompt flow | Produces the same promotions as hook-enabled flow |
| Retrieval trace | Trace `backend/routes/accounts.py` in review phase | Loads auth memory, skips unrelated memory, rejects inactive memory |

### Manual Commands

The intended manual test commands are:

```bash
dk sync --dry-run --state-dir "$DK_LEARNING_DIR" --since HEAD~20
dk sync --state-dir "$DK_LEARNING_DIR" --no-pr
dk sync --trace-retrieval backend/routes/accounts.py --phase review
dk sync --trace-retrieval docs/README.md --phase plan
```

The same test can also be performed inside an existing agent session by invoking
`/dksync` with:

- the fixture repo path,
- the explicit learning-state path,
- the scenario being tested,
- the instruction to produce a diff only under `.doyaken/`.

The important part is that every scenario has an expected diff and an expected
rejection list before the agent runs.

### Expected Diff For The Auth Scenario

The repeated auth scenario should produce a small diff like:

```text
.doyaken/memory/index.md
.doyaken/memory/domains/auth.md
.doyaken/rules/backend.md
```

It should not modify production code. The new memory entry should include:

- Status: `active`
- Domain: `auth`
- Scope: `backend/routes/**`, `backend/auth/**`, relevant tests
- Applies to phases and paths
- Evidence: at least two episode references plus current repo paths
- Recheck condition: auth route, ownership, or policy changes
- Future agent behavior: planning and review expectations

The backend rule update should be shorter than the memory entry. Rules should
tell agents what to do; memory should explain why the rule exists.

### Retrieval Verification

After promotion, manually test surfacing:

1. Trace a backend route task.
   - Expected: auth memory loads.
   - Expected: backend rules load.
   - Expected: unrelated workflow memory does not load.

2. Trace a documentation-only task.
   - Expected: auth memory does not load.
   - Expected: only general project context loads.

3. Mark the auth memory `Status: needs-recheck`.
   - Expected: trace reports it under `Rejected` or `Skipped`, not `Loaded`.

4. Narrow the scope from `backend/routes/**` to `backend/routes/admin/**`.
   - Expected: normal account routes stop loading that memory.

This verifies that Doyaken keeps the right memories without turning memory into
always-on prompt ballast.

### Retention And Retirement Verification

Manual testing should also prove that memory can be removed or weakened:

1. Delete or change the evidence paths in the fixture repo.
2. Run `dk sync --dry-run`.
3. Confirm the entry is marked `needs-recheck`, rewritten with new evidence, or
   proposed for retirement.
4. Confirm inactive memory does not load in `--trace-retrieval`.
5. Restore evidence and confirm sync can reactivate the memory with an updated
   `Last verified` date.

Memory that cannot be retired will eventually become worse than no memory.

### Pass Criteria

The manual test passes only if all of these are true:

- Repeated, current, scoped lessons are promoted.
- One-off observations are rejected.
- Stale or contradicted observations are rejected or marked `needs-recheck`.
- Raw episodes never become loaded instructions.
- Retrieval traces load relevant memory and skip unrelated memory.
- A second sync with unchanged inputs is idempotent.
- Hookless prompt flow and hook-enabled flow produce equivalent trusted outputs.
- Generated rules are shorter and more directive than generated memory.
- No reviewer-specific personal profile is created.
- Every promoted memory entry has evidence, scope, status, recheck condition, and
  future agent behavior.

## Open Questions

- How much initial memory should `dk init` generate beyond the empty memory
  index when evidence is thin?
- Should scheduled `dk sync` open draft PRs automatically, or only write local
  branches until the user opts in?
- Should project-specific skills live under `.doyaken/skills/`, or should
  Doyaken continue to keep all skills in the global `skills/` directory?
- How should old memory be retired: explicit review, stale-date revalidation, or
  automatic removal when evidence disappears?
- What is the smallest memory index format that remains useful across Claude and
  Codex?
