# Architecture Decisions

Durable design constraints that span Dex's primitives — skills, agents,
prompts, hooks, and the research harness.

## M-006: Dex skills and prompts must be codebase-agnostic and discover tooling at runtime

Domain: architecture-decisions
Status: active
Scope: skills/*/SKILL.md, prompts/*.md, prompts/phase-audits/*.md, prompts/init-analysis.md, research harness, agents/*.md
Applies to phases: plan, implement, review, verify, complete (any phase that loads skills or prompts)
Applies to paths: skills/, prompts/, agents/
Last verified: 2026-05-15
Recheck when: a new shared prompt is introduced, the research harness changes, or a skill encodes per-repo quality-gate commands

Lesson:
Dex is intended to work in any git repository, across languages and
frameworks. Skills, agents, prompts, and the research harness must avoid
framework-specific examples, hardcoded test/lint commands, and assumptions about
project structure. They must discover quality gates (format, lint, typecheck,
test, generate), package managers, ticket trackers, and integration tooling at
runtime — typically from `.dex/dex.md`, manifests (`package.json`,
`Cargo.toml`, `pyproject.toml`, `go.mod`), and CI config — rather than
hardcoding a stack.

Evidence:
- `7dc56c8 fix(research): make harness and prompts codebase agnostic`
  configures local git identity for generated research workspaces and replaces
  framework-specific shared prompt examples with neutral guidance.
- `29a0e70 feat(init): use AGENTS as generated context source` keeps generated
  context provider-neutral.
- `.dex/rules/skills-prompts.md`: "Skills must be codebase-agnostic and
  discover tooling at runtime."
- `.dex/review-rules.md` § `skills/*/SKILL.md` codifies the same rule for
  review.
- `bin/init.sh` discovers quality gates per-repo and writes them into
  `.dex/dex.md` rather than baking them into skill files.

Future agent behavior:
- When authoring or editing a skill, prompt, or agent, do not hardcode
  framework-specific commands or example identifiers. Reference
  `.dex/dex.md` § Quality Gates and § Integrations and let the
  generated context drive the specifics.
- When extending the research harness or generated prompt examples, prefer
  neutral phrasing (e.g., "the project's test command") and let the runner
  resolve specifics from project metadata.
- Treat per-language assumptions (Python venv layout, Node `node_modules`,
  Go module cache, Cargo target dir) as configuration, not as defaults baked
  into skills.
- When a feature truly needs a framework-specific path (e.g., Playwright for
  UI capture), gate it on detection or explicit user configuration rather than
  assuming presence.

## M-008: PreToolUse Bash hooks run guards-first and split fail-closed vs fail-open

Domain: architecture-decisions
Status: active
Scope: settings.json PreToolUse hook arrays, hooks/rtk-claude-hook.sh, hooks/guard-handler.py, hooks/stop-sound.sh, lib/rtk.sh, bin/install-settings.sh hook-provenance logic
Applies to phases: any phase that adds, reorders, or edits a Claude Code hook; guard and tooling maintenance
Applies to paths: settings.json, hooks/*.sh, hooks/guard-handler.py, lib/rtk.sh
Last verified: 2026-05-27
Recheck when: a new PreToolUse hook is added, hook registration order in settings.json changes, the RTK integration changes, or any hook's failure mode (exit code) changes

Lesson:
Dex's Claude Code hooks divide by responsibility into two failure contracts.
Security/guard hooks fail CLOSED: `guard-handler.py` exits 2 to block a
dangerous command, and surrounding logic treats other non-zero exits as errors,
not blocks. Enhancement and notification hooks fail OPEN: they must exit 0 on
every error path so a missing or broken optional tool never blocks or breaks the
user's command. In `settings.json` the PreToolUse/Bash array is ordered so the
guard runs before the RTK rewrite hook; a rewrite/enhancement hook must never
run before the guard, or it could mutate a command the guard would have blocked.

Evidence:
- `71ab07b feat(tooling): bootstrap RTK token reduction` adds
  `hooks/rtk-claude-hook.sh`, commented "Fail-open Claude Code hook", which
  exits 0 when RTK is disabled, the binary is unresolved, the payload is empty,
  or the rewrite fails.
- `settings.json` registers two PreToolUse/Bash hooks in order: `guard-handler.py`
  then `rtk-claude-hook.sh`.
- `docs/rtk-token-reduction.md`: "Bash tool calls now run through Dex guards
  first... If RTK is unavailable or fails, the wrapper exits successfully and
  leaves the original command untouched."
- `hooks/stop-sound.sh` is a "best-effort" notification hook that also exits 0
  unconditionally.
- Fail-closed side: `8b62b46 fix(guards): harden destructive command detection`,
  `4290403 feat: block unsafe raw codex delegation`, and `guard-handler.py`
  exit 2 == block (see [[security-guards]] M-005).
- `bin/install-settings.sh` records `rtk-claude-hook.sh` in its Dex-owned hook
  provenance detector, keeping install/uninstall scoped (see
  [[workflow-operations]] M-004).

Future agent behavior:
- When adding a PreToolUse Bash hook that rewrites or enhances commands, fail
  open: exit 0 on missing tooling, empty payload, or any internal error, and
  leave the original command untouched.
- When adding a security/guard hook, fail closed: exit 2 to block; never let a
  detection failure silently allow a dangerous command.
- Preserve guard-before-rewrite ordering in `settings.json`. Do not register a
  rewrite/enhancement hook ahead of `guard-handler.py`.
- When adding any Dex-owned hook, register it in the `bin/install-settings.sh`
  provenance detector so uninstall removes only Dex's entries (M-004).
- Reference `.dex/dex.md` § Tooling and `docs/rtk-token-reduction.md` for the
  RTK integration surface before changing it.
