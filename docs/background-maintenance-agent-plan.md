# Background Maintenance Agent Plan

This document scopes the first autonomous Doyaken agent that can run overnight
or in the background. It depends on the memory and sync model described in
`docs/dksync-memory-plan.md`.

The goal is not to create an agent that opens lots of speculative cleanup PRs.
The goal is to create a high-signal maintenance scout that uses durable repo
memory, deterministic checks, and review loops to reduce human review burden.

## Relationship To DKSync

`dk sync` is the first phase. It keeps repo context fresh.

The background maintenance agent is the second phase. It uses the synced context
to decide where to look, what risks matter, and which findings are worth turning
into reports or PRs.

The default nightly flow should be:

```
dk sync
dk maintain --nightly
```

Command naming is still open. Candidate names:

- `dk maintain`
- `dk scout`
- `dk nightly`
- `dk background`

`dk maintain` is the clearest long-term command because it can cover nightly,
manual, and scheduled modes without implying a specific time of day.

## Goals

- Run unattended in a clean branch or worktree.
- Use synced memory, rules, and guards to focus on important repo risks.
- Spot bugs, regressions, missing tests, CI drift, and review-process gaps.
- Create a morning artifact that is worth reviewing.
- Open a draft PR only when there is strong evidence and a safe patch.
- Reduce reviewer effort by including reproduction, verification, and review
  context in the output.
- Support increasing autonomy over time through explicit trust modes.

## Non-Goals

- Do not replace human review.
- Do not merge PRs automatically.
- Do not make broad architecture changes overnight.
- Do not create speculative refactor PRs.
- Do not run unbounded searches or expensive checks without budget controls.
- Do not rely on reviewer-specific personal profiles.
- Do not treat synced memory as proof without checking current code.

## Trust Modes

Autonomy should increase gradually:

| Mode | Behavior | PR Creation |
|------|----------|-------------|
| `report` | Runs checks and semantic review, writes a report | No PRs |
| `propose` | Creates issues or draft PRs for high-confidence findings | Draft PRs only |
| `fix-scoped` | Fixes configured low-risk categories | Draft PRs only |
| `trusted-maintenance` | Runs broader maintenance within configured boundaries | Draft PRs only, no merge |

The first implementation should default to `report`. Scheduled PR creation
should be opt-in.

## Inputs

The background agent should gather:

- Current default branch state.
- `.doyaken/doyaken.md`, `.doyaken/rules/`, `.doyaken/guards/`, and
  `.doyaken/memory/index.md`.
- Recent commits and files with recent `fix:` history.
- Recent merged PRs and review comments when GitHub is available.
- Recent CI failures and flaky checks when GitHub Actions is available.
- Quality gates discovered by `dk init` / `dk sync`.
- Dependency manifests and lockfiles.
- Existing test layout and coverage signals where available.

If an integration is missing, the agent should degrade gracefully and say which
signals were unavailable.

## Nightly Loop

One run should follow a bounded loop:

1. **Refresh context**
   - Run `dk sync` or reuse the most recent successful sync when configured.
   - Load only relevant durable memory.

2. **Select risk surfaces**
   - Prefer recent churn, files with repeated fixes, fragile tests,
     security-sensitive paths, migrations, generated contracts, CI failures, and
     areas flagged by memory.
   - Cap the number of surfaces per run.

3. **Run deterministic checks**
   - Run configured lint, typecheck, test, dependency audit, or targeted checks.
   - Keep command timeouts and total runtime budgets.

4. **Run semantic review**
   - Use a focused review pass similar to `/dkreviewloop`, but scoped to the
     selected risk surfaces.
   - Require evidence before reporting findings.

5. **Triage**
   - Classify each finding as reproducible bug, likely issue, documentation/rule
     gap, guard opportunity, or noise.
   - Drop low-confidence findings.

6. **Patch only safe findings**
   - Create code changes only when the fix is small, scoped, and verifiable.
   - Prefer adding regression tests before implementation changes.
   - For documentation/rule gaps, update `.doyaken/` context files instead of
     production code.

7. **Verify**
   - Re-run affected checks.
   - Run a focused review pass on the diff.
   - Record failing-before and passing-after evidence when possible.

