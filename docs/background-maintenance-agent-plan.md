# Background Maintenance Agent Plan

This document refines the first autonomous Doyaken agent that can run overnight
or in the background. It depends on the memory and sync model described in
`docs/dksync-memory-plan.md`.

The goal is not to create an agent that opens lots of speculative cleanup PRs.
The goal is to create a high-signal maintenance scout that uses durable repo
memory, deterministic checks, and review loops to reduce human review burden.

## Refinement Status

Status: implementation started. The first CLI, skill, prompt, and installable
GitHub workflow surfaces exist in this branch; this document remains the
planning record for rollout hardening and future expansion.

Architecture map status: `.doyaken/architecture.md` is not present in this repo
yet. This refinement therefore uses the current repo layout, `.doyaken/rules/`,
`.doyaken/memory/`, and existing Doyaken lifecycle docs as the component map. Run
`/dkarchitect` before creating formal tracked sub-tickets that require C4 domain
labels.

Relevant durable memory:

- `M-002`: lifecycle phases own their outputs strictly.
- `M-004`: Doyaken-owned global state must be tracked separately from user
  state.
- `M-006`: skills and prompts must stay codebase-agnostic and discover tooling
  at runtime.
- `M-007`: review waves build context first, run deterministic checks before
  semantic review, isolate acceptance criteria, and only count true clean waves.

Relevant GitHub/Copilot facts as of 2026-05-15:

- GitHub organization workflow templates live in a `.github` repository under
  `workflow-templates/`, with a matching `.properties.json` metadata file; a
  workflow template can use `$default-branch` as a placeholder. For Doyaken's
  per-repo install flow, shipping a local template and copying it to
  `.github/workflows/dk-maintain.yml` is the more direct first version.
- `gh pr edit <number> --add-reviewer @copilot` requests Copilot code review.
  The GitHub CLI also supports `--add-assignee @copilot`, but Doyaken should
  use reviewer request by default so Doyaken remains the PR owner.
- Copilot can be configured to review draft pull requests, and automatic
  re-review on new pushes depends on repository/organization Copilot settings.
  Doyaken should still explicitly re-request review after it pushes fixes.
- Events created with the default GitHub Actions `GITHUB_TOKEN` generally do
  not trigger follow-up workflows, except `workflow_dispatch` and
  `repository_dispatch`. A GitHub App token or PAT is needed when Doyaken wants
  PR creation, pushes, review requests, and comments to trigger normal
  downstream automation.
- PR-level comments trigger `issue_comment`; review submissions trigger
  `pull_request_review`; inline diff comments trigger
  `pull_request_review_comment`. The maintenance workflow needs all three if it
  should react to review feedback without polling.

References:

- GitHub Actions workflow templates:
  <https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations>
- GitHub Actions `GITHUB_TOKEN` trigger behavior:
  <https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow>
- GitHub Actions PR comment/review events:
  <https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows>
- GitHub Actions workflow permissions:
  <https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax>
- Copilot code review and draft review settings:
  <https://docs.github.com/en/copilot/concepts/agents/code-review>
- `gh pr edit` Copilot reviewer/assignee support:
  <https://cli.github.com/manual/gh_pr_edit>

## Problem Statement

Doyaken now has a repo memory model, but no autonomous consumer that turns that
memory into scheduled maintenance work. The background agent should run a
bounded maintenance loop that:

1. refreshes context with `dk sync`;
2. selects a small number of risk surfaces from memory, git history, CI, and
   review signals;
3. runs deterministic checks before semantic review;
4. reports high-confidence findings;
5. optionally opens a draft PR only when the evidence and patch are narrow
   enough for morning review.

Success means a team can schedule the agent in `report` mode without trusting it
to change production code, then gradually enable draft PR modes as the reports
prove useful.

## Relationship To DKSync

`dk sync` is the first phase. It keeps repo context fresh and promotes durable,
evidenced lessons into `.doyaken/memory/`, `.doyaken/rules/`, or
`.doyaken/guards/`.

The background maintenance agent is the second phase. It uses synced context to
decide where to look, what risks matter, and which findings are worth turning
into reports or PRs.

The default scheduled flow should be:

```bash
dk sync --since <last-successful-maintenance-run-or-explicit-ref>
dk maintain --mode report --nightly
```

`dk maintain` is the preferred command name because it covers manual, nightly,
and scheduled operation without implying a specific time of day.

## Goals

- Run unattended in a clean branch or worktree.
- Use synced memory, rules, and guards to focus on important repo risks.
- Spot bugs, regressions, missing tests, CI drift, stale context, and
  review-process gaps.
- Create a morning artifact that is worth reviewing.
- Open a draft PR only when there is strong evidence and a safe patch.
- Reduce reviewer effort by including reproduction, verification, and review
  context in the output.
- Support increasing autonomy over time through explicit trust modes.
- Work without Claude hooks, while using hooks when available for efficiency.

## Non-Goals

- Do not replace human review.
- Do not merge PRs automatically.
- Do not make broad architecture changes overnight.
- Do not create speculative refactor PRs.
- Do not run unbounded searches or expensive checks without budget controls.
- Do not rely on reviewer-specific personal profiles.
- Do not treat synced memory as proof without checking current code.
- Do not store raw maintenance run state inside the repository.

## Command Model

V1 should add a standalone command and an in-session skill:

```bash
dk maintain [--mode report|propose|fix-scoped] [--nightly]
dk maintain [--focus <domain-or-path>] [--since <ref|date>]
dk maintain [--budget-minutes <n>] [--max-surfaces <n>] [--max-prs <n>]
dk maintain [--no-sync] [--no-pr] [--dry-run]
dk maintain install-workflow [--force]
dk maintain respond --pr <number> [--event <review|comment|review-comment>]
dk maintain publish --state-file <path>
dk maintain publish-response --state-file <path>
```

