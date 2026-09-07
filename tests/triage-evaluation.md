# Triage skill evaluation

These fixtures exercise agent decisions; they are not a substitute for runtime
tests. Use `fixtures/triage/scenarios.json` in an isolated session with the current
`skills/dxtriage/SKILL.md` and its referenced prompts. Supply only the scenario
inputs, not this rubric. No live tracker or implementation writes are permitted.

Ask the evaluator to execute each scenario against the supplied fictional tracker,
returning a ledger of exact proposed writes, questions for the session user, and
final readiness/coverage. Simulate missing tool capabilities and provided user
answers faithfully; do not invent answers. Compare the resulting decisions with
the expectations below and retain the evaluation output outside the repo.

| Scenario | Required observable decisions |
|----------|-------------------------------|
| single | Reuse existing readiness labels, produce observable acceptance criteria and an estimate; no forced children, reassignment, or status-start. |
| hierarchy | Reuse the matching existing child candidate through an approval proposal; do not reparent or close it yet. Ask the user about the conflicting product decision; no stakeholder comment until deferred and a recipient is confirmed. File the evidenced unrelated finding once, without making it a blocker. |
| retriage | Incorporate the confirmed stakeholder's answer with its comment link; preserve newer unrelated discussion and concurrent description additions. Reuse the already-created child after the timeout; do not repeat the question or mention. |
| project | Follow pagination, include the descendant outside the project view once, report draft/PR items separately, mark inaccessible work and dependency cycles as incomplete. Do not publish an unsupported complete sequence or mark the parent ready. |

Also test shell/provider behaviour with `triage-command-test.sh` and hook isolation
with `triage-hooks-test.sh`. Those checks mock provider execution and exercise the
real launcher and hooks. They do not prove how a live agent edits real tickets.