8. **Publish morning artifact**
   - In `report` mode, write a summary.
   - In PR modes, create a draft PR with evidence and reviewer guidance.
   - Escalate anything that needs human judgment.

## PR Creation Criteria

The agent may open a draft PR only when at least one of these is true:

- A test, check, or reproduction fails before the change and passes after it.
- A missing guard or rule addresses a repeated observed failure pattern.
- A documentation or memory update captures a durable lesson with evidence.
- A dependency or CI fix is narrow, deterministic, and verified.

The agent should not open a PR for:

- Style-only preferences.
- Broad refactors.
- Findings based only on "best practice" claims.
- Changes that require product or architecture judgment.
- Multiple unrelated fixes bundled together.

## Morning Artifact

Every run should end with a compact artifact:

```markdown
# Doyaken Maintenance Report

Run: 2026-05-15 nightly
Mode: report
Repo: owner/repo
Base: main@abc123

## Checked
- Risk surface 1: backend/auth/**
- Risk surface 2: migrations/**
- Commands: npm test -- auth, npm run lint

## Findings
| ID | Status | Evidence | Action |
|----|--------|----------|--------|
| F-1 | Fixed in draft PR | test failed before, passed after | PR #123 |
| F-2 | Report only | likely issue, needs product call | Escalated |

## Not Promoted
- Observation about naming was one-off and contradicted nearby code.

## Next Suggested Run
- Focus migrations again after the pending schema PR merges.
```

For PRs, the description should reduce reviewer work:

- State the risk that was checked.
- Link to tests or commands that failed before and passed after.
- Explain why the fix is intentionally small.
- List memory/rules consulted.
- List what the agent deliberately did not change.
- Include the focused review result.

## Safety Controls

The first version needs strict safety controls:

- Always use an isolated worktree or branch.
- Never merge automatically.
- Default to draft PRs.
- Limit max PRs per run.
- Limit max files changed per PR unless configured.
- Limit total runtime and per-command runtime.
- Cancel on secrets scan failures.
- Escalate architecture, product, data-loss, auth-policy, and destructive git
  decisions.
- Do not run scheduled watchers while a user is actively working in the same
  session.
- Do not run overlapping nightly jobs for the same repo.

Run state should stay outside the repo, similar to existing Doyaken phase state.
Durable lessons discovered by a run should be proposed through `dk sync`
artifacts under `.doyaken/`.

## Reducing Human Review Burden

The agent should improve review quality before asking for review:

- Run deterministic checks first.
- Run a focused adversarial review of its own diff.
- Include a concise review packet in the PR.
- Keep PRs small and single-purpose.
- Avoid reviewer-specific assumptions.
- Convert repeated review comments into repo-wide rules or guards through
  `dk sync`.

This is where the background agent becomes more valuable than a generic coding
agent: it does not just make changes, it learns which changes are worth making
and which review failures should be prevented next time.

## First Version Requirements

V1 should be considered useful when:

- It can run in `report` mode without modifying production code.
- It can select risk surfaces using `.doyaken/memory/index.md` and recent git
  history.
- It can run bounded deterministic checks.
- It can produce a morning report with checked surfaces, findings, rejected
  observations, and unavailable signals.
- It can optionally create a draft PR for a `.doyaken/` memory/rule update.
- It does not require Claude hooks to run, but uses them when available.

## Later Versions

After V1 is reliable:

- Add `propose` mode for draft PR creation.
- Add scoped fix categories such as tests, docs, guards, dependency metadata, or
  CI configuration.
- Integrate with Phase 6 so maintenance PRs can monitor CI and review comments.
- Add trend reports: recurring review failures, flaky areas, stale memory, and
  rules that no longer match the codebase.
- Add a trust dashboard showing what the agent is allowed to change
  autonomously.

## Open Questions

- Should the background command always run `dk sync` first, or only when the
  memory index is stale?
- Where should morning reports live when no PR is created: local artifact
  directory, GitHub issue, PR comment, or terminal output?
- What categories are safe enough for first automatic draft PRs?
- How should teams configure runtime and cost budgets?
- Should scheduled runs be launched by cron, GitHub Actions, Claude `/loop`, or
  a Doyaken-managed scheduler?