Proposed files:

| Surface | Proposed path | Responsibility |
|---------|---------------|----------------|
| Shell command | `bin/maintain.sh` | Parse flags, prepare run state, launch provider prompt |
| zsh entry point | `dk.sh` | Expose `dk maintain` and keep re-sourcing safety |
| Skill | `skills/dkmaintain/SKILL.md` | In-session maintenance workflow |
| Prompt | `prompts/maintain.md` | Provider-neutral loop contract |
| Shared helpers | `lib/maintenance.sh` | Run ids, locks, artifact paths, config defaults |
| GitHub workflow template | `templates/github/workflows/dk-maintain.yml` | Thin scheduled/event wrapper that runs the CLI |
| Workflow installer | `bin/maintain-workflow.sh` or `bin/maintain.sh install-workflow` | Copy/update `.github/workflows/dk-maintain.yml` in the target repo |
| Docs | `docs/background-maintenance-agent-plan.md` | Refinement and rollout plan |

The command should not be folded into the six-phase ticket lifecycle. It is a
separate maintenance lifecycle that may create a draft PR, but it starts from a
maintenance report rather than a user ticket.

The workflow must stay thin. Workflow YAML should install Doyaken, set up
authentication, call `dk maintain`, and upload/report artifacts. Skill prompts
and CLI commands remain the source of behavior so the same maintenance flow is
usable manually, inside an agent session, and from GitHub Actions.

GitHub Actions jobs normally run bash, while `dk.sh` is zsh-only. The workflow
should therefore invoke a bash-compatible script such as
`bash "$DOYAKEN_DIR/bin/maintain.sh" ...` or a future standalone executable
wrapper, not depend on the interactive `dk` zsh function being sourced.

## Trust Modes

Autonomy should increase gradually:

| Mode | Allowed writes | PR creation | Default for scheduled runs |
|------|----------------|-------------|----------------------------|
| `report` | External report artifact only | No PRs | Yes |
| `propose` | Draft PR for `.doyaken/` docs, rules, memory, or guards | Draft PRs only | No |
| `fix-scoped` | Configured low-risk file categories plus tests | Draft PRs only | No |
| `trusted-maintenance` | Broader configured maintenance boundaries | Draft PRs only, no merge | No |

Scheduled PR creation must be opt-in. `--dry-run` should show the selected risk
surfaces, proposed commands, unavailable signals, and any PR it would have
created.

## Component Map

Because `.doyaken/architecture.md` is absent, these domains use current repo
component boundaries instead of canonical C4 names.

| Component | Existing paths | Current responsibility | Impact |
|-----------|----------------|------------------------|--------|
| Project context and memory | `.doyaken/memory/`, `.doyaken/rules/`, `.doyaken/guards/`, `bin/sync.sh`, `skills/dksync/`, `prompts/sync-memory.md` | Store durable repo context and promote verified learning | Heavy |
| CLI command surface | `dk.sh`, `bin/*.sh`, `lib/common.sh` | Expose Doyaken commands and shared shell bootstrapping | Heavy |
| Provider and state libraries | `lib/provider.sh`, `lib/session.sh`, `lib/output.sh`, `lib/worktree.sh` | Launch providers and keep state outside the repo | Medium |
| Review system | `skills/dkreview/`, `skills/dkreviewloop/`, `prompts/review-wave.md`, `prompts/review.md` | Run deterministic-plus-semantic review waves | Medium |
| Verification system | `skills/dkverify/`, `prompts/failure-recovery.md` | Discover and run project quality gates | Medium |
| PR and watcher system | `skills/dkpr/`, `skills/dkcomplete/`, `skills/dkwatchpr/` | Create PRs, monitor CI, and respond to review feedback | Light in V1, Medium later |
| GitHub workflow integration | `templates/github/workflows/`, `.github/workflows/dk-maintain.yml`, future workflow installer | Schedule maintenance and trigger one-shot PR feedback responses | Heavy |
| Hook system | `settings.json`, `hooks/*.sh`, `hooks/guard-handler.py` | Guard commands, preserve context, pause watcher overlap | Light in V1 |
| Documentation | `docs/*.md`, `README.md` | Explain behavior, rollout, and manual operation | Medium |

## Architecture Direction

The maintenance agent should be a pipeline, not a new monolithic lifecycle. Each
stage has explicit inputs, outputs, budgets, and failure behavior.

1. **Preflight and locking**
   - Confirm the repo is clean or create an isolated worktree.
   - Acquire a per-repo maintenance lock under external Doyaken state.
   - Refuse overlapping scheduled runs for the same repo.

2. **Context refresh**
   - Run `dk sync` unless `--no-sync` is set.
   - Load `.doyaken/memory/index.md` first, then only scoped active memory.
   - Treat memory as context to verify, not proof.

3. **Risk-surface selection**
   - Combine durable memory, recent churn, recent `fix:` commits, CI failures,
     review findings, dependency manifests, and configured focus domains.
   - Cap selected surfaces with `--max-surfaces`.
   - Record why each surface was selected.

4. **Deterministic checks**
   - Reuse the `dkverify` discovery model where possible.
   - Prefer commands that match selected surfaces.
   - Enforce per-command and total runtime budgets.

5. **Semantic review**
   - Run a focused review pass modeled on `dkreviewloop`, but scoped to selected
     surfaces rather than the full ticket diff.
   - Build context first, run deterministic checks first, and require evidence
     before reporting findings.

6. **Triage and action decision**
   - Classify findings as reproducible bug, likely issue, documentation/rule
     gap, guard opportunity, stale memory, or noise.
   - Drop low-confidence findings.
   - In `report` mode, stop after the report.
   - In PR modes, patch only findings that satisfy the PR creation criteria.

