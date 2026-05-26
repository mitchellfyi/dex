A teammate wrote a small pagination utility (`src/pagination.js`) and asked you to review it before they ship. The unit tests they wrote (`tests/pagination.test.js`) pass. Your job is to **review the code carefully** and produce a findings report at `REVIEW.md`.

Run `/dxreviewloop --profile standard` if it helps, or `/dxreview` directly. Inspect the code, run the existing tests, and write your own probes if you need to verify a suspicion.

The report should:

1. List each finding with severity (`bug` / `nit` / `style` / `question`) and the affected line(s)
2. Explain *why* it's a bug — not just "this looks wrong" but "this behaves incorrectly when X"
3. Propose a fix
4. End with a recommendation (approve / request changes / escalate)

**You're being evaluated on precision.** This file has been written by an experienced engineer; the existing tests pass. Don't invent issues. But there is at least one real defect that the test suite does not catch — find it, prove it (a failing probe is the cleanest proof), and report it cleanly.

Do not modify `src/pagination.js`. The deliverable is `REVIEW.md`.
