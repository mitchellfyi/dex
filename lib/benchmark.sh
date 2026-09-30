# shellcheck shell=bash
# Dex shared library - the benchmark workflow's prompt text.
#
# A benchmark lifecycle (run spec workflow.name=benchmark, DEX_WORKFLOW=benchmark)
# runs Plan, Implement and Review in one headless provider session, then stops.
# An evaluation harness scores the working tree Dex leaves behind, so the parts
# of a ticket lifecycle that talk to the outside world have nothing to act on:
# no tracker, no remote, no PR, no CI, no reviewer, no human to approve a plan.
# lib/lifecycle-control.sh owns which phases run; this file owns what the agent
# is told about them. dx.sh (launch) and hooks/phase-loop.sh (inline handoff
# and audits) both read it, so the two cannot drift apart.

# dx_benchmark_phase_message <phase>
# The instruction that opens a benchmark phase, at launch or at an inline handoff.
dx_benchmark_phase_message() {
  case "${1:-}" in
    1)
      cat <<'EOF'
Begin Phase 1: Plan. This is a benchmark run: the requested task below is the whole request, there is no ticket or tracker, and an automated verifier will score the working tree you leave behind. Invoke the Skill tool with skill: "dxplan" now. Phase 1 is read-only, exactly as it would be in plan mode: read, explore and run commands that inspect, but do not create, edit or delete project files, and do not run commands that change them. The only files you write are dxplan's own artifacts, the review criteria and the ready marker. Implementation starts in Phase 2, however small the task. Plan mode itself stays off because nobody can answer an ExitPlanMode prompt here: do not call EnterPlanMode and do not wait for approval. The run spec sets workflow.requires_plan_approval=false, so it authorizes the plan once the normal plan quality checks pass; follow the dxplan headless instructions. Skip tracker intake, ticket updates and issue searches. When the plan and its review criteria are ready, write the Phase 1 ready marker and stop so the Stop hook can audit and advance.
EOF
      ;;
    2)
      cat <<'EOF'
The plan is approved. Invoke the Skill tool with skill: "dximplement" to begin implementation. Phase focus: implement and test the change in this checkout. Commit coherent checkpoints locally if you like, but never push, open a PR, or touch a tracker; there is no remote and no reviewer. Record UI proof as N/A. Run the tests that cover your change rather than the whole suite unless the suite is small. Before the Phase 2 ready marker, record the review risk tier with dx_review_write_selection as dximplement describes; the Stop hook rejects Phase 2 without it. When implementation is complete and the audit criteria are met, stop so the Stop hook can advance to review.
EOF
      ;;
    3)
      cat <<'EOF'
Begin Phase 3: Review. Invoke the Skill tool with skill: "dxreviewloop". Use the current Phase 2 risk selection: trivial and small require 1, normal 2, and complex 3 consecutive independent clean waves (CLEAN or NOTES:N). Any fix, MECHANICAL:N included, resets the clean streak; residual findings, blockers, churn, invalid results, or provider failures pause the loop instead of counting as clean. Keep accepted review fixes in this checkout (local commits are fine); do not push, switch branches, or open a PR. When the loop writes a valid success receipt, stop. Review is the last phase of a benchmark run.
EOF
      ;;
  esac
}

# dx_benchmark_scope_lines <phase>
# The per-phase scope bullets for the system context.
dx_benchmark_scope_lines() {
  case "${1:-}" in
    1)
      cat <<'EOF'
- DO invoke the dxplan skill immediately; do not call EnterPlanMode
- Phase 1 is read-only: no project file changes, however small the task; implementation starts in Phase 2
- The run spec authorizes the plan once its quality checks pass; do not wait for approval
- Skip tracker intake and ticket updates; there is no tracker
EOF
      ;;
    2)
      cat <<'EOF'
- DO implement, test, and verify completeness via the dximplement skill
- Local commits are optional; never push, open a PR, or update a tracker
- Record the review risk tier (dx_review_write_selection) before the ready marker
- Record UI proof as N/A
EOF
      ;;
    3)
      cat <<'EOF'
- DO run /dxreviewloop, fix all findings, and reach a SUCCESS result
- Keep accepted fixes in this checkout; do not push, switch branches, or open a PR
- Review is the final phase; the lifecycle ends when it succeeds
EOF
      ;;
  esac
}

# dx_benchmark_context
# The system-context section every benchmark phase carries.
dx_benchmark_context() {
  cat <<'EOF'

## Benchmark Run

This lifecycle is a benchmark run (workflow.name=benchmark). An automated
verifier scores the files in this checkout after Dex exits; nothing else you
produce is read.

- Phases: Plan, Implement, Review. Setup, Verify, PR and Complete do not run.
- There is no ticket tracker, remote, pull request, CI, or human reviewer.
  Never push, never open or update a PR, never create, search or comment on
  issues, and never wait for approval or ask the user a question. Where a
  skill or audit asks for one of those, it does not apply here: note it as
  N/A and continue.
- Skip prompts/issue-hygiene.md and the `Issue/PR work:` line.
- The task text is the whole request. Solve it from the repository and the
  task; do not search issue trackers, pull requests or later commits for it.
- Local commits are fine but not required; the verifier reads files, not
  history. When you finish, leave the change in place: do not switch
  branches, stash, reset, or clean the checkout.
- Prefer targeted tests over the full suite. Some benchmark repositories have
  very large suites and the run has a time limit.
EOF
}

# dx_benchmark_audit_addendum
# Appended to every phase audit so its PR, push and tracker checks read as N/A.
dx_benchmark_audit_addendum() {
  cat <<'EOF'
## Benchmark Run Overrides

This is a benchmark run. In the audit above, treat every check about pushing,
origin or upstream tracking, draft or ready PRs, tracker tickets, issue
hygiene or the `Issue/PR work:` line, reviewer requests, UI proof, and user
approval as not applicable. Mark those N/A and do not try to satisfy them.
Every other check applies in full.
EOF
}