7. **Verification and publication**
   - Re-run affected checks.
   - Run focused review on any diff.
   - Write a report artifact every time.
   - Open at most the configured number of draft PRs.
   - Label maintenance PRs, for example `doyaken-maintenance`, so event-driven
     workflows can distinguish them from human-authored PRs.
   - Request Copilot review on opened draft PRs with
     `gh pr edit <number> --add-reviewer @copilot` when enabled. Optionally add
     `--add-assignee @copilot` only when the repo explicitly wants Copilot cloud
     agent ownership rather than code-review feedback.

8. **State update**
   - Persist run metadata outside the repo.
   - Record last successful run ref/time so local/persistent runners can choose
     better future `--since` defaults; hosted scheduled workflows need
     cache/artifact persistence before they can reuse that state across runs.
   - Send durable learning candidates through `dk sync`; do not write raw
     observations directly into trusted memory.

9. **PR feedback response**
   - For maintenance PRs only, react to `issue_comment`,
     `pull_request_review`, and `pull_request_review_comment` events.
   - Run a one-shot `dk maintain respond --pr <number>` command that gives the
     provider pinned PR context and structured response artifact paths.
   - Fix valid comments locally, write bounded reply artifacts, and let the
     wrapper recheck PR provenance before pushing commits or publishing replies.
     Explain why non-fixes are out of scope or inconsistent with repo patterns.
   - Escalate architectural, unclear, or product-scope comments instead of
     deciding autonomously.
   - Re-request Copilot and configured reviewers after a push.

## State And Artifacts

Run state should stay outside the repository, following existing Doyaken phase
and artifact patterns.

Proposed defaults:

```text
~/.claude/.doyaken-maintenance/
  <session-id>.lock
  <session-id>.last-success   # local/persistent runners; hosted runners need cache/artifact persistence
  <session-id>.state

~/.claude/.doyaken-artifacts/maintenance/
  <run-id>/
    report.md
    commands.log
    findings.json
    selected-surfaces.md
```

State files are operational metadata, not durable memory. Durable lessons must
be promoted through `dk sync` into a reviewable repo diff.

## Configuration Surface

V1 can start with flags and conservative defaults. A later version should add a
repo config section, either in `.doyaken/doyaken.md` or a dedicated
`.doyaken/maintenance.md`.

Candidate config:

```yaml
maintenance:
  default_mode: report
  max_runtime_minutes: 90
  command_timeout_seconds: 120
  max_surfaces: 5
  max_prs: 1
  install_github_workflow: false
  github_workflow_name: DK maintain
  github_label: doyaken-maintenance
  copilot_review: true
  copilot_assignee: false
  token_secret: DK_MAINTAIN_TOKEN
  safe_fix_categories:
    - docs
    - tests
    - doyaken-context
  focus_domains:
    - review-quality
    - workflow-operations
  scheduled_sync: true
```

Keep provider launch, worktree handling, and external state path defaults aligned
with existing Doyaken libraries instead of creating separate conventions.

## GitHub Workflow Template

Yes: Doyaken should ship an installable GitHub workflow template called
`DK maintain`.

There are two distribution shapes:

- **Per-repo install**: Doyaken ships
  `templates/github/workflows/dk-maintain.yml`, and `dk maintain
  install-workflow` copies it to `.github/workflows/dk-maintain.yml` in the
  target repo. This fits `dk init` and normal Doyaken install flows.
- **Organization template**: an organization can also publish the same workflow
  under `.github/workflow-templates/dk-maintain.yml` with matching metadata, but
  that packaging is intentionally deferred until Doyaken ships an org-template
  layout. The first implementation only installs directly into a target repo.

The per-repo installer should be explicit, not automatic by default, because the
workflow needs write permissions and may consume provider/GitHub minutes. Good
entry points:

```bash
dk init --install-maintenance-workflow
dk maintain install-workflow
dk maintain install-workflow --force
```

The installed workflow should have one name but two jobs:

1. **Nightly maintenance job**
   - Triggers on `schedule` and `workflow_dispatch`.
   - Checks out the default branch.
   - Bootstraps Doyaken from the source repo/ref pinned by the installer.
   - Runs an optional `DK_MAINTAIN_PROVIDER_SETUP` secret before provider use
     through stdin, not shell argv; if no provider is available, it writes a
     skipped report instead of failing noisily on every schedule.
   - Runs the bash-compatible sync script and maintain script.
   - Uploads the maintenance report artifact.
   - Opens at most one draft PR when the selected mode allows it.
   - Requests Copilot review immediately after PR creation when enabled.

2. **Maintenance PR feedback job**
   - Triggers on `issue_comment`, `pull_request_review`, and
     `pull_request_review_comment`.
   - Runs a deterministic preflight before checkout/provider setup and proceeds
     only for trusted comments on PRs labeled `doyaken-maintenance` and
     branches matching a Doyaken maintenance branch prefix.
   - Checks out the immutable PR head SHA only after confirming the PR is a
     same-repository Doyaken maintenance PR. Fork PR response is out of scope
     for V1.
   - Runs `dk maintain respond --pr <number> --event <event-kind>`.
   - Delegates comment handling to `dkprreview` so every comment receives either
     a fix, an inline answer, or an escalation.

Skeleton:

