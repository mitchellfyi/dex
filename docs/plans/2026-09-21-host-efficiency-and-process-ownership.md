# Agent prompt: make Dex sessions efficient citizens of a shared host

You are working on Dex, the codebase-agnostic, machine-agnostic agent
lifecycle tool in this repository. Your task is to change how Dex runs
agents so that several concurrent Dex sessions on one developer machine do
the same quality of work with a fraction of the CPU, memory, disk and
filesystem churn they use today, and so that nothing an agent starts
outlives the session that started it.

Read this whole document before touching code. It contains an incident
report with measured numbers, a survey of the Dex code paths involved
(with file and line references that were accurate on 2026-09-21; re-verify
them), a set of principles you must not violate, and a prioritised list of
work items with acceptance criteria. Work through the items in the order
given in section 5, one commit per item, with tests in `tests/` for every
behavioural change.

---

## 1. The non-negotiable principles

1. **Capability is not the lever.** Do not make agents do less review,
   fewer tests, or shallower verification. Make the same work cheaper by
   making it targeted, sequenced and shared. Any change whose only effect
   is "the agent may skip X" is wrong.
2. **Ownership, not policing.** Every process, port, temp dir and database
   an agent creates belongs to the session that created it. The session
   records it, the session removes it. Cleanup is a property of the
   launch path, not a separate janitor that guesses. A hidden background
   reaper that kills things it did not start is explicitly out of scope:
   the maintainer rejected it as too custom and too easy to forget.
3. **Visible and inspectable.** A human must be able to run one command
   and see what every Dex session on the host currently owns, what is
   queued, and what is orphaned, before anything is stopped. Default to
   dry-run; require an explicit flag to act.
4. **Swarm awareness.** An agent must know it is one of N on this host and
   be told, in numbers it can act on, how much capacity it has right now.
   Teach agents what to do when the host is busy: sequence heavy work,
   queue behind the lease, and do CPU-light work while waiting. Never
   teach them to bypass the queue.
5. **Codebase-agnostic and machine-agnostic.** Nothing may hard-code a
   repository, a command, a port, a database name, a core count or a
   memory size. Per-project facts live in the project's `.dex/dex.md`
   contract. Per-host facts are measured at runtime, and every measurement
   must have a conservative fallback when the host cannot provide it (no
   `lsof`, no libproc, a container with no load average, a CI runner with
   a cgroup limit below the physical machine). Design for the whole range
   at once: a 2-core / 8 GB laptop running one session, a 32-core / 128 GB
   workstation running twelve, a headless Ubuntu server reached over SSH
   where there is no interactive user to protect but a dozen sessions to
   keep fair, a Linux VM with 4 GB and no swap, a throttled CI container.
   The incident below happened on one of these shapes; it is calibration
   data, not a target.
6. **Slower is acceptable, blocking is not.** A session that takes twice
   as long because it queued behind another session's gate has cost
   nothing that matters. A session that finishes fast by pushing three
   other sessions and the human's browser into swap has. When in doubt,
   yield: lower priority, queue, sequence.
7. **Prose is not enforcement.** Every cleanup or resource obligation that
   today exists only as text in `prompts/` must gain either a mechanism
   that makes it automatic or a check that verifies it. Keep the prose
   too, but do not rely on it.

---

## 2. Incident report: one machine, one afternoon

This section describes a single host on a single day. Treat every number
in it as an example of the failure shape, not as a threshold to design
for. The same Dex behaviour on a smaller machine would have failed
sooner with fewer sessions; on a larger one it would have failed later
with more. Your changes are correct when they make the outcome depend on
the measured host, whatever it is, rather than on luck.

The host in question: 12 cores, 24 GB RAM, macOS, 20 days uptime, one
developer's laptop that also runs a browser, an editor and a screen
recorder. Five interactive Dex lifecycle sessions were running in five
worktrees of one Rails repo.

What was found, in one snapshot:

| Item | Measured |
|---|---|
| Swap in use | 24.9 GB of 28 GB (26 one-GB swapfiles) |
| Load average | 54 to 65 |
| Detached `bin/verify` trees with ppid 1 | 4 concurrently, 12 test workers each, 400 to 570 MB per worker |
| Memory held by those four runs | about 21 GB |
| Rails test step, one run alone | 2m45s to 3m40s |
| Rails test step, four runs at once | 57 to 63 minutes each |
| Sessions still alive for those runs | 2 of 4; the other two had exited an hour earlier |
| Leftover puma servers | 3 (one 22 hours old on a worktree the UI-proof flow had already deleted), each with 3 `fsevent_watch` children |
| Leftover MCP servers with ppid 1 | `codegraph serve --mcp` 1 day old, 192 MB |
| Stale `tail -F` to `grep` pipelines and `sleep 3600` keepers | 12, aged 3 to 17 days |
| Orphan per-worktree Postgres databases | 156 (3.2 GB) from removed worktrees |
| Leaked test temp dirs in `$TMPDIR` | 28,521 in three days (a project test bug, but Dex sessions ran the tests) |
| Chrome-for-Testing `--isolated` profiles in `$TMPDIR` | dozens |
| `fseventsd` (macOS file-events daemon) | 23 GB footprint, 100 percent CPU, string table of 9.7 million paths |

