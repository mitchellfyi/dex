---
name: "dxverify"
description: "Run and repair the full quality pipeline for a project. Use before committing or pushing, after implementation, when asked to verify code quality, or when dx test project delegates verification."
---

# Skill: dxverify

Verify the current project against its declared quality contract.

Read `prompts/issue-hygiene.md`. Apply it only when verification reveals
material new context, not for transient failures repaired within accepted
scope. Reconcile concrete findings before handoff and end the Phase 4 summary
with the contract's exact `Issue/PR work:` line.

## 1. Read the project contract first

Find the Git repository root, then inspect the current change:

```bash
git status
git diff --stat
```

If `.dex/dex.md` exists, read it before discovering commands elsewhere. Treat
its `## Quality Gates` section as authoritative:

- Run every required command or check it names.
- Do not replace a named gate with an inferred, narrower alternative.
- Treat a missing command, stale instruction, or un-runnable gate as a failure
  to resolve or report, not permission to skip it.
- If an outlier justifies skipping a required gate, ask the human or apply a
  named `verification.required-gates` waiver through `dx control waive`. Keep
  the skipped result explicit; a waiver is not a passing check.

If the file or section is absent, discover the complete pipeline from the
repository instead.

## 2. Discover supporting checks

Inspect CI workflows, task runners, package manifests, language configuration,
and workspace definitions. Use them to fill categories the quality contract
does not cover, such as formatting, linting, type checking, generated-code
freshness, builds, tests, and repository-specific validation.

For a monorepo, inspect each affected workspace. Treat a newly created package
or standalone deliverable as a full workspace even when the repository root
uses a different toolchain.

## 3. Run the pipeline

Run checks in dependency order so one failure does not obscure another:

1. Formatting
2. Linting and static analysis
3. Type checking
4. Code generation and generated-file freshness
5. Build or packaging checks
6. Tests

Prefer a canonical aggregate command only when it covers every required gate.
Scope supplemental checks to affected workspaces where appropriate, but never
scope away a command required by `.dex/dex.md`.

When a check fails:

1. Diagnose the exact failure.
2. Make the smallest valid fix.
3. Rerun the failed check.
4. Continue only after it passes.

On the second failure of the same check type, read
`prompts/failure-recovery.md`, choose a different recovery strategy, and follow
it. Try at most three times per strategy and two strategies per check type. If
both strategies fail, stop and report the command, relevant output, approaches
tried, and recommended next step.

## 4. Reconcile Dex context

Before reporting success, check whether the change introduced a dependency,
tool, convention, integration, or security-sensitive path that should update
`.dex/`. Keep `dex.md`, `rules/`, and `guards/` aligned with durable project
changes. Use `dx sync --dry-run` for repeated lessons that may belong in Dex
memory.

Do not read or expose secrets to make a gate pass. If verification needs
credentials that are unavailable, name the blocked command and the required
human action.

## 5. Report exact results

List every required gate and its result. Include concise failure output and the
remaining action for any gate that did not pass. Do not report the pipeline as
successful while a required gate is failed, skipped, or unverified. If the
phase proceeds by override, report it as waived with the recorded reason.
