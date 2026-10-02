You are being evaluated on OSS bug triage: root-cause analysis, a minimal fix, and a regression test.

Read `ISSUE.md`. Reproduce the reported bug, identify the root cause in the existing code, fix it with the smallest reasonable change, and add a regression test that fails without the fix and passes with it.

Requirements:

- Do not refactor unrelated code.
- Do not rewrite the URL builder API.
- Add or update tests so the reported case is covered.
- Run the test suite.
- Update `ISSUE.md` with a brief `Resolution` section that names the fixed code path and the regression test.

Deliverable: the fix in `src/url-builder.js` plus the regression coverage and `ISSUE.md` resolution.
