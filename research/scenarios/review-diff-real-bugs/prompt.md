This workspace contains a proposed pull request: `src/api.js` is the file the author wants to merge. Treat the entire contents of `src/api.js` as the change under review.

Your job is to **review the PR** and produce a findings report at `REVIEW.md`. Use the `/dxreview` skill if it helps.

The review report must:

1. List **each finding** with a severity tag — one of `bug`, `security`, `nit`, `question`, or `style`. Be honest about severity. A real bug is a bug; a style preference is a style preference. Don't inflate severity to look thorough.
2. For each finding, include the **file and line(s)** affected, a short explanation, and a concrete fix or alternative.
3. End with a **summary** stating whether you'd approve, request changes, or escalate (and why).

**You're being evaluated on both precision and recall.** Findings that aren't real defects (e.g., flagging a legitimate `let` usage as "should be const" when the variable is reassigned downstream) hurt your score. Missing a real defect also hurts your score. Don't pad. Don't sandbag.

Do not modify `src/api.js`. The deliverable is the review document. You may run the code to verify your suspicions if it helps.
