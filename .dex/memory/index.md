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
| review-quality | domains/review-quality.md | Phase 3 review waves; editing `agents/review-*.md`, `agents/self-reviewer.md`, `agents/review-verifier.md`, `prompts/review-wave.md`, `prompts/review.md`, `prompts/phase-audits/3-review*.md`, or `skills/dxreview*/` | active |
| workflow-operations | domains/workflow-operations.md | Lifecycle phase ownership, in-place vs worktree mode, and shared global config; editing `dx.sh` phase routing, `skills/dx*/SKILL.md`, `prompts/phase-audits/`, `hooks/phase-loop.sh`, `bin/install-settings.sh`, `bin/uninstall.sh`, `bin/uninit.sh`, `bin/config.sh`, or session/branch state code | active |
| security-guards | domains/security-guards.md | Editing `hooks/guard-handler.py`, `hooks/guards/*.md`, or `.dex/guards/*.md`; adding any new dangerous-command detector | active |
| architecture-decisions | domains/architecture-decisions.md | Adding or editing any skill, prompt, agent, or research harness; adding/reordering Claude Code hooks or editing `settings.json` hook arrays; reviewing portability across repositories | active |

## Entries

| ID | Domain | Summary |
|----|--------|---------|
| M-001 | review-quality | Review specialists are read-only and must not enable project memory |
| M-002 | workflow-operations | Each lifecycle phase owns its outputs strictly — no spillover |
| M-003 | workflow-operations | In-place lifecycle mode is a first-class peer to worktree mode |
| M-004 | workflow-operations | Dex-owned global state must be tracked separately from user state |
| M-005 | security-guards | Dangerous-command guards must use syntax-aware detection, not pattern matching |
| M-006 | architecture-decisions | Dex skills and prompts must be codebase-agnostic and discover tooling at runtime |
| M-007 | review-quality | Review waves must build context first, run deterministic checks before semantic review, isolate acceptance criteria, and only count true CLEAN waves |
| M-008 | architecture-decisions | Bash PreToolUse hooks run guards-first; guards fail closed, enhancement hooks (RTK) fail open |

## Retrieval Rules

- Load only entries with `Status: active` whose scope matches the task.
- Re-check evidence paths and recheck conditions before relying on an entry.
- A new lesson should not be added here directly — run `/dxsync` or `dx sync`
  so the lesson is verified and promoted through a reviewable diff.
