You are evaluating AI-generated code for a Python data validation library.

It should have validators for: email, URL, phone, credit card (Luhn), and date ranges. Each returns (bool, error_message). No external dependencies.

Rate the code quality on a scale of 0-100:
- 90-100: Excellent — clean, well-documented, comprehensive edge case handling, thorough tests
- 70-89: Good — solid implementation, minor gaps
- 50-69: Acceptable — works but quality issues
- 30-49: Poor — significant issues
- 0-29: Failing — broken

The code produced:

{{CODE_LISTING}}

Respond with ONLY a JSON object: {"score": N, "reasoning": "brief explanation"}
