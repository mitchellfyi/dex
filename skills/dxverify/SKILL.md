---
name: "dxverify"
description: "Discover and run the full quality verification pipeline for the current project."
---

# Skill: dxverify

Run the full quality verification pipeline for the current project.

## When to Use

- Before committing or pushing changes
- After completing a feature or bug fix
- When asked to verify code quality

## Steps

### 1. Discover the Toolchain

Identify what quality tools the project uses by checking for these files at the repo root (and in subdirectories for monorepos):

| File | Indicates | Typical Commands |
|------|-----------|-----------------|
| `Makefile` | Make targets | Read the file — look for `format`, `lint`, `typecheck`, `test`, `verify`, `ci` targets |
| `package.json` | Node.js project | Read `scripts` — look for `format`, `lint`, `typecheck`, `test`, `check` scripts |
| `Cargo.toml` | Rust project | `cargo fmt --check`, `cargo clippy`, `cargo test` |
| `pyproject.toml` | Python project | Check `[tool.ruff]`, `[tool.black]`, `[tool.pytest]`, `[tool.mypy]` sections |
| `go.mod` | Go project | `go fmt ./...`, `go vet ./...`, `go test ./...` |
| `composer.json` | PHP project | Read `scripts` for `lint`, `test`, `analyse` |
| `.github/workflows/` | CI config | Read CI workflows to understand what checks will run remotely |

For monorepos, check each workspace/package for its own toolchain. Scope checks to the packages that have changes.
If the change creates a new project, package, or standalone deliverable, treat that new directory as a full workspace even if the parent repo has no matching root-level tooling. Discover and run its local build, lint, type-check, and test commands before reporting success.

### 2. Check What Changed

```bash
git status
git diff --stat
```

Understand the scope. If only one package/app changed in a monorepo, run checks scoped to that package.

### 3. Run Quality Checks

Run the discovered checks in this order (fix each before moving to the next):

1. **Format** — auto-fix formatting issues
2. **Lint** — auto-fix where possible, manual fix where not
3. **Type-check** — fix type errors (if the language has a type checker)
4. **Code generation** — if the project uses code generation (API clients, DB types, OpenAPI specs), run the generator and check for uncommitted changes
5. **Test** — run the test suite

If the project has a single command that runs all checks (e.g., `make verify`, `npm run ci`, `make check`), prefer that.

### 4. `.dex/` Sync Check

Before reporting results, verify `.dex/` is in sync with the changes:

1. Check if any of these changed during implementation:
   - Package manifests (package.json, Cargo.toml, pyproject.toml, go.mod)
   - New frameworks, tools, or conventions introduced
   - Security-sensitive file paths or patterns
2. If so, confirm the corresponding `.dex/` files were updated (dex.md, rules/, guards/, memory/).
3. If durable lessons were discovered but not yet promoted, run `/dxsync --dry-run` or call them out as candidate observations for `dx sync`.
4. If `.dex/` updates are pending, make them now and stage them for commit.

### 5. Report

Summarize results:
- Which checks passed
- Which checks failed (with the error output)
- Suggested fixes for any failures

## Fix-and-Retry Loop

When a check fails:

1. **Diagnose** — read the error output carefully.
2. **Fix** — make the minimum change to resolve the issue.
3. **Re-run only the failing check** — not the entire pipeline.
4. **On 2nd failure of the same check type**: read `prompts/failure-recovery.md` and run the failure analysis. Choose a recovery strategy and follow it. If you switch strategies, the retry count resets for the new strategy.
5. **Max 3 retries per strategy per check type.** After exhausting 2 strategies (6 total attempts), escalate to the user with:
   - The check name and error output
   - The recovery analysis (strategies tried and why each failed)
   - Recommended next steps

Run checks sequentially — fix each before moving to the next:
- Format failures first (they may fix lint issues).
- Lint failures second (they may fix type issues).
- Type errors third.
- Generated code freshness fourth.
- Tests last (everything else must pass first).

## Notes

- If linting or formatting fails, fix the issues and re-run.
- If type checking fails, fix type errors before running tests.
- If tests fail, investigate and fix before committing.
- AI agents do not have access to `.env` files — ask the developer to verify environment variables if tests require them.
