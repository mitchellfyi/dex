Review, improve, and harden the codebase. Focus your effort where it will have the most impact.

## Scope and Prioritisation

Start by understanding the current state of the project:

1. Read the project's AGENTS.md, README, CLAUDE.md, and `.dex/dex.md` (if they exist) to understand the tech stack, conventions, and quality gates.
2. Run `git log --oneline -30` to see recent activity and identify active areas.
3. Run the project's quality checks (format, lint, typecheck, test) to find existing failures.
4. Review `git diff` and `git status` for any uncommitted work in progress.

Prioritise improvements in this order:
1. **Failing checks** — fix anything that's currently broken (tests, lint, types)
2. **Security** — hardcoded secrets, missing auth, input validation gaps, insecure defaults
3. **Correctness** — bugs, missing error handling, resource leaks, race conditions
4. **Test gaps** — untested public functions, missing edge case coverage, brittle tests
5. **Performance** — N+1 queries, unbounded loops, missing pagination, unnecessary allocations
6. **Code quality** — dead code, stale comments, unnecessary complexity, inconsistent patterns
7. **Documentation** — undocumented public APIs, missing "why" comments on non-obvious logic

## How to Work

Apply the criteria from `prompts/review.md` (12 review passes) and the principles from `prompts/guardrails.md` (implementation discipline). For each area:

- **Investigate first** — read the code, understand the context, check for prior art before changing anything.
- **Make targeted fixes** — prefer small, focused changes over sweeping rewrites. Each change should be independently correct.
- **Follow existing patterns** — match the project's conventions for naming, error handling, test structure, and code organisation.
- **Verify your changes** — run the relevant quality checks after each meaningful change. Don't accumulate unverified work.
- **Stay in scope** — improve existing code, don't add new features or speculative abstractions.

## What NOT to Do

- Don't rewrite working code for style preferences alone.
- Don't add dependencies to solve problems the project already handles.
- Don't refactor code that isn't related to an actual issue you found.
- Don't add comments that restate what the code already says.
- Don't change public APIs or break backward compatibility without clear justification.