The four verify runs together would have completed in about 20 minutes
if run one after another. Run together they took 65 minutes each and
pushed the machine into swap, which then slowed every other session,
including the browser the human was using.

The detached verify launchers (`verify-launch.sh`, `verify1.sh`,
`/tmp/dxw<ticket>/verify_run.sh`, `runtime-owner-keeper.sh`) were not
written by Dex. Agents invented them, because the shell tool's foreground
limit is shorter than a full gate and Dex gave them no sanctioned way to
run a long command that survives the tool call yet dies with the session.
Every one of those scripts used `nohup … & disown`, which reparents the
tree to launchd and puts it beyond the reach of Dex's `pgrep -P` tree
walk.

The `fseventsd` growth is a side effect worth understanding: on macOS,
every distinct path that changes costs the daemon memory for the life of
the boot, and the daemon's CPU rises with the size of that table. Test
suites that truncate hundreds of database relations per run (each
truncate mints new file names), fresh worktrees with `node_modules` and
build caches, thousands of `mktemp` directories, and per-launch browser
profiles are all path-minting machines. Reducing churn is a real win on
this platform, not just tidiness.

---

## 3. Survey of the Dex code involved

File and line references were taken on 2026-09-21 against commit
`80cc975`. Re-check each before editing.

### 3.1 Architecture you will touch

- `dx.sh` is the sourced zsh library and CLI dispatcher. `dx <ticket>`
  creates a worktree (`dx.sh:880`) and runs six phases through
  `__dx_run_phases_inline` (`dx.sh:2957`), launching one provider CLI per
  phase at `dx.sh:3168-3186` via `dx_provider_run_session`.
- The Stop hook `hooks/phase-loop.sh` audits each phase against
  `prompts/phase-audits/<n>-*.md` and emits the next-phase message
  (`hooks/phase-loop.sh:505-539`).
- A per-phase watchdog subshell is disowned at `dx.sh:3124-3166`. It kills
  the provider tree on timeout, but the default timeout is 0, disabled
  (`dx.sh:434`), and its `__dx_kill_process_tree` (`dx.sh:486`) walks
  `pgrep -P`, which cannot reach a reparented process.
- `bin/session-runtime-owner.sh` (launched from
  `lib/session-runtime.sh:2035`) supervises the session record and lease.
  It does not supervise child processes.
- `hooks/session-end.sh` records an end timestamp and removes a context
  file. It stops nothing.
- Phase 3 is `lib/review-loop.sh`. Risk tier sets required consecutive
  clean waves 1/2/3 (`lib/review-policy.sh:54`) and wave budgets 3/6/9
  (`lib/review-policy.sh:33-42`). Each wave is a fresh provider session.
- `lib/review-capacity.sh` is the only host-wide admission control: a
  FIFO lease with two pools, waves (default 3,
  `DEX_REVIEW_MAX_ACTIVE_WAVES`, lines 45-49) and checks (default 1,
  `DEX_REVIEW_MAX_ACTIVE_CHECKS`, lines 51-55). It is PID-reuse safe and
  prunes stale owners (`__dx_review_capacity_prune_locked`, line 80).
  The wave limit is a constant and ignores `__dx_review_host_cpu_count`
  (`lib/review-capacity.sh:34-40`).
- `bin/review-check.sh` is the only sandboxed command runner: lease plus
  timeout plus cache. `DEX_REVIEW_CHECK_TIMEOUT` (default 900 s, line 24)
  bounds queue waiting (lines 62-66, returns 124 at 69) and, separately,
  execution (line 80). A timed-out run is discarded (line 81).
- `dx_run_with_timeout` (`lib/session.sh:2128-2208`) is a genuinely good
  reaper: every command under it inherits `DX_TIMEOUT_PROCESS_TOKEN` and
  an open fd 9 on a token file (`lib/session.sh:2133-2139`), and cleanup
  finds daemonized survivors by descriptor identity via macOS libproc
  with an `lsof` fallback (`lib/session.sh:1836-1938`; there is no
  `/proc/<pid>/fd` path, so on Linux it depends on `lsof` being installed), `__dx_timeout_terminate_processes` at
  `2009-2052`). It handles children that daemonize before the exit
  snapshot (`2025-2030`). Its call sites are `bin/review-check.sh:80`,
  `bin/sync.sh:349`, `bin/maintain.sh:1536,1560`,
  `lib/review-loop.sh:214,223`, `lib/git.sh:107`, `lib/agent-tools.sh:242`.
  **The interactive lifecycle provider session at `dx.sh:3168-3186` is
  not launched through it.** That is the single largest gap.
- `__dx_review_test_jobs` (`lib/review-loop.sh:474-490`) computes
  `cpu_count / 2 / capacity_limit`, clamped to 1..4, and exports
  `DEX_REVIEW_TEST_JOBS` and `DX_TEST_JOBS` (`lib/review-loop.sh:2241-2242`
  and `2282-2283`). No project reads those names. Phases 2 and 4 get no
  job budget at all.
