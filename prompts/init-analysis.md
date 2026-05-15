# Doyaken Init — Codebase Analysis

Analyze this codebase and generate project-specific Doyaken configuration. Write all output files to `.doyaken/` in the current repo.

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

Integration configuration (ticket tracker, Figma, Sentry, Vercel, Grafana) is handled interactively by `dk config`, which runs after codebase analysis. Include the `## Integrations` section in the `.doyaken/doyaken.md` template below with placeholder values — it will be populated by the config step.

## Step 3: Generate Configuration

Write these files:

### `.doyaken/doyaken.md`

```markdown
# Doyaken — [Project Name]

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

Reviewers assigned when the PR is marked ready for review (Phase 6). Two types:
- `request` — `gh pr edit --add-reviewer <handle>` (humans, Copilot, anything GitHub supports)
- `mention` — `@<handle>` posted as a PR comment (for AI agents that watch mentions)

| Handle | Type | Notes |
|--------|------|-------|
| @[auth-user] | request | Authenticated GitHub user (auto-detected by `dk config`) |
| Copilot | request | GitHub Copilot review |

If the table is empty or only contains `_none_` rows, Phase 6 skips review-request and mention steps. Edit rows directly or rerun `dk config`.

## Rules
[Reference any rule files generated in .doyaken/rules/]
[Reference `.doyaken/review-rules.md` if generated]
[Reference `.doyaken/memory/index.md` if generated]

## Memory
`.doyaken/memory/index.md` maps durable repo memory to paths, phases, and
workflows. Agents should load only scoped active entries and verify them against
current code before relying on them.

## Workflow
Run `/doyaken` to begin the autonomous ticket lifecycle.
Run `/dksync` or `dk sync` to refresh repo memory after significant repo,
workflow, review, or CI changes.
```

### `.doyaken/rules/*.md` (one per major area of the codebase)

For each significant area (e.g., backend, frontend, shared library), generate a rule file with:
- Architecture patterns specific to this codebase
- Naming conventions observed in existing code
- Testing patterns and expectations
- Common pitfalls or patterns to follow
- Framework-specific conventions (based on what's actually used)

Name them descriptively: `backend.md`, `frontend.md`, `api.md`, `database.md`, etc.

Only generate rules for areas that have enough established patterns to document. Don't generate rules for trivial or obvious things. Each rule file should be genuinely useful for someone working in that area.

### `.doyaken/review-rules.md` (path-specific review focus)

Generate this file when the codebase has meaningful path-specific review focus.
Use it to tell Doyaken review waves where specialist reviewers should spend
attention. Include concise sections for applicable areas such as:

- frontend/UI paths: accessibility, responsive layout, state/data contracts,
  UI capture expectations
- backend/API paths: authn/authz, input validation, contract compatibility,
  observability
- database/migration paths: additive migration safety, indexes, rollback risk,
  generated types
- CI/devops paths: workflow triggers, secrets, caches, artifacts, deploy gates
- shell/tooling paths: shell language boundaries, quoting, cleanup, syntax checks
- generated/docs paths: freshness checks and stale-documentation risk

Do not duplicate generic review criteria from `prompts/review.md`; capture only
project-specific focus by path or subsystem.

### `.doyaken/memory/index.md`

Create `.doyaken/memory/index.md` as the retrieval map for durable repo memory.
This file should be compact. It tells future agents which memory domain files to
load for specific paths, phases, commands, or workflows.

Initial repos often do not have enough evidence for durable memory. In that
case, create the index with an explicit empty state:

```markdown
# Doyaken Memory Index

No durable repo memory has been promoted yet.

Run `/dksync` or `dk sync` after repeated review comments, CI failures,
maintenance runs, or durable workflow lessons create evidence worth preserving.

## Domains

| Domain | File | Loads For | Status |
|--------|------|-----------|--------|
```

If the repo already contains strong, current, evidenced conventions, create
focused memory files under `.doyaken/memory/domains/` and reference them from the
index. Let the repo shape the domains: choose names based on how future agents
need context, such as `review-quality`, `verification-ci`,
`architecture-decisions`, `security-guards`, `workflow-operations`, or a
repo-specific subsystem such as `auth`, `migrations`, or `frontend-ui`.

Avoid catch-all domains such as `misc`, `general`, or `learnings`. If a lesson
does not fit a clear domain, leave it out until `/dksync` has enough evidence to
organize it.

Only promote durable lessons that have evidence in current files, docs, tests,
CI, or git history. Do not create speculative memory.

Memory entries must include:

- `Domain`
- `Status`
- `Scope`
- `Applies to phases`
- `Applies to paths`
- `Last verified`
- `Recheck when`
- `Lesson`
- `Evidence`
- `Future agent behavior`

Do not create `.doyaken/learnings.md`. Session observations belong in external
Doyaken run state until `/dksync` promotes them through a reviewable diff.

### `.doyaken/guards/*.md` (project-specific guards)

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

Only generate guards that are specific to THIS project. Generic guards (destructive commands, sensitive files, hardcoded secrets) already ship with Doyaken.

## Step 4: Update Instruction Entrypoints

Ensure `.doyaken/AGENTS.md` is the source of truth for generated Doyaken project context and imports the generated doyaken.md:

```
@doyaken.md
```

Ensure `.doyaken/CLAUDE.md` remains a compatibility pointer to `.doyaken/AGENTS.md`:

```
@AGENTS.md
```

## Guidelines

- Be specific and accurate. Use exact commands and paths from the actual codebase.
- Don't generate speculative content. If you're unsure about a convention, skip it.
- Keep rules concise. Developers will read these alongside their work.
- Keep memory durable and evidenced. If a lesson is not current, scoped, and
  useful to future agents, leave it out.
- Test any commands you reference by checking they exist (in Makefile, package.json, etc.).
- For monorepos, document per-package quality gates, not just top-level ones.