```yaml
name: DK maintain

on:
  workflow_dispatch:
    inputs:
      mode:
        description: Doyaken maintenance mode
        required: false
        default: report
        type: choice
        options: [report, propose, fix-scoped]
      since:
        description: Git ref/date used to bound recent-history scanning
        required: false
        default: ""
  schedule:
    - cron: "17 2 * * *"
  issue_comment:
    types: [created]
  pull_request_review:
    types: [submitted]
  pull_request_review_comment:
    types: [created]

permissions:
  {}

concurrency:
  group: dk-maintain-${{ github.repository }}-${{ github.event.issue.number || github.event.pull_request.number || github.run_id }}
  cancel-in-progress: false

jobs:
  nightly:
    if: ${{ github.event_name == 'schedule' || github.event_name == 'workflow_dispatch' }}
    runs-on: ubuntu-latest
    timeout-minutes: 120
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd
        with:
          persist-credentials: false
      - name: Install Doyaken
        run: |
          # Replace with the installed Doyaken bootstrap command.
          bash install.sh
      - name: Run DK maintain
        run: |
          # Provider job has no GitHub write token; it uploads report/patch state.
          bash "$DOYAKEN_DIR/bin/maintain.sh" --nightly --mode "$MODE" --defer-publish "$STATE_FILE"

  publish:
    needs: nightly
    if: ${{ github.event_name == 'workflow_dispatch' && inputs.mode != 'report' }}
    permissions:
      contents: write
      pull-requests: write
      issues: write
      actions: read
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd
      - name: Publish deferred maintenance PR
        env:
          DK_MAINTAIN_TOKEN: ${{ secrets.DK_MAINTAIN_TOKEN }}
        run: |
          # Fresh trusted Doyaken checkout applies the uploaded patch/state.
          bash "$DOYAKEN_DIR/bin/maintain.sh" publish --state-file "$STATE_FILE"

  respond:
    if: ${{ (github.event_name == 'issue_comment' && github.event.issue.pull_request) || github.event_name == 'pull_request_review' || github.event_name == 'pull_request_review_comment' }}
    runs-on: ubuntu-latest
    timeout-minutes: 45
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd
        with:
          persist-credentials: false
      - name: Install Doyaken
        run: |
          bash install.sh
      - name: Respond to maintenance PR feedback
        run: |
          # Response provider job has no GitHub write token; it uploads patch/reply state.
          bash "$DOYAKEN_DIR/bin/maintain.sh" respond --pr "$PR_NUM" --trusted-preflight --defer-publish "$STATE_FILE"

  publish-response:
    needs: respond
    permissions:
      contents: write
      pull-requests: write
      issues: write
      actions: read
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd
      - name: Publish maintenance PR response
        env:
          GH_TOKEN: ${{ secrets.DK_MAINTAIN_TOKEN }}
        run: |
          bash "$DOYAKEN_DIR/bin/maintain.sh" publish-response --state-file "$STATE_FILE"
```

The skeleton shows intent, not final syntax. The shipped template keeps
permissions job-scoped, pins third-party actions to commit SHAs, writes
artifacts to a non-hidden runner temp directory, uses a stable nightly
concurrency group, and performs the response preflight before checkout/provider
setup. Implementation must verify GitHub expression compatibility and
provider-specific setup snippets before shipping broadly.

### Authentication

The default `GITHUB_TOKEN` can write branches, comments, and review requests
inside the repo when workflow permissions allow it, but it does not trigger most
follow-up workflows from events it creates and should not be exposed to report
mode agents. The workflow should therefore support:

- `DK_MAINTAIN_TOKEN`: optional PAT or GitHub App installation token for teams
  that want downstream CI/review workflows to trigger normally.
- no token fallback for report mode; report and dry-run launches scrub GitHub
  write credentials before invoking the provider.
- write-capable workflow runs split provider and publication into separate jobs:
  provider jobs do not receive GitHub write-token environment variables and
  upload bounded patch/state artifacts; publish-only jobs use a fresh trusted
  Doyaken checkout plus `DK_MAINTAIN_TOKEN` to apply the patch, push, open or
  update PRs, request reviewers, and post response comments.
- clear report output when token permissions prevent branch push, PR creation,
  reviewer request, or comment reply.

### Copilot Review

When maintenance opens a draft PR, it should:

1. add a `doyaken-maintenance` label;
1. add a provenance marker to the PR body that ties the branch run id to the
   Doyaken-created PR;
2. request configured `request` reviewers from `.doyaken/doyaken.md`;
3. request Copilot review with `gh pr edit <number> --add-reviewer @copilot`
   when Copilot review is enabled;
4. optionally add Copilot as assignee with
   `gh pr edit <number> --add-assignee @copilot` only if the repo config
   explicitly chooses Copilot cloud-agent ownership;
5. re-request Copilot and other configured reviewers after every Doyaken push.

Reviewer parsing should normalize `Copilot`, `@copilot`, and other configured
aliases to the GitHub CLI special value `@copilot`. Do not strip the `@` from
this special value even though normal GitHub usernames should be passed without
the leading `@`.

Do not rely only on repository automatic Copilot review settings. Automatic
review of drafts and new pushes is configurable, so Doyaken should explicitly
request the review it needs.

## Loop Strategy

The workflow should not contain an unbounded polling loop. It should call the
CLI, and the CLI should run bounded internal loops.

V1 needs two loop shapes:

1. **Pre-publish loop inside `dk maintain`**
   - Run deterministic checks.
   - Patch only eligible findings.
   - Run focused semantic review on the generated diff.
   - Repeat until the diff is clean or the maintenance budget is exhausted.
   - Publish only after the loop has a clean result.

2. **Event-driven feedback loop after PR creation**
   - Do not run a long-lived watcher in GitHub Actions.
   - Let GitHub events trigger one-shot response jobs.
   - Each job runs `dk maintain respond --pr <number>`, giving the provider
     pre-collected review context while withholding GitHub write credentials.
   - The provider job writes bounded patch/reply artifacts. A separate publish
     job with a fresh trusted Doyaken checkout pushes valid fixes, posts
     bounded structured response summaries and inline review-comment replies,
     and re-requests reviewers; the next reviewer comment/review triggers
     another one-shot response.

