You are being evaluated on a deprecated dependency upgrade: read a migration guide and apply every breaking API change consistently.

The workspace ships a fictional local library in two versions:

- `lib/v3/` is the deprecated API currently used by `src/`.
- `lib/v5/` is the target API.
- `MIGRATION.md` documents the v3 to v5 changes.

Upgrade `src/` from v3 to v5. Swap all `require('../lib/v3')` imports to the v5 API and apply every migration item from `MIGRATION.md`.

Requirements:

- The test suite must pass against v5.
- Do not modify `lib/v3/`, `lib/v5/`, or `MIGRATION.md`.
- Do not add compatibility shims that preserve the v3 API.
- Do not leave any v3 calls or callback wrappers in `src/`.
- Keep the existing public functions in `src/` working for the tests.

Deliverable: the migrated application code in `src/`.
