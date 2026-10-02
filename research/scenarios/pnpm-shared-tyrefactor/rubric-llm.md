You are evaluating a TypeScript monorepo refactor. The author was asked to replace `User.fullName` with `User.firstName` and `User.lastName`, add a shared `displayName(user)` helper, and update frontend/backend consumers and fixtures without unsafe casts.

Expected signals:

- The shared `User` type contains `firstName` and `lastName`, not `fullName`.
- `displayName` is exported from the shared types package and reused by consumers.
- Frontend and backend fixtures/tests are updated coherently.
- There is no `any`, `as any`, or `@ts-ignore`.
- The refactor touches all consumers without rewriting tooling or package boundaries.
- No stale `fullName` strings remain in production code or tests.

Score on a 0-100 scale:
- 90-100: Complete, idiomatic cross-package refactor with shared helper and clean tests.
- 70-89: Correct migration with minor duplication or a small fixture gap.
- 50-69: Most consumers fixed, but helper reuse or tests are incomplete.
- 30-49: Partial migration with stale references, casts, or broken package boundaries.
- 0-29: Type still uses `fullName` or checks fail.

The produced changes:

{{CODE_LISTING}}

Respond with ONLY a JSON object: {"score": N, "reasoning": "brief explanation"}
