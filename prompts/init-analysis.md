# Dex Init — Codebase Analysis

Analyze this codebase and generate project-specific Dex configuration. Write all output files to `.dex/` in the current repo.

Apply `humanizer` to generated documentation and summaries. Please remove all
mannered prose. Preserve exact commands, paths, identifiers, and required structure.

## Step 1: Analyze the Codebase

Explore the repo to understand:

### Tech Stack
- Read: `package.json`, `Cargo.toml`, `pyproject.toml`, `go.mod`, `Gemfile`, `composer.json`, `Makefile`, `CMakeLists.txt`
- Identify: languages, web frameworks, test frameworks, ORM/database tools, build systems
- For monorepos: identify each workspace/package and its role

### Quality Gates
- Read `package.json` `scripts` section, `Makefile` targets, CI workflows (`.github/workflows/`)
- Find the exact commands for: formatting, linting, type checking, testing, code generation
- Note any "verify" or "ci" meta-commands that run everything

### Resources
- Which environment variable sets the test runner's worker count (`JEST_WORKERS`,
  `PYTEST_XDIST_AUTO_NUM_WORKERS`, a project-specific name)? Which Quality Gate
  commands are heavy — minutes long, or gigabytes while they run? Is there a
  command that runs only the tests covering given files? Omit the section when
  none has an answer: a wrong value misbudgets every session, absent means "Dex decides".

### Project Structure
- Is it a monorepo or single app?
- What directories contain what? (e.g., `src/`, `frontend/`, `backend/`, `packages/`)
- Where are tests? (co-located, `__tests__/`, `tests/`, `spec/`)
- What are the main entry points?

### Sensitive & Generated Files
- What should never be committed? (check `.gitignore`, known patterns)
- What config files get modified per-environment?

### CI Configuration
- Read `.github/workflows/*.yml` (or CircleCI, GitLab CI, etc.)
- Map CI job/step names to local commands

### Conventions
- Read existing `AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md`, `.editorconfig`, linter configs
- Note established patterns in the codebase (naming, file organization, test patterns)

## Step 2: Integrations

Integration configuration (ticket tracker, Figma, Sentry, Vercel, Grafana) is handled interactively by `dx config`, which runs after codebase analysis. Include the `## Integrations` section in the `.dex/dex.md` template below with placeholder values — it will be populated by the config step.

## Step 3: Generate Configuration

Write these files:

### `.dex/dex.md`

Read the existing `.dex/dex.md` before rewriting it. Preserve its Maintenance
section as is — custom values, `_none_`, omitted settings (a missing
`issue_label` deliberately leaves legacy ticket intake paused), or its absence.
Use the defaults below only for a file that did not exist; the init launcher
already wrote them for a new repository. Create no labels and enable no GitHub
workflows during analysis.

```markdown
# Dex — [Project Name]

## Tech Stack
[List languages, frameworks, and key tools discovered]

## Quality Gates
| Check | Command | Scope |
|-------|---------|-------|
| Format | [exact command] | [which packages/apps] |
| Lint | [exact command] | [which packages/apps] |
| Typecheck | [exact command] | [which packages/apps] |
| Test | [exact command] | [which packages/apps] |
| Generate | [exact command or "N/A"] | [what it generates] |
| All | [single command if available or "N/A"] | [full pipeline] |

## Resources

Optional, like `## Worktree Hooks`: a fenced flat YAML mapping Dex reads and
never writes. Omit a key with no real answer, and a section none of whose keys apply.

```yaml
# parallelism_env is set to the session's DX_TEST_JOBS budget at launch and
# under `dx run-gate`; heavy_commands take the host-wide lease (run them as
# `dx run-gate <command>`); targeted_tests runs only the tests for {files}.
parallelism_env: [WORKER_COUNT_VARIABLE]
heavy_commands:
  - [exact command]
targeted_tests: "[exact command] {files}"
full_gate: local  # or ci: the PR stays a draft and CI is the gate Phase 6 fixes through
# Review-tier derivation: extra sensitive globs, the size bounds for `trivial`
# and for a broad change, and the diff size above which thorough may use scouts.
review_sensitive_paths: ["**/migrations/**", "**/auth*"]
review_trivial_max_files: 10
review_trivial_max_lines: 500
review_broad_impact_files: 10
review_scout_min_files: 40
```