This keeps the reusable behavior in Doyaken skills/prompts while allowing GitHub
Actions to provide scheduling and event delivery.

## Skill And Prompt Layering

The long-term pattern should be:

```text
prompt -> skill -> CLI command -> scheduled/event workflow
```

Each layer should add orchestration, not duplicate the previous layer:

- `prompts/maintain.md` defines the provider-neutral maintenance contract.
- `skills/dkmaintain/SKILL.md` makes the flow usable inside an agent session.
- `bin/maintain.sh` and `dk maintain` make the same flow runnable from a shell,
  cron, or CI.
- `templates/github/workflows/dk-maintain.yml` schedules and routes events to
  the CLI.
- `dk maintain respond` reuses `skills/dkprreview/SKILL.md` rather than
  creating a second comment-review framework.

Maintenance tasks can then become domain-specific prompt modules without
becoming separate products. Candidate modules:

| Module | Purpose | Reuses |
|--------|---------|--------|
| `maintain-risk-selection` | Pick surfaces from memory, git history, CI, reviews | `sync-memory.md`, memory index |
| `maintain-deterministic-checks` | Choose and run bounded checks | `dkverify`, `failure-recovery.md` |
| `maintain-review` | Focused self-review before publish | `dkreview`, `review-wave.md` |
| `maintain-pr-publication` | Draft PR body, labels, reviewers, Copilot | `dkpr`, `pr-description.md` |
| `maintain-pr-response` | Inline replies and fixes for review feedback | `dkprreview`, `dkwatchpr` |

Avoid creating a new prompt for a domain if an existing Doyaken skill already
owns the behavior. Extend the existing skill when the behavior is the same
workflow in a new context; add a new prompt only when maintenance needs a
different contract or output schema.

## PR Creation Criteria

The agent may open a draft PR only when at least one of these is true:

- A test, check, or reproduction fails before the change and passes after it.
- A missing guard or rule addresses a repeated observed failure pattern.
- A documentation or memory update captures a durable lesson with evidence.
- A dependency, CI, or test fix is narrow, deterministic, and verified.

Every maintenance PR should be identifiable as agent-owned maintenance work:

- branch prefix such as `doyaken/maintain/<run-id>`;
- label such as `doyaken-maintenance`;
- draft status by default;
- PR body section listing the maintenance run id, selected surfaces, memory/rules
  consulted, deterministic checks, focused review result, and token mode;
- Copilot review request when configured.

The agent should not open a PR for:

- style-only preferences;
- broad refactors;
- findings based only on best-practice claims;
- changes that require product or architecture judgment;
- multiple unrelated fixes bundled together;
- findings based only on unverified memory.

## Morning Artifact

Every run should end with a compact artifact:

```markdown
# Doyaken Maintenance Report

Run: 2026-05-15 nightly
Mode: report
Repo: owner/repo
Base: main@abc123
Sync: completed at main@abc123
Workflow: DK maintain
Token mode: GitHub App token

## Checked
- Risk surface 1: backend/auth/** — repeated review findings about ownership tests
- Risk surface 2: migrations/** — recent fix commits and CI failures
- Commands: npm test -- auth, npm run lint

## Findings
| ID | Status | Evidence | Action |
|----|--------|----------|--------|
| F-1 | Fixed in draft PR | test failed before, passed after | PR #123, Copilot requested |
| F-2 | Report only | likely issue, needs product call | Escalated |

## Not Promoted
- Observation about naming was one-off and contradicted nearby code.

## Unavailable Signals
- GitHub review comments unavailable: gh not authenticated.

## Next Suggested Run
- Focus migrations again after the pending schema PR merges.
```

For PRs, the description should reduce reviewer work:

- State the risk that was checked.
- Link to tests or commands that failed before and passed after.
- Explain why the fix is intentionally small.
- List memory/rules consulted.
- List what the agent deliberately did not change.
- Include the focused review result.

## Safety Controls

The first version needs strict safety controls:

- Always use an isolated worktree or branch.
- Never merge automatically.
- Default to `report`.
- Default scheduled PR creation to off.
- Limit max PRs per run.
- Limit max files changed per PR unless configured.
- Limit total runtime and per-command runtime.
- Cancel on secrets scan failures.
- Escalate architecture, product, data-loss, auth-policy, and destructive git
  decisions.
- Do not run scheduled watchers while a user is actively working in the same
  session.
- Do not run overlapping nightly jobs for the same repo.
- Do not use uncommitted working-tree evidence unless an explicit flag enables
  it.
- Do not let workflow event payload text become executable shell or untrusted
  prompt instructions. Treat PR comments as review input only after the PR is
  confirmed as a Doyaken maintenance PR.
- Do not check out or push to fork PR heads from the feedback workflow in V1.

Durable lessons discovered by a maintenance run should become `dk sync`
candidates, not direct trusted-memory edits.

## Design Patterns

| Pattern | Why it fits | Proposed location | Sub-tickets |
|---------|-------------|-------------------|-------------|
| Pipeline | The run has ordered, budgeted stages with explicit handoff data | `prompts/maintain.md`, `skills/dkmaintain/SKILL.md` | 1, 4, 5 |
| Strategy | Risk selectors and action policies vary by repo and mode | `lib/maintenance.sh`, prompt sections | 3, 10 |
| Adapter | GitHub/CI/review signals should degrade when integrations are missing | `prompts/maintain.md`, future helper scripts | 3, 7, 8 |
| Memento | Last run refs, locks, reports, and run metadata are external resumable state | `lib/maintenance.sh` | 2 |
| Chain of Responsibility | Findings move through evidence gates before report, patch, or PR | `prompts/maintain.md` | 5, 8 |
| Template Method | The GitHub workflow is a thin reusable wrapper around CLI-owned behavior | `templates/github/workflows/dk-maintain.yml` | 6 |

