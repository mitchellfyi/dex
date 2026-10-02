You are evaluating a code refactoring that eliminates validation duplication across 3 route files.

The original code had nearly identical validation patterns in users.js, products.js, and orders.js. The AI was asked to extract shared validation logic while preserving all behavior.

Rate the refactoring quality on a scale of 0-100:
- 90-100: Clean shared utility, declarative validation schemas, zero duplication, all behavior preserved
- 70-89: Good extraction, minor duplication remains, tests pass
- 50-69: Partial extraction, some behavior may have changed
- 30-49: Minimal refactoring, significant issues
- 0-29: Failed to refactor or broke behavior

The code produced:

{{CODE_LISTING}}

Respond with ONLY a JSON object: {"score": N, "reasoning": "brief explanation"}