## Worktree Hooks

```yaml
# One shell command each, run in the worktree; see docs/worktree-hooks.md.
after_create: [exact command]      # stand this worktree's resources up
before_remove: [exact command]     # give them back; never blocks a removal
on_session_end: [exact command]    # release what the session alone held
orphan_resources: [exact command]  # names `dx worktree audit` and `dxclean` hand back
```

## Project Structure
[Brief description of directory layout and what each area contains]

## Files to Never Commit
[List files that should never be committed]

## Integrations

| Integration | Tool | Status |
|-------------|------|--------|
| Ticket tracker | [Linear MCP / GitHub Issues / none] | [enabled / not configured] |
| Design | Figma MCP | [enabled / not configured] |
| Error monitoring (Sentry) | Sentry MCP | [enabled / not configured] |
| Error monitoring (Honeybadger) | Honeybadger MCP | [enabled / not configured] |
| Deployments | Vercel MCP | [enabled / not configured] |
| Observability (Grafana) | Grafana MCP | [enabled / not configured] |
| Observability (Datadog) | Datadog MCP | [enabled / not configured] |

When an integration is "not configured", skip any workflow steps that reference it.
For ticket tracking: use the enabled tracker for all status updates, context gathering, and ticket lifecycle management.

## Reviewers

Request-type reviewers are attached before Phase 5 marks the PR ready. Phase 6
verifies readiness, re-requests them, and posts mention comments. Two types:
- `request` — native GitHub review request via Dex's `dx_maintenance_request_reviewer` helper
- `mention` — `@<handle>` posted as a PR comment (for AI agents that watch mentions)

These rows route notifications; they do not create approval requirements for
Phase 6. Dex handles actionable feedback, but it can finish without a submitted
review or approval. GitHub's target-branch rules still apply when a maintainer
merges the PR. Copilot reviews are `COMMENTED` by default; when admins enable
Copilot auto-approval, Dex reports the resulting `APPROVED` state without
making it a Phase 6 requirement.

When attaching request reviewers, normalize `Copilot`, `@copilot`, or Copilot
aliases to GitHub CLI's special `@copilot` reviewer value. Strip leading `@`
from normal GitHub usernames only. If GitHub says a reviewer is not requestable
for the repository, Dex records a warning and continues.

| Handle | Type | Notes |
|--------|------|-------|
| @[auth-user] | request | Authenticated GitHub user (auto-detected by `dx config`) |
| Copilot | request | GitHub Copilot review |

If the table is empty or only contains `_none_` rows, Phase 6 skips review-request and mention steps. Edit rows directly or rerun `dx config`.

## Rules
[Reference any rule files generated in .dex/rules/]
[Reference `.dex/review-rules.md` if generated]
[Reference `.dex/memory/index.md` if generated]

## Memory
`.dex/memory/index.md` maps durable repo memory to paths, phases, and
workflows. Agents should load only scoped active entries and verify them against
current code before relying on them.

## Maintenance

| Setting | Value |
|---------|-------|
| enabled | true |
| branch_prefix | dex/maintain/ |
| label | dex-maintenance |
| default_mode | report |
| schedule_mode | report |
| issue_mode | report |
| issue_label | dex-execute |
| issue_queue_limit | 10 |
| max_prs | 1 |
| low_risk_fix_categories | docs, rules, guards, memory, tests |
| copilot_review | true |
| auto_merge | false |
| auto_merge_method | squash |

`fix-scoped` may only patch the configured low-risk categories above, plus
verification updates in matching test files, unless a repo maintainer expands
this table. Publication is handled by the DX maintain
CLI wrapper after the provider exits so GitHub write credentials are not exposed
to the agent process.

