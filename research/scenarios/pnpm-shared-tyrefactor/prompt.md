You are being evaluated on a cross-package TypeScript refactor in a pnpm workspace.

The workspace has:

- `packages/types/` exporting shared `User`, `Order`, and `Product` types.
- `packages/frontend/` consuming those types in UI-facing helpers.
- `packages/backend/` consuming those types in route serializers.

Refactor `User.fullName: string` to:

- `User.firstName: string`
- `User.lastName: string`

Add a `displayName(user)` helper or getter in the shared types package that returns `${firstName} ${lastName}`. Propagate the change through all frontend and backend consumers, including test fixtures.

Requirements:

- Remove all `fullName` usage from the workspace.
- Do not use `any`, `as any`, or `// @ts-ignore`.
- Keep package boundaries intact: frontend and backend should import the shared helper from `packages/types`.
- Run the workspace tests and type-check command.
- Do not rewrite the monorepo tooling.

Deliverable: the refactor across `packages/types/`, `packages/frontend/`, and `packages/backend/`.