- Scouts are provider-native subagents (`prompts/review-wave.md:146-150`,
  "Use provider-native agents for independent, read-only scouting"). They
  run inside the wave's own provider process, so they add no processes;
  their cost is that each one re-reads the diff and surrounding files,
  spends tokens and wall time, and splits the picture a coherence review
  needs. `__dx_review_scout_parallelism` (`lib/review-loop.sh:455-473`)
  allows `scout_count` concurrent scouts when the host wave limit is 1 and
  only 1 when the limit is greater; the inversion looks unintended.
- Review waves already run with MCP disabled
  (`lib/review-loop.sh:1179-1192`, `DEX_REVIEW_DISABLE_MCP` default on).
  Lifecycle phases 0 to 6 do not.
- `scripts/browser-mcp.cjs:18` appends `--isolated`, minting a fresh
  browser profile under `$TMPDIR` per launch; nothing removes them. MCP
  servers are installed at `--scope user` (`lib/ui-capture.sh:438,455`),
  so every Claude session on the host forks them whether or not the
  phase needs a browser.
- Worktree removal (`dx.sh:5172-5202` → `dx_wt_remove`,
  `lib/worktree.sh:57-69`) is `git worktree remove --force || rm -rf`
  plus three Dex-state cleanups. There is no project hook before or
  after create or remove, so a repo has nowhere to declare "drop the
  per-worktree database" or "free the dev-server port".
- `dxclean` (`dx.sh:5376-5569`) prunes worktrees and deletes Dex state
  files older than 7 days (`lib/worktree.sh:154-178`). It touches no
  processes, ports, databases or `$TMPDIR`. `dx sessions doctor`
  (`bin/sessions.sh:723-769`) validates record structure only. There is
  no host-wide process, port or database audit anywhere.
- `hooks/guards/` has nine guards; none concerns process detachment,
  even though `hooks/shell_parse.py:649,2531` already tokenises `nohup`
  and `setsid`.

### 3.2 What the prompts currently teach

Toward full-suite runs, everywhere:

- `skills/dxverify/SKILL.md:30-39` "Run every required command or check
  it names. Do not replace a named gate with an inferred, narrower
  alternative." and `:66` "Prefer a canonical aggregate command only when
  it covers every required gate."
- `prompts/phase-audits/2-implement.md:199` "All tests pass (run the test
  suite one final time to confirm)".
- `prompts/phase-audits/prompt-loop.md:131` "Test — run the full test
  suite".
- `prompts/guardrails.md:139,154` run the tests after every change and
  incrementally.