## Workflow
Run `/dex` to begin the autonomous ticket lifecycle.
Run `/dxsync` or `dx sync` to refresh repo memory after significant repo,
workflow, review, or CI changes.
```

### `.dex/rules/*.md` (one per major area of the codebase)

For each significant area (backend, frontend, shared library), generate a rule
file with the architecture patterns, naming conventions, testing patterns and
expectations, common pitfalls, and framework-specific conventions actually
observed in that area. Name them descriptively: `backend.md`, `api.md`, `database.md`.

Only generate rules for areas that have enough established patterns to document. Don't generate rules for trivial or obvious things. Each rule file should be genuinely useful for someone working in that area.

### `.dex/review-rules.md` (path-specific review focus)

Generate this file when the codebase has meaningful path-specific review focus,
to tell Dex review waves where domain sweeps should spend attention. Include
concise sections for applicable areas: frontend/UI (accessibility, responsive
layout, state/data contracts, UI capture expectations); backend/API (authn/authz,
input validation, contract compatibility, observability); database/migrations
(additive safety, indexes, rollback risk, generated types); CI/devops (workflow
triggers, secrets, caches, artifacts, deploy gates); shell/tooling (language
boundaries, quoting, cleanup, syntax checks); generated/docs (freshness and
stale-documentation risk). Do not duplicate generic criteria from
`prompts/review.md`; capture only project-specific focus by path or subsystem.

### `.dex/memory/index.md`

Create `.dex/memory/index.md` as the compact retrieval map for durable repo
memory: which domain files future agents load for specific paths, phases,
commands, or workflows. Initial repos often lack the evidence for durable
memory; then create the index with an explicit empty state:

```markdown
# Dex Memory Index

No durable repo memory has been promoted yet.

Run `/dxsync` or `dx sync` after repeated review comments, CI failures,
maintenance runs, or durable workflow lessons create evidence worth preserving.

## Domains

| Domain | File | Loads For | Status |
|--------|------|-----------|--------|
```

If the repo already contains strong, current, evidenced conventions, create
focused memory files under `.dex/memory/domains/` and reference them from the
index. Let the repo shape the domains, named for how future agents need context
(`review-quality`, `verification-ci`, `architecture-decisions`, `security-guards`,
`workflow-operations`, or a subsystem such as `auth`, `migrations`, `frontend-ui`);
never a catch-all such as `misc`, `general`, or `learnings` — a lesson without a
clear domain waits until `/dxsync` has enough evidence to organize it. Promote
only durable lessons evidenced in current files, docs, tests, CI, or git history;
never speculative memory.

Memory entries must include `Domain`, `Status`, `Scope`, `Applies to phases`,
`Applies to paths`, `Last verified`, `Recheck when`, `Lesson`, `Evidence`, and
`Future agent behavior`.

Do not create `.dex/learnings.md`. Session observations belong in external
Dex run state until `/dxsync` promotes them through a reviewable diff.

### `.dex/guards/*.md` (project-specific guards)

Generate guards for:
- **Files that should never be committed** — environment-specific files, generated configs. Use `event: commit`, `action: block`.
- **Framework-specific safety patterns** — e.g., unprotected endpoints, raw SQL, missing validation. Use `event: file`, `action: warn`.

Guard format:
```markdown
---
name: guard-name
enabled: true
event: bash|file|commit
pattern: regex-pattern
action: warn|block
---

Message shown when the guard triggers.
```

Only generate guards that are specific to THIS project. Generic guards (destructive commands, sensitive files, hardcoded secrets) already ship with Dex.

## Step 4: Update Instruction Entrypoints

`.dex/AGENTS.md` is the source of truth for generated Dex project context and
contains only `@dex.md`; `.dex/CLAUDE.md` stays a compatibility pointer whose
only content is `@AGENTS.md`.

## Guidelines

- Be specific and accurate. Use exact commands and paths from the actual codebase.
- Don't generate speculative content. If you're unsure about a convention, skip it.
- Keep rules concise. Developers will read these alongside their work.
- Keep memory durable and evidenced. If a lesson is not current, scoped, and
  useful to future agents, leave it out.
- Test any commands you reference by checking they exist (in Makefile, package.json, etc.).
- For monorepos, document per-package quality gates, not just top-level ones.
