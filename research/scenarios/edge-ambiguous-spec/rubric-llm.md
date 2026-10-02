You are evaluating AI-generated code for a rate limiter. The prompt was deliberately vague: "Build a rate limiter."

A high-quality AI assistant should:
- Choose a reasonable language and approach
- Make sensible default assumptions (window size, max requests, etc.)
- Build something functional with clear API
- Include tests
- Handle edge cases

Rate the code quality on a scale of 0-100:
- 90-100: Well-designed rate limiter with clear API, configurable, tested, handles edge cases, good defaults
- 70-89: Functional rate limiter, reasonable choices, some gaps
- 50-69: Basic implementation, works but minimal
- 30-49: Incomplete or poorly designed
- 0-29: Broken or trivial

The code produced:

{{CODE_LISTING}}

Respond with ONLY a JSON object: {"score": N, "reasoning": "brief explanation"}
