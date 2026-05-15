# Architecture Decisions

Durable design constraints that span Doyaken's primitives — skills, agents,
prompts, hooks, and the research harness.

## M-006: Doyaken skills and prompts must be codebase-agnostic and discover tooling at runtime

Domain: architecture-decisions
Status: active
Scope: skills/*/SKILL.md, prompts/*.md, prompts/phase-audits/*.md, prompts/init-analysis.md, research harness, agents/*.md
Applies to phases: plan, implement, review, verify, complete (any phase that loads skills or prompts)
Applies to paths: skills/, prompts/, agents/
Last verified: 2026-05-15
Recheck when: a new shared prompt is introduced, the research harness changes, or a skill encodes per-repo quality-gate commands

Lesson:
Doyaken is intended to work in any git repository, across languages and
frameworks. Skills, agents, prompts, and the research harness must avoid
framework-specific examples, hardcoded test/lint commands, and assumptions about
project structure. They must discover quality gates (format, lint, typecheck,
test, generate), package managers, ticket trackers, and integration tooling at
runtime — typically from `.doyaken/doyaken.md`, manifests (`package.json`,
`Cargo.toml`, `pyproject.toml`, `go.mod`), and CI config — rather than
hardcoding a stack.

Evidence:
- `7dc56c8 fix(research): make harness and prompts codebase agnostic`
  configures local git identity for generated research workspaces and replaces
  framework-specific shared prompt examples with neutral guidance.
- `29a0e70 feat(init): use AGENTS as generated context source` keeps generated
  context provider-neutral.
- `.doyaken/rules/skills-prompts.md`: "Skills must be codebase-agnostic and
  discover tooling at runtime."
- `.doyaken/review-rules.md` § `skills/*/SKILL.md` codifies the same rule for
  review.
- `bin/init.sh` discovers quality gates per-repo and writes them into
  `.doyaken/doyaken.md` rather than baking them into skill files.

Future agent behavior:
- When authoring or editing a skill, prompt, or agent, do not hardcode
  framework-specific commands or example identifiers. Reference
  `.doyaken/doyaken.md` § Quality Gates and § Integrations and let the
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