- The only counterweight is `prompts/review-wave.md:90` ("targeted
  tests") and `:127`.

Cleanup obligations that exist only as prose:

- `prompts/workflows/dximplement.md:229` "Clean up after yourself. Stop
  every process/server you started".
- `prompts/ui-proof.md:89` "Record every process you start so it can be
  stopped at handoff." and `:175` "Stop all servers and processes started
  for capture." The teardown snippet at `:173-187` removes only the
  baseline worktree, not the servers.
- `prompts/workflows/dximplement.md:184-185` "If a local port is busy,
  normally use another port" actively encourages port sprawl.
- Background-process completion criteria exist for Phases 0 and 2 only
  (`prompts/phase-audits/0-setup.md:112`,
  `prompts/phase-audits/2-implement.md:212`). Phases 3 to 6 have none;
  Phase 6 starts one (`/loop 5m /dxwatchpr`).
- No prompt mentions `nohup`, `disown`, `setsid`, `&`, or the shell
  tool's background mode at all.

Swarm awareness exists only in the review path
(`prompts/review-checks.md:53-58`, `skills/dxreview/SKILL.md:46-50`,
`skills/dxreviewloop/SKILL.md:38`). Nothing tells a Phase 2 or Phase 4
agent that other sessions exist on the machine.

Why agents bypass the check runner: with one host-wide check slot and a
900 s queue timeout, a second session's full gate is guaranteed to time
out in the queue, and a timed-out execution is discarded. The rational
agent response is to run the gate in a raw backgrounded shell call,
which is exactly what happened.

---

## 4. Work items

Do them in this order. Each is one PR-sized commit with tests. Where an
item changes a prompt, change the audit that checks it in the same
commit. Where an item adds a project-contract field to `.dex/dex.md`,
update `templates/` and the contract documentation, and make the default
behaviour with the field absent identical to today's.

### Item 1. Session process ownership: every child dies with its session

Goal: a process an agent starts during a Dex session cannot outlive the
session, however it was launched, and the human can see the list.

- Launch the lifecycle provider session (`dx.sh:3168-3186`) through the
  same fd-token mechanism `dx_run_with_timeout` uses, so every descendant
  inherits `DX_TIMEOUT_PROCESS_TOKEN` and fd 9, including ones that later
  `nohup`/`disown`/`setsid` themselves. Do not impose a timeout by doing
  this; the token is for ownership, the timeout stays configurable.
- Add a `/proc/<pid>/fd` scan to `__dx_timeout_token_pids` for Linux so
  the reaper works on Ubuntu without `lsof`; keep libproc on macOS and
  `lsof` as the last fallback. Measure host facts portably the same way:
  `getconf _NPROCESSORS_ONLN`, `/proc/meminfo` or `sysctl hw.memsize` and
  `vm_stat`, `/proc/loadavg` or `sysctl vm.loadavg`, and cgroup v2
  `cpu.max` / `memory.max` when present.
- On session end (normal exit, `hooks/session-end.sh`, watchdog kill,
  `dx control stop|cancel`, and the runtime owner noticing its parent is
  gone), run the token reaper: TERM, grace period, KILL, and log what was
  reaped with pid, command, age and RSS to the session's event log.
- Add a session temp root, `DX_SESSION_TMP`, created per session and
  exported to the provider. Teach `mktemp` users to put files under it
  (see Item 7). Remove it on session end after the reaper has run.
- Add `dx ps` (or extend `dx sessions`): list, per live session, the
  processes carrying its token, with pid, ppid, age, RSS, command and
  cwd; then list token-carrying processes whose session is gone
  (orphans). Dry-run by default. `dx ps --reap-orphans` stops orphans
  and prints what it stopped. This is the visible replacement for a
  hidden reaper.
- Add a PreToolUse guard (`hooks/guards/`) for the shell tool that
  recognises `nohup`, `disown`, `setsid`, a trailing `&` on a long
  command, and the harness's background mode. It does not block. It
  advises: "this will be owned by the session and stopped at session
  end; if you need it to survive, say so explicitly and record why."
  Reuse the tokenisation in `hooks/shell_parse.py`.
- Tests: a fake provider that spawns `sleep` via `nohup … & disown` and
  via `setsid`; assert both are gone after session end and appear in the
  reap log; assert `dx ps` lists them while alive and as orphans when the
  session record is removed underneath them.

### Item 2. Host-wide admission for heavy work in every phase

Goal: at most a host-appropriate number of heavy commands run at once
across all Dex sessions, regardless of phase, and every agent knows the
current capacity in numbers.

- Generalise `lib/review-capacity.sh` into a host capacity module with
  named pools. Keep `waves` and `checks`. Add `heavy` for project gates,
  test suites, builds and dev servers, used by Phase 2, Phase 4,
  `dxverify`, `dx test project` and UI capture, not only review.
- Derive pool limits from measured host facts at lease time, not
  constants: logical CPU count, available memory and current load (all
  measured portably on macOS and Linux, honouring a cgroup CPU or memory
  limit when one is lower than the machine's). When a measurement is
  unavailable, fall back to a conservative default and record that the
  fallback was used. Keep every environment override that exists today.
  Document the formula in `docs/reference.md` and test it against a
  matrix of injected host shapes (see section 6).
- Run heavy commands at reduced scheduling priority so they yield to
  interactive work and to other sessions instead of competing with them:
  `nice` everywhere, plus the platform's background class where one
  exists (macOS `taskpolicy`, Linux `ionice`/cgroup weight via
  `systemd-run` when available). Slower is fine; blocking is not.
- Publish a small, cheap host snapshot to every provider session as
  environment: `DX_HOST_CPUS`, `DX_HOST_MEM_GB`, `DX_HOST_LOAD1`,
  `DX_HOST_ACTIVE_SESSIONS`, `DX_HOST_ACTIVE_HEAVY`, `DX_TEST_JOBS`.
  Refresh it at each phase start and print one line in the phase
  handoff message so the agent sees it: "Host: N sessions, M heavy
  commands running, K test jobs available to you."
- Add a project-contract section to `.dex/dex.md`, for example
  `## Resources`, where a repo declares (a) which environment variable
  its test runner reads for parallelism, (b) which of its Quality Gate
  commands count as heavy, and (c) optionally a targeted-test command
  template that takes a file list. Dex sets the declared parallelism
  variable to `DX_TEST_JOBS` when launching heavy commands. With the
  section absent, behaviour is unchanged except that heavy commands
  still take a lease.
- Provide `dx run-gate <command…>` (name it to fit the CLI): takes a
  `heavy` lease, waits with a visible heartbeat ("queued behind 2, oldest
  started 4m ago"), runs the command under the session token, streams
  output to a session-owned log, records exit code and duration, and
  never discards a completed result. This is the sanctioned way to run
  a long gate from a short tool call: the agent starts it and polls the
  log, and the process still dies with the session.
- Tests: two fake sessions each requesting a heavy lease with limit 1;
  assert FIFO order, heartbeat output, no orphan on cancel. Assert the
  declared parallelism variable is set in the child's environment.

### Item 3. Verification ladder: scoped in the loop, the full gate at fixed points

Goal: the same assurance with the project's full gate run once per ticket
in the common case, never inside a review wave, and never twice on the
same tree.

The rungs:

1. **Inner loop** (TDD, fixes, refactors, in Phase 2 and inside review
   waves): only the tests that cover the changed files, using the
   project's targeted-test template when the contract declares one,
   otherwise the narrowest selection the runner supports. Fast static
   checks on the changed files only.
2. **Commit boundary**: the project's fast gates (format, lint, static
   analysis) on the changed set, plus rung 1 tests.
3. **Full gate**: the complete local gate, run through `dx run-gate` at
   background priority, producing a receipt keyed by the tree fingerprint.
   It runs at the end of Phase 2, so review starts from a tree known to
   pass everything and distant breakage is found before review effort is
   spent, and again in Phase 4 only if the fingerprint changed since the
   last receipt. Review waves never run rung 3.
4. **CI**: the whole suite plus CI-only gates on the PR. CI is the final
   arbiter. Local rung 3 exists to avoid pushing red, not to duplicate CI.

Rules that make the ladder real:

- A wave's "applicable deterministic checks" (`prompts/review-wave.md:88-113`)
  are rung 1 and 2 checks scoped to the paths the wave touched, plus any
  probe a finding needs. Rewrite that section so `CLEAN` requires the
  scoped checks to pass and states that the full gate is Phase 4's job.
  The project's aggregate command is not a check a wave may choose.
- "A fix invalidates reuse for the entire checkout"
  (`prompts/review-wave.md:103`) becomes: a fix invalidates receipts
  whose declared inputs intersect the changed paths. A check with no
  declared inputs keeps today's whole-checkout rule, so nothing gets less
  safe by default.
- Add the contract field `full_gate: local | ci`, default `local`. With
  `ci`, Phase 4 runs rungs 1 and 2 only, the PR opens as a draft, and
  Phase 6 treats CI as rung 3, fixing and re-pushing through the same
  loop. This exists for hosts where CI is the cheaper place to run a
  suite, such as a shared remote server, and it never skips the gate. If
  the ticket changes gate, CI or test infrastructure, Phase 4 runs rung 3
  locally regardless.
- Change `skills/dxverify/SKILL.md:30-39,66` so "run every required gate"
  means every gate has a passing receipt on the final tree. Change
  `prompts/phase-audits/2-implement.md:199` and
  `prompts/phase-audits/prompt-loop.md:131` to accept a rung 3 receipt plus
  rung 1 evidence during the loop. Change `prompts/phase-audits/4-verify.md`
  to accept a reused receipt whose fingerprint matches the tree.
- Tests: prompt fixtures assert the ladder text in each phase prompt; a
  review-loop test asserts a wave never invokes the aggregate command; a
  Phase 4 test asserts receipt reuse on an identical fingerprint and one
  re-run on a changed one.

### Item 4. Make the check runner something agents want to use

Goal: remove the incentives that taught agents to bypass
`bin/review-check.sh`.

- Split `DEX_REVIEW_CHECK_TIMEOUT` into a queue budget and an execution
  budget. The queue budget defaults to "wait, with heartbeat" rather than
  fail; if a hard cap is set and reached, return a distinct `queued`
  status the agent can act on (do lighter work, retry) instead of 124.
- A command that completes after the execution budget is still recorded
  with its real exit code and duration; mark it `over-budget` rather than
  discarding it (`bin/review-check.sh:81`).
- Print the queue position and the age of the oldest running check on
  every heartbeat so waiting is legible in the transcript.
- Update `prompts/review-checks.md:53-58` to say plainly: waiting for the
  runner is correct; running the same gate outside the runner is not;
  use the wait to read, plan or write.
- Tests: a check that runs longer than the execution budget is recorded
  with `over-budget` and its real exit code; a queued check reports
  position on each heartbeat.

### Item 5. Project lifecycle hooks in the contract

Goal: give a repository a place to declare per-worktree resources and
their teardown, so Dex can stay codebase-agnostic and still clean up.

- Add optional `## Worktree Hooks` to `.dex/dex.md` with
  `after_create`, `before_remove` and `on_session_end` commands, run in
  the worktree with the worktree name and ticket in the environment.
  Typical uses a repo might declare: create or drop a per-worktree
  database, free a port, delete a build cache. Dex documents the
  variables it provides and runs the hook with a timeout under the
  session token.
- Call `before_remove` from every removal path: `dx.sh:5172-5202`,
  `dx.sh:5018-5030`, `dxclean` at `dx.sh:5434-5450`, `bin/maintain.sh`
  removals, and the UI-proof baseline teardown (`prompts/ui-proof.md:181`
  becomes a Dex-executed step, not prose).
- Add `dx worktree audit` (dry-run) that lists worktrees Dex knows about,
  worktrees git knows about, and, when a repo declares an
  `orphan_resources` probe command in the same section, the resources
  that belong to neither. Nothing is deleted without `--apply`.
- Tests: a fake repo whose `before_remove` writes a marker; assert the
  marker after `dxrm`, `dxrm --all`, `dxclean`, and the baseline
  teardown.

### Item 6. Browsers and MCP servers only when a phase needs them

- Give each session a browser profile directory under `DX_SESSION_TMP`
  instead of `--isolated` (`scripts/browser-mcp.cjs:18`), so it is
  removed with the session. If `--isolated` must remain for
  compatibility, record the profile path it mints and remove it at
  session end.
- Extend the review-wave MCP suppression (`lib/review-loop.sh:1179-1192`)
  to the phases that do not use a browser (Plan, Verify, PR, Complete)
  with a minimal config, keeping the user's own MCP settings untouched
  for interactive use. Make it a documented default with an override.
- Move the Dex-installed MCP servers from `--scope user`
  (`lib/ui-capture.sh:438,455`) to a scope Dex controls, or start them
  lazily on first use, so a phase that never captures UI never forks a
  browser.
- Tests: launching a Verify phase with a fake provider records no
  browser or MCP child; a UI-capture phase records one and its profile
  directory is gone after session end.

### Item 7. Teach host etiquette in every phase

Write one shared fragment, `prompts/host-etiquette.md`, included by every
phase prompt and every wave prompt, and referenced from
`prompts/guardrails.md`. It must be short enough to be read every time
and concrete enough to act on. Cover, in this order:

1. **You are one of several.** Read `DX_HOST_ACTIVE_SESSIONS`,
   `DX_HOST_ACTIVE_HEAVY`, `DX_HOST_LOAD1`, `DX_TEST_JOBS` before any
   heavy command. If heavy work is already running, expect to queue.
2. **Targeted before total.** Use the verification ladder. Say which rung
   you are on when you run tests.
3. **Heavy work goes through the lease.** Use `dx run-gate` (or the
   review-check runner in waves). Waiting is correct. Running the same
   thing outside the lease is the one thing that slows everyone,
   including you.
4. **Use the wait.** While queued, do work that needs no CPU: read the
   next file, draft the PR body, write the test you will run next,
   update the plan. Never sit in a polling loop that burns a tool call
   every few seconds.
5. **Own what you start.** Anything you start is stopped when your
   session ends, and `dx ps` shows it. If you truly need something to
   survive the session, say so in the transcript and why. Reuse a port
   you own rather than opening the next one. Put temp files under
   `DX_SESSION_TMP`.
6. **Leave the tree the way the next agent needs it.** Stop servers,
   drop temp data, close browsers, before you declare a phase done. The
   audit checks the ledger, not your word.
7. **Prefer fewer, larger tool calls over many small ones** when the
   result is the same; each provider process on the host costs memory.
8. **When the host is saturated** (load well above core count, or memory
   pressure), finish the step you are on, then do reading, planning and
   writing until `dx run-gate` reports capacity. Do not compensate by
   splitting into more parallel subagents.

Also: remove the advice at `prompts/workflows/dximplement.md:184-185` to
"use another port"; replace with "reuse the port your session owns;
if a port you did not start is busy, report it, do not fight it."

Add the "no session-owned background process in flight, per `dx ps`"
criterion to the audits for Phases 3, 4, 5 and 6, matching the ones for
0 and 2, with an explicit carve-out for the Phase 6 PR watcher, which
must itself be session-owned.

### Item 8. Cleanup commands that see the whole host

- Extend `dxclean` to report (dry-run) and, with `--apply`, remove:
  session temp roots of ended sessions, browser profiles Dex minted,
  orphan token-carrying processes (via `dx ps`), and worktree resources
  the project's `orphan_resources` probe reports.
- Add `dx doctor` (or extend `dx sessions doctor`) to summarise host
  health for a human in ten lines: live sessions, heavy commands running
  and queued, orphans, swap and load, and the three largest process
  trees Dex is responsible for. It must run in under two seconds and
  never modify anything.
- Tests: fixtures for each category; assert dry-run lists and `--apply`
  removes; assert `dx doctor` output shape.

### Item 9. Review loop: one reviewer, sequential lenses, delta plus one holistic pass

Goal: the same or better review quality per wave with less duplicated
reading, fewer tokens, and a single head that sees the whole change.

- **No scouts by default.** The wave's reviewer performs the domain
  sweeps itself, one lens at a time: correctness, contracts and tests;
  security, architecture and devops; frontend, performance and
  observability; then coherence (below). Set
  `DEX_REVIEW_SCOUT_PARALLELISM` to 0 by default and allow scouts only for
  the `thorough` tier when `DX_HOST_ACTIVE_HEAVY` is low and the diff
  exceeds a size the contract may declare. Parallelism inside one
  reviewer comes from issuing independent read-only tool calls in a single
  turn, which the provider already supports; \1 On the incident host scouts took 35 percent of all
  wave time, a median of 24 minutes of a 38-minute pass, which is the
  single largest cost in the loop.
- **Delta review with a ledger.** Keep a structured findings ledger in the
  session directory (id, file, lens, status, evidence, wave found, wave
  fixed). A wave starts by re-verifying open findings, then reviews the
  diff since the previous wave, and only on a pass that would be declared
  `CLEAN` reviews the whole ticket diff (`base...HEAD`) with the
  coherence lens. A wave that re-verifies the ledger and finds nothing new
  is cheap; do not count it against the tier's wave budget the way a
  full review counts.
- **Coherence lens, required in every tier.** Does the change follow the
  Coherence Contract from the plan (Item 11)? Does it reuse an existing
  helper, service or pattern where one exists rather than adding a
  parallel one? Do naming, error handling, logging and documentation match
  the files around it? Are the docs, configuration and tests the contract
  listed as "must change together" all changed? Are callers and dependents
  of changed symbols still consistent? Findings from this lens are
  verified and recorded like any other.
- **A fix resets only the lenses whose inputs it touched**, not the whole
  clean streak. The required number of consecutive clean passes is set by
  Item 12, not lowered here.
- `dx_review_capacity_limit` derives from host facts (Item 2); FIFO stays.
- Tests: the wave prompt fixture asserts no scout instruction by default
  and the coherence lens present; a ledger round-trip test; a test that a
  fix to one lens's inputs leaves the other lenses' clean status intact.

### Item 10. Telemetry so this can be seen next time

Record, per session and in `docs/events.md`, the number of heavy
commands run, their durations, queue wait, peak RSS of the session's
process tree, and the reap log. Emit one summary line at session end.
Without numbers the next regression will be invisible until the machine
swaps again.

### Item 11. Plan phase: the Coherence Contract

`prompts/workflows/dxplan.md:96` already asks for codebase prior art and
`:109` for a holistic-fit check. Make the result a first-class output.

- The plan gains a `## Coherence Contract` section: the canonical files
  the change must mirror and why; the existing helpers, services and
  extension points to reuse; the project rules and invariants that apply,
  pulled from the project's agent documentation; the naming and layering
  conventions of the touched area; and the documentation, configuration
  and tests that must change together with the code.
- Phase 1's audit requires the section for non-trivial tickets. Phase 2
  reads it before writing code and cites it when it deviates. Phase 3's
  coherence lens (Item 9) checks the diff against it. Phase 5's PR body
  lists any deviation with its reason.
- Keep it short: a contract longer than a screen is a plan problem, not a
  review asset.
- Tests: Phase 1 audit fixture with and without the section; a wave
  prompt fixture asserting the lens reads the contract.

### Item 12. Right-size the gates to the change, and calibrate them from history

Goal: small, low-risk changes stop paying the price of large ones, and the
bar for changes that carry risk does not move.

What the existing telemetry says (66 review loops recorded on the incident
host, `~/.dex/runs/*/events.jsonl`, all but seven classified `complex`):

| Measure | Value |
|---|---|
| Passes recorded | 599, median 38 minutes each |
| Passes ending `findings_fixed` / `clean` / failed or timed out | 277 / 221 / 101 |
| Loops that reached the clean gate | 32 of 63; median 10 passes and 156 minutes |
| Passes spent after a loop's first `clean` | 223 (104 hours) |
| Of those, passes that found something | 52 (23 percent), 111 findings, in 14 of the 32 loops |
| Mean findings per pass before the first `clean` / after | 2.76 / 0.50 |
| Loops that never reached the gate | 31, holding 266 passes (44 percent of all wave time); 17 paused by human intervention |
| Share of passes that found something, by position 1 to 10 | 56, 47, 44, 48, 57, 56, 56, 46, 34, 47 percent |
| Share of pass time in scouts / fixes / checks / context | 35 / 16 / 10 / 5 percent |

Three conclusions follow, and they shape the items below rather than a
blanket cut in required clean passes:

1. The consecutive-clean rule is not worthless: about one confirmation
   pass in four found something. Dropping `required_clean` to 1 would
   have skipped 52 finding passes. What is wrong is the price: a
   confirmation pass costs the same 38 minutes as a first review because
   it repeats the whole review with scouts and checks. Confirmation
   passes must be delta-only, scout-free and cheap (Item 9), so that
   keeping two or three of them costs minutes, not hours.
2. The loop does not converge. The share of passes with findings is flat
   from pass 1 to pass 10 instead of falling, and sequences like
   `FFFFFFFFFFFCC` are common. Either fixes seed new findings, or the
   reviewer's bar admits a steady trickle of low-value items every pass,
   or scope creeps beyond the ticket. The remedies are a better first pass
   (implementer self-review, Coherence Contract, ledger), a finding bar
   (in ticket scope, verified by a probe or a named rule, above a
   severity floor; anything else is a note that does not reset the
   streak), mechanical autofix results never resetting the streak, and a
   convergence guard: if the findings rate has not fallen over three
   consecutive review passes, the loop stops with `CHURN` and asks a
   human instead of spending a twentieth pass.
3. Nearly half of all wave time sat in loops a human eventually paused or
   killed. Time-to-first-clean and passes-per-loop must become visible
   numbers in `dx review stats` and in the phase handoff, so the human can
   intervene at pass 4, not pass 14.


- Today the risk tier is chosen up front and fixes required consecutive
  clean passes at 1/2/3 and wave budgets at 3/6/9
  (`lib/review-policy.sh:33-42,54`). Derive the tier from measured change
  facts at wave time as well: files and lines changed, whether the diff
  touches surfaces the contract marks as sensitive (migrations, auth,
  public API, CI and config, payments, personal data), whether
  dependencies changed, and whether Phase 2's full-gate receipt is green.
  The contract declares the sensitive surfaces and thresholds; Dex ships
  sane defaults.
- Add a `trivial` tier below `small`: one clean pass, at most two waves,
  coherence lens still required. Typical members: a documentation fix, a
  test-only change, a rename with no behaviour change, a dependency bump
  with a green gate.
- Calibrate from data, not opinion. Add `dx review stats`, reading the
  telemetry Dex already writes (`docs/events.md`: `review.pass.started`,
  wave results, findings per wave, tier), and report per tier: waves per
  loop, how often wave N found anything after wave N-1 was clean, and how
  often a later pass reversed an earlier `CLEAN`. Use the report to set
  the tier defaults, and to decide whether requiring more than one
  consecutive clean pass buys anything measurable. Publish the numbers in
  the PR that changes a default.
- Make the first pass better so fewer passes are needed. Phase 2 ends
  with the implementer running the review lenses over its own diff, in
  the same process and context with no subagent, fixing what it finds
  before handoff, and seeding the ledger with what it checked. The
  Coherence Contract (Item 11) and the ledger (Item 9) are the other two
  levers.
- Mechanical fixes (format, lint autofix, generated files) never reset
  the clean streak; re-run the deterministic check and continue. Only a
  verified finding within the ticket's scope and above the severity floor
  resets it. Notes below the floor go to the ledger and the PR body.
- Convergence guard: track findings per pass; if the count has not fallen
  across three consecutive review passes, end the loop with `CHURN` and a
  one-paragraph summary for the human rather than continuing.
- Confirmation passes (a pass whose `clean_before` is at least 1) are
  delta-only and scout-free by construction (Item 9), so the second and
  third clean passes cost minutes.
\1 (`ESCALATE:`) when it
  finds risk the facts did not show. No de-escalation inside a loop.
- Tests: tier-derivation fixtures at each threshold; a stats test over a
  synthetic events file.

---

## 5. Build order and restraint

Ship in this order. Each step is independently useful and independently
revertible.

1. Item 1, ownership. Reuse the existing token reaper; add the `/proc`
   path; make session end reap; add `dx ps`. No new state store.
2. Item 2, lease plus `dx run-gate` plus priority. One more pool in the
   existing capacity module; `dx run-gate` is a thin wrapper over
   `dx_run_with_timeout` plus a lease plus `nice` or `taskpolicy`.
3. Items 3, 9, 11 and 12 together, since they are mostly prompt and
   policy edits that only make sense as a set. Run `dx review stats` on
   the existing telemetry before choosing the new tier defaults.
4. Item 7, etiquette text, once the mechanisms it refers to exist.
5. Item 5, worktree hooks.
6. Items 4, 6, 8 and 10 as follow-ups.

Restraint:

- Do not build a daemon, a scheduler service, a memory-prediction model,
  or a cross-session cache in the first pass. Defer cross-session receipt
  sharing until the single-session ladder has shown its numbers.
- Do not add new state directories; use `$DX_LOOP_DIR` and the session
  directory that exist.
- New CLI surface is limited to `dx ps`, `dx run-gate`, `dx doctor` and
  `dx review stats`. New contract surface is limited to `## Resources`,
  `## Worktree Hooks` and the `full_gate` field.
- Every paragraph added to a prompt must replace one. The prompts are
  already long; the fix for "agents ignore the cleanup text" is not more
  text.
- Measure before and after with one fixed scenario: N fake sessions on a
  fake project whose gate is `sleep`, recording wall time, peak host
  memory, number of full-gate runs and number of orphans at the end.
  Report those four numbers in the PR for every step above.

---

## 6. Definition of done

- All twelve items landed, each with tests in `tests/` that fail before and
  pass after.
- A scripted scenario in `tests/` runs three fake sessions concurrently on
  a fake project whose gate is `sleep`: the gates run one at a time in FIFO order at background priority, no
  review wave ever invokes the aggregate gate, the full gate runs exactly
  once per session when waves make no fixes, every session's children are
  gone within the grace period of session end, `dx ps` shows the right ownership throughout, and the
  project's `before_remove` hook fires on every removal path.
- `docs/reference.md`, `docs/guards.md`, `docs/events.md` and the
  `.dex/dex.md` template document every new contract field, environment
  variable, command and guard.
- Nothing in the diff names a specific repository, command, port,
  database, core count or memory size outside tests and examples.
- A host-shape test matrix in `tests/` injects at least these shapes
  through the measurement seams and asserts sane pool limits, job
  budgets and fallbacks for each: 2 cores / 8 GB; 8 cores / 16 GB;
  32 cores / 128 GB; a Linux container with a 2-CPU cgroup quota on a
  16-core machine; a host where load average or memory cannot be read.
- No phase prompt tells an agent to run the full suite on every
  iteration, and every phase prompt includes the host-etiquette fragment.
- Existing behaviour is unchanged for a project whose `.dex/dex.md` has
  none of the new sections, apart from: heavy commands take a lease,
  children die with the session, and the etiquette text is present.

## 7. Non-goals

- Reducing review depth, the number of required clean passes, test
  coverage, or the strictness of the final gate.
- A background daemon or cron that kills processes it did not start.
- Anything specific to Rails, Postgres, npm, Chrome or macOS beyond
  portable measurement of CPU, memory and load. Project specifics belong
  in the project's contract.

## 8. Appendix: what the agents built for themselves

For calibration, the launchers found on the machine, all agent-authored
in the shell tool's scratchpad and all reparented to launchd:

```
/bin/bash <scratchpad>/verify-launch.sh
  → env DB_SUFFIX=cc820 bin/verify   (12 test workers, 62 minutes, session already gone)
zsh <scratchpad>/verify1.sh
  → bin/verify > verify1.log; echo $? > verify1.rc   (65 minutes, failed, unread)
bash <scratchpad>/runtime-owner-keeper.sh   (17 days old, sleep 3600 loop)
tail -n +13 -F /tmp/dxrev-590-pass-*/static-and-replay.out | sed -u … | grep --line-buffered …   (11 days)
tail -F /tmp/dex-checks-654-*/chain.log | zsh -c 'source <shell-snapshot>' | ugrep …   (9 days)
```

Each of these is an agent solving a real problem, running something
longer than a tool call allows, without a sanctioned tool. Item 2's
`dx run-gate` and Item 1's ownership token are the sanctioned tool.
Design them so the agent's easiest path is also the correct one.
