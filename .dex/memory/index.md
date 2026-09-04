# Dex Memory Index

This index maps durable repo memory to scopes, paths, and phases. Future agents
should read this file first, then load only memory entries whose scope matches
the current task, changed files, command, or phase. Memory is context, not
proof — re-verify entries against the current code before acting on them.

Promotion of new memory entries goes through `/dxsync` or `dx sync`. Raw
session observations are not trusted memory and must not be loaded from this
directory until promoted via a reviewable diff.

## Domains

| Domain | File | Loads For | Status |
|--------|------|-----------|--------|
| review-quality | domains/review-quality.md | Phase 3 review waves; clean-pass and wave-budget policy; editing `prompts/review-wave.md`, `prompts/review.md`, `prompts/review-risk-assessment.md`, `prompts/phase-audits/3-review*.md`, `lib/review*.sh`, or `skills/dxreview*/` | active |
| workflow-operations | domains/workflow-operations.md | Lifecycle phase ownership, in-place vs worktree mode, provider-session resume, runtime leases, and shared global config; editing `dx.sh` phase routing, `bin/dxcodex.sh`, `skills/dx*/SKILL.md`, `prompts/phase-audits/`, lifecycle hooks, install/config scripts, or session/runtime/branch state code | active |
| security-guards | domains/security-guards.md | Editing `hooks/guard-handler.py`, `hooks/shell_parse.py`, `hooks/git-commit-target.py`, `hooks/guards/*.md`, or `.dex/guards/*.md`; adding any new dangerous-command detector | active |
| architecture-decisions | domains/architecture-decisions.md | Adding or editing any skill, prompt, agent, or research harness; adding/reordering Claude Code hooks or editing `settings.json` hook arrays; reviewing portability across repositories | active |
| verification-ci | domains/verification-ci.md | Editing `tests/`, `.github/workflows/ci.yml`, test assertions, manifest rows, runner lanes, or static-check coverage; implementation, review, verification, and maintenance | active |

## Entries

| ID | Domain | Summary |
|----|--------|---------|
| M-001 | review-quality | Review specialists are read-only and must not enable project memory |
| M-002 | workflow-operations | Phase gates stay owned while Git history follows the work |
| M-003 | workflow-operations | In-place lifecycle mode is a first-class peer to worktree mode |
| M-004 | workflow-operations | Dex-owned global state must be tracked separately from user state |
| M-005 | security-guards | Dangerous-command guards must use syntax-aware detection, not pattern matching |
| M-006 | architecture-decisions | Dex skills and prompts must be codebase-agnostic and discover tooling at runtime |
| M-007 | review-quality | Review waves isolate context, count only true CLEAN waves, and keep soft wave budgets separate from assurance |
| M-008 | architecture-decisions | Bash PreToolUse hooks run guards-first and preserve block, warning, and enhancement failure contracts |
| M-009 | verification-ci | Test manifest rows, runner lanes, and portable assertions are executable contracts |
| M-010 | workflow-operations | Runtime lock lineage gates live-lease mutations, not durable reads, restart, or recovery |
| M-011 | workflow-operations | Interactive lifecycle resumes use exact provider conversation IDs |

## Retrieval Rules

- Load only entries with `Status: active` whose scope matches the task.
- Re-check evidence paths and recheck conditions before relying on an entry.
- A new lesson should not be added here directly — run `/dxsync` or `dx sync`
  so the lesson is verified and promoted through a reviewable diff.