Rejected alternative: a seventh normal Doyaken phase. Maintenance starts from
repo risk scanning rather than a user ticket, so it should not inherit phase
ownership, approval, and PR expectations from the ticket lifecycle.

## Verification Criteria

### Command And State

1. `dk maintain --mode report --dry-run` exits successfully in a fresh repo with
   `.doyaken/` context and writes no repo changes.
2. A second scheduled run for the same repo exits with an overlap message while
   the first run lock is active.
3. Run state appears only under the configured external maintenance/artifact
   directories, never as untracked files in the repo.
4. Missing optional integrations are listed under unavailable signals without
   failing the run.

### Risk Selection

1. Given scoped memory and recent `fix:` commits, the report lists selected
   surfaces with a reason for each one.
2. `--focus <domain>` restricts selection to matching memory domains or paths.
3. `--max-surfaces 2` reports no more than two checked surfaces.
4. A memory entry whose scope does not match the task is not loaded into the run
   context.

### Deterministic Checks And Review

1. Deterministic commands are logged before semantic review starts.
2. A timed-out command is recorded as a bounded failure and does not leave the
   run hanging.
3. A semantic finding without file, command, or reproduction evidence is dropped
   into `Not Promoted`.
4. Focused review of a generated diff must pass before any draft PR is created.

### PR Modes

1. In `report` mode, no branch push or PR creation command runs.
2. In `propose --no-pr`, eligible `.doyaken/` changes remain local and the
   report says a PR was suppressed by configuration.
3. In PR-enabled mode, the agent creates at most `--max-prs` draft PRs.
4. A code PR includes failing-before/passing-after evidence or is blocked.

### GitHub Workflow

1. `dk maintain install-workflow` creates
   `.github/workflows/dk-maintain.yml` only when the user opts in.
2. The installed workflow is named `DK maintain` and includes
   `workflow_dispatch`, `schedule`, `issue_comment`, `pull_request_review`, and
   `pull_request_review_comment` triggers.
3. The nightly job calls Doyaken's bash-compatible sync and maintain scripts; it
   does not duplicate the maintenance prompt in YAML.
4. The feedback job runs only for Doyaken maintenance PRs and refuses unrelated
   PR comments.
5. If a token lacks `contents: write`, `pull-requests: write`, or `issues:
   write`, the run reports the missing permission and does not silently skip PR
   work.
6. A draft maintenance PR has the configured maintenance label and Copilot review
   request when `copilot_review: true`.
7. Configuring `Copilot`, `@copilot`, or the normalized Copilot alias produces
   `gh pr edit <number> --add-reviewer @copilot`, not
   `--add-reviewer Copilot`.

### PR Feedback Response

1. A PR-level comment triggers a one-shot response run through `issue_comment`
   only when it explicitly mentions `@doyaken` or `dk maintain`.
2. An inline review comment triggers a one-shot response run through
   `pull_request_review_comment`.
3. A submitted review triggers a one-shot response run through
   `pull_request_review`.
4. Each unaddressed comment receives either a fix commit plus wrapper-published
   inline reply, a wrapper-published explanation for not fixing, or an
   escalation report.
5. After a fix push, Copilot and configured reviewers are re-requested.

## Proposed Sub-Tickets

These are sized for future `dk <subticket>` lifecycles. Domains use current repo
component names because the C4 architecture map is absent.

1. **Add maintenance command scaffold**
   - Domain: CLI command surface
   - Scope: add `dk maintain`, `bin/maintain.sh`, `/dkmaintain`, and
     `prompts/maintain.md` in report-only dry-run form, including a respond
     subcommand placeholder.
   - Depends-on: -
   - Primary paths: `dk.sh`, `bin/maintain.sh`, `skills/dkmaintain/SKILL.md`,
     `prompts/maintain.md`
   - Size: M
   - Pattern: Pipeline

2. **Add external maintenance state and locking**
   - Domain: Provider and state libraries
   - Scope: create shared helpers for run ids, lock files, artifact paths, last
     successful run markers, and overlap detection.
   - Depends-on: 1
   - Primary paths: `lib/maintenance.sh`, `lib/common.sh`, `docs/autonomous-mode.md`
   - Size: M
   - Pattern: Memento

3. **Implement risk-surface selector**
   - Domain: Project context and memory
   - Scope: select bounded surfaces from memory scopes, recent git history,
     changed hot spots, and optional integration signals.
   - Depends-on: 1, 2
   - Primary paths: `prompts/maintain.md`, `skills/dkmaintain/SKILL.md`,
     optional helper in `lib/maintenance.sh`
   - Size: M
   - Pattern: Strategy

4. **Integrate bounded deterministic checks**
   - Domain: Verification system
   - Scope: reuse `dkverify` discovery ideas to run scoped checks with command
     budgets, logging, unavailable-signal reporting, and failure triage.
   - Depends-on: 1, 2, 3
   - Primary paths: `skills/dkverify/SKILL.md`, `prompts/maintain.md`,
     `prompts/failure-recovery.md`
   - Size: M
   - Pattern: Pipeline

5. **Add focused semantic review and finding gates**
   - Domain: Review system
   - Scope: adapt review-wave discipline for selected surfaces and require
     evidence gates before reporting, patching, or PR creation.
   - Depends-on: 3, 4
   - Primary paths: `skills/dkreview*/SKILL.md`, `prompts/review-wave.md`,
     `prompts/maintain.md`
   - Size: M
   - Pattern: Chain of Responsibility

