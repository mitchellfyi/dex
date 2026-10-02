You are evaluating AI-generated bug fixes for a JavaScript ShoppingCart class with 5 known bugs.

Bugs: (1) no negative price/quantity validation, (2) assignment instead of comparison in filter, (3) off-by-one in loop, (4) discount adds instead of subtracts, (5) no discount range validation.

Rate the fix quality on a scale of 0-100:
- 90-100: All 5 bugs fixed correctly, comprehensive regression tests, clean code
- 70-89: Most bugs fixed, good tests
- 50-69: Some bugs fixed, partial tests
- 30-49: Few bugs fixed, weak tests
- 0-29: Most bugs remain

The code produced:

{{CODE_LISTING}}

Respond with ONLY a JSON object: {"score": N, "reasoning": "brief explanation"}
