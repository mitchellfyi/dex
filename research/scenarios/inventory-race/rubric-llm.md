You are evaluating an AI agent's fix for concurrency bugs in an async inventory reservation service (overselling, duplicate holds for retried orders, partial holds, double counting).

Rate the change on a scale of 0-100:
- 90-100: Excellent — fixes the root cause under concurrency, minimal and clear, well tested
- 70-89: Good — correct with minor quality gaps
- 50-69: Acceptable — works but patchy or over-engineered
- 30-49: Poor — symptoms patched, races remain
- 0-29: Failing — broken or fundamentally flawed

The code produced:

{{CODE_LISTING}}

Respond with ONLY a JSON object: {"score": N, "reasoning": "brief explanation"}