6. **Add installable DK maintain GitHub workflow**
   - Domain: GitHub workflow integration
   - Scope: ship `templates/github/workflows/dk-maintain.yml` and an explicit
     install command that copies the workflow into `.github/workflows/`; defer
     organization workflow-template packaging until a matching template layout
     exists.
   - Depends-on: 1, 2
   - Primary paths: `templates/github/workflows/dk-maintain.yml`,
     `bin/maintain.sh`, `docs/background-maintenance-agent-plan.md`
   - Size: M
   - Pattern: Template Method

7. **Enable draft PR publication and Copilot review request**
   - Domain: PR and watcher system
   - Scope: allow `propose` mode to open at most one draft PR for verified
     `.doyaken/` memory, rule, guard, or doc updates; label it
     `doyaken-maintenance`; request Copilot review when configured; normalize
     Copilot reviewer handles to `@copilot`.
   - Depends-on: 1, 2, 5
   - Primary paths: `skills/dkpr/SKILL.md`, `skills/dkcommit/SKILL.md`,
     `prompts/pr-description.md`, `prompts/maintain.md`, `.doyaken/doyaken.md`
   - Size: M
   - Pattern: Adapter

8. **Add event-driven PR feedback response**
   - Domain: PR and watcher system
   - Scope: implement `dk maintain respond --pr <number>` as a one-shot workflow
     bridge that delegates to `/dkprreview --reply=inline`, replies to every
     comment, pushes valid fixes, and re-requests reviewers after pushes.
   - Depends-on: 1, 2, 6, 7
   - Primary paths: `bin/maintain.sh`, `skills/dkmaintain/SKILL.md`,
     `skills/dkprreview/SKILL.md`, `skills/dkwatchpr/SKILL.md`,
     `templates/github/workflows/dk-maintain.yml`
   - Size: M
   - Pattern: Adapter

9. **Add scheduled-run documentation and manual test harness**
   - Domain: Documentation
   - Scope: document cron/GitHub Actions/manual operation, trust modes, report
     review, and a local fixture-based manual verification workflow.
   - Depends-on: 1, 2, 3, 6
   - Primary paths: `docs/background-maintenance-agent-plan.md`,
     `docs/autonomous-mode.md`, `README.md`
   - Size: S
   - Pattern: none

10. **Add scoped fix categories after reports prove useful**
   - Domain: CLI command surface
   - Scope: implement `fix-scoped` for configured low-risk categories such as
     docs, tests, `.doyaken/` context, and CI metadata.
   - Depends-on: 4, 5, 7, 8
   - Primary paths: `bin/maintain.sh`, `skills/dkmaintain/SKILL.md`,
     `prompts/maintain.md`, `.doyaken/doyaken.md`
   - Size: L
   - Pattern: Strategy

## Estimation Summary

Size mix: 10 sub-tickets: 1 x S, 8 x M, 1 x L.

Critical path: 1 -> 2 -> 3 -> 4 -> 5 -> 7 -> 8 -> 10. The first usable V1 can
stop after sub-ticket 5 in `report` mode; sub-ticket 6 makes it schedulable from
GitHub Actions, sub-ticket 7 enables context-only PRs with Copilot review, and
sub-ticket 10 should wait until reports are trusted.

Parallelizable work: sub-ticket 6 can run after the scaffold and state model are
clear. Sub-ticket 9 can run once the command and workflow shape are stable.
Sub-tickets 4 and 5 can be designed in parallel once the risk selector output
shape is stable, but implementation should sequence deterministic checks before
semantic review.

Riskiest estimate: sub-ticket 10, because safe autonomous fixes depend on how
well report-mode evidence performs in real repos.

Per-domain rollup:

| Domain | Count | Size mix |
|--------|-------|----------|
| CLI command surface | 2 | 1 x M, 1 x L |
| Provider and state libraries | 1 | 1 x M |
| Project context and memory | 1 | 1 x M |
| Verification system | 1 | 1 x M |
| Review system | 1 | 1 x M |
| GitHub workflow integration | 1 | 1 x M |
| PR and watcher system | 2 | 2 x M |
| Documentation | 1 | 1 x S |

## Risk Register

| Risk | Likelihood | Impact | Mitigation | Owner |
|------|------------|--------|------------|-------|
| Low-signal nightly reports train users to ignore the agent | Medium | High | Default to few surfaces, require evidence, track rejected observations | Maintenance command owner |
| Agent trusts stale memory and reports false findings | Medium | High | Re-verify memory against current code and record recheck conditions | Memory/risk selector owner |
| Scheduled runs overlap with manual work or each other | Medium | High | External locks, watcher pause markers, clean worktree preflight | State owner |
| Deterministic checks run too long or consume too much budget | Medium | Medium | Per-command timeout, total budget, scoped checks first | Verification owner |
| Draft PRs bundle unrelated changes | Medium | Medium | `max-prs`, one finding family per PR, focused review before publish | PR owner |
| Workflow responds to unrelated or untrusted PR comments | Medium | High | Require `doyaken-maintenance` label, branch prefix, PR-body provenance marker, pinned head SHA checkout, and same-repo checks before writes | Workflow owner |
| `GITHUB_TOKEN` push does not trigger downstream CI/review automation | High | Medium | Require `DK_MAINTAIN_TOKEN` GitHub App/PAT for write modes and report token mode explicitly | Workflow owner |
| Copilot does not review drafts or new pushes in a repo's current policy | Medium | Medium | Explicitly request/re-request `@copilot` and surface Copilot review status in the report | PR owner |
| Provider-specific hooks become required for correctness | Low | Medium | Prompt-level pre/post instructions are canonical; hooks are accelerators | Skill/prompt owner |
| Safe fix categories are too broad | Medium | High | Delay `fix-scoped` until report/propose data proves categories safe | Maintainer/user |

