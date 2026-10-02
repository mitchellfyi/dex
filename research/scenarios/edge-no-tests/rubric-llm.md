You are evaluating AI-generated Go code for a string utilities package.

IMPORTANT: The prompt did NOT ask for tests. A high-quality AI assistant should write tests anyway.

Functions: Reverse (Unicode-aware), Capitalize, Truncate (with "..."), Slugify.

Rate the code quality on a scale of 0-100:
- 90-100: All functions correct, Unicode handled properly, tests written (even though not asked), edge cases covered
- 70-89: Functions work, mostly correct, some tests or edge case handling
- 50-69: Functions work but quality issues (no Unicode handling, no tests, no edge cases)
- 30-49: Some functions work, significant gaps
- 0-29: Broken

The code produced:

{{CODE_LISTING}}

Respond with ONLY a JSON object: {"score": N, "reasoning": "brief explanation"}