## Manual Test Plan

Use a temporary fixture repo and this repo.

1. **Report-only smoke test**
   - Run `dk maintain --mode report --dry-run --max-surfaces 2`.
   - Expected: no repo diff, report lists selected surfaces, commands, skipped
     integrations, and no PR action.

2. **Memory retrieval scope test**
   - Create or use memory domains with distinct path scopes.
   - Run `dk maintain --focus review-quality --dry-run`.
   - Expected: only review-quality memory is loaded; unrelated domains are not
     cited as active context.

3. **No working-tree evidence test**
   - Add an uncommitted change that appears to create a maintenance finding.
   - Run `dk maintain --mode report --dry-run`.
   - Expected: the CLI refuses to run and asks for `--include-working-tree`.
     Re-run with `--include-working-tree`; the report may inspect the local
     evidence but must mark it as untrusted local evidence.

4. **Unavailable integration test**
   - Run without GitHub auth or CI access.
   - Expected: the run completes and lists unavailable GitHub/CI signals.

5. **Budget test**
   - Configure a very short command timeout and include a slow check in a fixture.
   - Expected: timeout is captured in the report and the process exits cleanly.

6. **Propose no-PR test**
   - Run a scenario that would produce a `.doyaken/` update with
     `--mode propose --no-pr`.
   - Expected: changes are isolated to the maintenance worktree, the report says
     PR creation was suppressed, and no push/PR command ran.

7. **Lock test**
   - Create a fake active maintenance lock for the repo session id.
   - Run `dk maintain --nightly`.
   - Expected: the command exits with an overlap message and does not start a
     second run.

8. **Draft PR gating test**
   - In a throwaway remote branch, allow PR mode for a context-only update.
   - Expected: at most one draft PR opens, the PR body includes checked surfaces,
     memory/rules consulted, verification evidence, and deliberate non-changes.

9. **Workflow install test**
   - Run `dk maintain install-workflow` in a fixture repo before and after
     `dk init`.
   - Expected before init: the command refuses installation and tells the user
     to run `dk init`.
   - Expected: `.github/workflows/dk-maintain.yml` is created with name
     `DK maintain`, explicit permissions, concurrency, schedule/dispatch
     triggers, and review/comment event triggers.

10. **Copilot request test**
   - In a throwaway repo with Copilot review enabled, create a draft maintenance
     PR. Repeat with reviewer config values `Copilot` and `@copilot`.
   - Expected: the PR has the maintenance label and `@copilot` is requested as a
     reviewer; if the request fails, the report records the exact `gh` error.

11. **Feedback response trigger test**
   - Add a PR-level comment containing `@doyaken` or `dk maintain`, an inline
     review comment, and a submitted review to a labeled maintenance PR.
   - Expected: each eligible event launches a one-shot response run; ordinary
     PR-level comments and unrelated PRs do not trigger writes.

12. **Inline reply/fix test**
   - Add one actionable review comment and one out-of-scope comment.
   - Expected: Doyaken fixes the actionable comment, pushes once, replies inline
     with the commit SHA, explains the non-fix inline or escalates, and
     re-requests configured reviewers.

## Open Questions

1. Should `dk maintain` always run `dk sync` first, or only when the memory index
   is stale? Owner: maintainer.
2. Should report artifacts live only under `DK_ARTIFACT_DIR`, or should scheduled
   runs optionally publish GitHub issues/comments? Owner: maintainer/team.
3. What first `fix-scoped` categories are safe enough: docs, tests,
   `.doyaken/` context, CI metadata, dependency metadata? Owner: maintainer.
4. Should `dk init` offer the workflow install interactively, or should workflow
   install stay behind an explicit `dk maintain install-workflow` command?
   Owner: maintainer.
5. What budget presets should larger repos use beyond the V1 default 60-minute
   local budget and 100-minute workflow budget? Owner: maintainer.
6. Should report mode also move to a disposable worktree, or is in-place
   read-only execution with mutation detection sufficient? Owner: maintainer.
7. How should formal sub-ticket domains be renamed after `/dkarchitect` creates
   `.doyaken/architecture.md`? Owner: refinement follow-up.
8. Should `DK_MAINTAIN_TOKEN` be a PAT or a GitHub App installation token in
   the recommended setup? V1 requires the secret for PR-writing modes and does
   not fall back to `github.token`. Owner: maintainer/security.
9. Should Copilot be only a requested reviewer, or should repos be allowed to
   opt into `@copilot` assignee/coding-agent ownership for maintenance PRs?
   Owner: maintainer/team.
10. Should the final implementation use one `DK maintain` workflow with two jobs,
   or split scheduled maintenance and PR feedback into separate workflow files?
   Owner: workflow owner.

## Decision Log

- 2026-05-15: Chose `dk maintain` as the primary command name.
- 2026-05-15: Kept maintenance separate from the normal six-phase ticket
  lifecycle.
- 2026-05-15: Defaulted scheduled runs to `report` mode with no PR creation.
- 2026-05-15: Required external run state and reviewable `dk sync` promotion for
  durable memory.
- 2026-05-15: Flagged missing `.doyaken/architecture.md`; formal C4 domain
  mapping should follow `/dkarchitect`.
- 2026-05-15: Added an installable GitHub Actions workflow direction named
  `DK maintain`.
- 2026-05-15: Chose event-driven one-shot PR feedback responses instead of a
  long-running GitHub Actions polling loop.
- 2026-05-15: Chose Copilot requested-reviewer integration by default, with
  Copilot assignee/coding-agent ownership as explicit opt-in.
