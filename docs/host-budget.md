# Running several lifecycles on one machine

Six `dx` sessions on one laptop can take it down in a couple of hours. This
page explains where the memory goes, what Dex does about it, and what to set
when you run more than two or three lifecycles at once.

## Where the memory goes

Measured on a Dex-installed macOS host, one `claude` session costs about
120 MB fresh and 200 to 300 MB after an hour. That is not the problem. The
problem is everything one session starts:

| Source | Cost | Multiplied by |
|--------|------|---------------|
| MCP sidecar processes (`playwright`, `chrome-devtools`, docs, code intelligence) | ~370 MB idle per session, before any browser opens | every session, and every background subagent, since each spawns its own copies |
| A browser opened through an MCP server | 500 MB to 1 GB each; orphaned on reconnect | every session that touched a browser |
| A project test suite | 1 to 6 GB while it runs; jest, vitest, pytest-xdist and cargo fan out to every core by default | every session running one, and Phase 2 audits used to ask for the full suite on every pass |
| A cold dependency install or build in a fresh worktree | the whole build, plus a flood of file-system events that `fseventsd` has to index | every new worktree |
| Language-server plugins (`typescript-lsp`, `pyright-lsp`, `rust-analyzer-lsp`) | 1 to 3 GB each on a large repository | every session on that repository |
| A review wave | one more `claude` process, its scouts, and its deterministic checks | up to `DEX_REVIEW_MAX_ACTIVE_WAVES` at once |

Two facts from Anthropic's tracker matter here. Claude Code applies no
cross-session backpressure, and `NODE_OPTIONS=--max-old-space-size` does
nothing on the native build, which is not a Node process. Backpressure has to
come from the thing that launches the sessions, which is Dex.

The terminal can also hold gigabytes of scrollback from hours of agent output.
Before blaming anything else, measure with `ps` rather than Activity Monitor,
whose Memory column counts virtual and compressed pages:

```bash
ps -Ao pid,ppid,rss,etime,command | sort -k3 -nr | head -40
```

`dx status` prints the same view summarised: sessions, sidecars, browsers,
and the current budget.

## What Dex does now

**One host budget on every launch.** `lib/host-budget.sh` derives a test-job
budget from the host's cores and the number of sessions expected to share it,
and `dx_provider_claude` exports it to every session it starts, on every
engine including the router. Runners that read an environment variable get it
directly; the prompts carry the same number as `DX_TEST_JOBS` for runners that
only take a flag.

| Exported | Read by |
|----------|---------|
| `DX_TEST_JOBS` | Dex's manifest runner, the lifecycle prompts (`jest --maxWorkers`, `playwright test --workers`, `pytest -n`) |
| `VITEST_MAX_THREADS`, `VITEST_MAX_FORKS` | vitest |
| `PYTEST_XDIST_AUTO_NUM_WORKERS` | pytest-xdist with `-n auto` |
| `CARGO_BUILD_JOBS`, `RUST_TEST_THREADS` | cargo and libtest |
| `GOFLAGS=-p=N` | go build and go test |
| `MAKEFLAGS=-jN` | make |
| `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`, `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` | Claude Code's Agent tool |

A name you export yourself keeps its value; Dex only fills in what is unset.

**One host-wide slot count for heavy work, in every phase.** Project gates,
test suites and builds take a `heavy` lease before they run, so at most a
host-appropriate number are running at once across every Dex session on the
machine — not per phase, not per lifecycle, not only in review. A dev server
never takes one: it starts directly and is session-owned, because a lease held
for a server's whole life is never returned. The limit is derived from what the
host actually is:

```
max(1, min(cpus / 4, mem_gb / 8)), capped at 8
```

Four cores and eight gigabytes is roughly what one project test suite or one
cold build consumes while it runs, so the two terms are the same answer from
opposite directions and the smaller one wins. `DEX_MAX_ACTIVE_HEAVY` replaces
the calculation.

Every number in it is measured at run time, on macOS and on Linux, and a
cgroup v2 `cpu.max` or `memory.max` limit lower than the machine's wins — a
container budgets against its own share. A measurement the host cannot supply
falls back to a small, conservative default (2 cores, 4 GB) and says so:
`DX_HOST_FALLBACKS=fallback=mem_gb` rides along with the snapshot rather than
letting an unmeasurable host quietly get the benefit of the doubt.

The `heavy` pool shares its FIFO queue, its stale-owner recovery and its
refusal to over-admit with the `waves` and `checks` pools that came before it.
Queueing is by arrival, so a second session's gate cannot be starved by a
third that asked later.

**`dx run-gate` is how a heavy command runs.**

```bash
dx run-gate bin/verify
dx run-gate --name suite -- bash tests/run-all.sh
```

It takes the lease, waits with a heartbeat that says who is ahead and how long
the oldest has been running — waiting never fails the command — runs at reduced
scheduling priority, streams output to a log under the session's temp root, and
records a receipt. The process carries the session's ownership token, so it dies
with the session however it was started. Because output goes to a file, a gate
that takes twenty minutes can be started from one tool call and polled from the
next instead of holding a call open.

Reduced priority means `nice -n 10` everywhere, plus the platform's background
classes where they exist and actually work, strongest first:

| Wrapper | Chain |
|---------|-------|
| `systemd-run+ionice` | `systemd-run --user --scope -q -p CPUWeight=50 nice -n 10 ionice -c 3` |
| `systemd-run` | the same scope, where `ionice` is unavailable |
| `nice+taskpolicy` | `nice -n 10 taskpolicy -c background` (macOS) |
| `nice+ionice` | `nice -n 10 ionice -c 3` (Linux with no user manager) |
| `nice` | `nice -n 10` alone |
| `none` | this host would not even renice |

CPU weight and I/O class are not alternatives, which is why the first row
exists: a transient scope halves the CPU share and says nothing about the disk,
and the disk is what a test suite or a cold build actually saturates.

Each candidate is probed by running its whole chain against a real binary, so
composition is proved rather than inferred — one whose parts are all installed
but whose combination fails here (`systemd-run --user` on a box with no user
manager is the common case) is passed over silently and the next is tried. The
wrapper that was used is recorded in the receipt and in the `gate.finished`
event, so the log says what happened rather than what was configured. Slower is
fine; blocking the interactive session is not. `DEX_GATE_PRIORITY` pins one
wrapper by name or turns the whole thing off.

A gate that finished is evidence. Its receipt lands in
`$DX_LOOP_DIR/<session>.gate-receipts/<name>.json` keyed by the checkout
fingerprint (HEAD) and the working fingerprint, and it is written whether the
gate passed or failed — a failure is as much a fact about that tree as a pass.
A gate whose working tree moved while it ran is recorded as `stable: false` and
never matched again, because it describes neither the tree before nor the tree
now.

**Every session is told what else is on the machine.** Each provider launch
exports `DX_HOST_CPUS`, `DX_HOST_MEM_GB`, `DX_HOST_LOAD1`,
`DX_HOST_ACTIVE_SESSIONS`, `DX_HOST_ACTIVE_HEAVY`, `DX_TEST_JOBS` and
`DX_HOST_FALLBACKS`, and every phase handoff prints the same numbers as one
line:

```
Host: 3 sessions, 1 heavy commands running, 2 test jobs available to you.
```

A phase handoff happens inside the running provider process, so its launch
environment is as old as the session; the line is the refresh.

Those are outputs, and they are re-measured every time they are published. A
session launches further sessions — every review wave is one — so a reader that
accepted its own published value would hand a nested launch the parent's
launch-time load average as the current one, and an inherited
`DX_HOST_FALLBACKS` marker would outlive the host condition that earned it
(which is why it is published empty rather than omitted when everything
measured cleanly). The inputs have their own names:
`DX_HOST_CPUS_OVERRIDE`, `DX_HOST_MEM_GB_OVERRIDE`, `DX_HOST_LOAD1_OVERRIDE`,
and `DX_HOST_CGROUP_DIR` for where the cgroup limits live. Set those in a
container that knows its own shape. Counting live
sessions costs one directory read and one `kill -0` per session — no `ps`, no
fork — which is what lets it run at every phase start.

**Review waves are capped harder.** A wave already ran with no MCP servers and
no browser integration. It now also gets a hard subagent cap equal to its
scout parallelism and no nested subagents, so a wave cannot fan out past what
the wave prompt asks for.

**Only the phases that need a browser get one.** Verify, PR and Complete
launch with the same empty MCP configuration a review wave uses
(`--strict-mcp-config --mcp-config`), so they no longer start a node sidecar
per registered server, or the Chromium behind it, for tools they never call.
Plan joins them when the launch ends with the phase — `dxplan`, `dxcomplete`,
a headless run, Codex's direct handoff. An inline lifecycle advances phases
inside one provider session and an MCP configuration is fixed for the life of
that process, so a Phase 1 launch there keeps its servers: it goes on to run
Phase 2, which is where UI proof is captured. Setup, Implement and Review keep
them in every mode. Nothing is rewritten — the registrations are read, an
interactive `claude` session is unaffected, and `DEX_LIFECYCLE_MINIMAL_MCP=0`
restores the old launch for a project whose planning or completion work
genuinely needs an MCP server. The one gap is a `dx control jump` backwards
into Implement from Verify or later, which lands in a process that has already
dropped them. The plan (Item 6) also asked for the browser servers to move out
of user scope; Dex tried project scope as the default and reverted it, because
a project-scope registration writes an absolute Dex path into the repository's
tracked `.mcp.json` and never reaches a lifecycle worktree — Dex links only
`.claude/` into one. The minimal launch above is what keeps a browser out of a
phase that needs none, so `dx ui-capture install` stays on user scope, with
`--project` and `--local` as explicit choices. A browser a session does start
gets its profile under `DX_SESSION_TMP`, which goes away with the session.

**Waves wait for memory.** The host-wide review queue admits the first wave
regardless, but a wave that would join others already running waits while
free memory is below `DEX_MIN_FREE_MEMORY_PERCENT`. The wait is logged once
and ends when memory recovers.

**Worktrees share build caches.** A new worktree links the main checkout's
ignored `node_modules`, `target`, `.venv`, `vendor`, `.next` and `.nuxt`
directories instead of starting empty, so a lifecycle no longer pays a cold
install and a cold build the host has already done. Only directories git
already ignores are linked, the link itself is excluded from status, and an
existing real directory is never replaced. Cargo serialises builds on a
shared `target`, which also stops six lifecycles compiling the same
dependency tree side by side. Set `DEX_WORKTREE_SHARED_DIRS` to change the
list or empty to disable.

**Prompts ask for less, and leave the judgment to the agent.** Phase 2
audits run the tests that cover the change, not the suite, on every pass;
the complete pipeline runs once, in Phase 4. Running the whole suite earlier
is the agent's call, and the prompts name when it is the right one: a shared
module, a schema, build or test configuration, a fix whose blast radius
cannot be bounded. Review waves run targeted tests. Every phase is told to
stop the servers, browsers, watchers and runners it started, never to use
watch mode, and to stay within `DX_TEST_JOBS`. `prompts/guardrails.md`
carries the rule set under "Resource Discipline". There is no gate that
moves the suite elsewhere; Phase 4 remains the place it runs.

## What a project can declare about itself

Dex cannot guess which environment variable your test runner reads, or which of
your gates is the expensive one. A repository states it in a fenced YAML block
under `## Resources` in `.dex/dex.md`:

```yaml
parallelism_env: [PARALLEL_WORKERS]
heavy_commands:
  - make check
  - bin/rails test
targeted_tests: "bin/rails test {files}"
```

The example is a Rails project, whose minitest reads `PARALLEL_WORKERS`;
substitute your own runner's variable and your own gates.

- `parallelism_env` names the variables Dex sets to `DX_TEST_JOBS` when it
  launches a session and when it runs a gate. Dex already sets the common ones
  (`VITEST_MAX_THREADS`, `PYTEST_XDIST_AUTO_NUM_WORKERS`, `CARGO_BUILD_JOBS`,
  `RUST_TEST_THREADS`, `GOFLAGS`, `MAKEFLAGS`); this is for a name only your
  repository knows.
- `heavy_commands` names the commands that must take a heavy lease. `dx
  run-gate` confirms a command it was handed is one of them, and warns when it
  is not — it leases either way.
- `targeted_tests` is the template for running only the tests covering a file
  list; `{files}` is replaced with space-separated paths.
- `full_gate` is `local` (default) or `ci`. With `ci`, Phase 4 runs the fast
  gates and the focused tests, the PR opens as a draft, and Phase 6 treats CI
  as the complete gate and fixes through the same loop. A ticket that changes
  the gates, CI, or test infrastructure runs the full gate locally regardless.
  This is for hosts where CI is the cheaper place to run a suite; it never
  skips the gate.
- `review_sensitive_paths` lists globs Dex adds to its own sensitive surfaces
  when it derives the review risk tier from the diff. Additive only: the
  built-in surfaces (auth, secrets, migrations, schemas, CI, hooks, guards,
  deployment, public CLI and config) always apply.
- `review_trivial_max_files` (10), `review_trivial_max_lines` (500) and
  `review_broad_impact_files` (10) bound that derivation; `review_scout_min_files`
  (40) is the diff size above which the deepest tier may use parallel review
  scouts again. A malformed or missing value falls back to the default.

Read only through `dx_project_contract_values`, which parses a flat mapping of
scalars and lists with the Python standard library. Nesting, anchors and block
scalars are not part of the contract. With the section absent nothing changes
except that a command run through `dx run-gate` still takes its lease, so
adding it is an optimisation and never a prerequisite.

## Recommended settings for a shared host

Put these in the shell that launches `dx` on a machine that runs several
lifecycles at once. Start with the first block; add the second on 16 GB
machines or when browsers are involved.

```bash
# One review wave at a time (the derived default is one per four cores and
# eight gigabytes). Scouts are already off: DEX_REVIEW_SCOUT_PARALLELISM=0 in
# every tier, so do not export it here — 1 would turn them on.
export DEX_REVIEW_MAX_ACTIVE_WAVES=1

# Hold new review waves until at least 15% of memory is free.
export DEX_MIN_FREE_MEMORY_PERCENT=15
```

```bash
# Tighter fan-out per session.
export DEX_TEST_JOBS=1
export DEX_MAX_CONCURRENT_SUBAGENTS=2
export DEX_MAX_SUBAGENT_SPAWN_DEPTH=1

# Compact earlier on routed sessions. The router states the route's budget
# (often 800k tokens); this lowers the trigger without changing the budget.
export CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=50
```

Outside Dex:

- Keep the browser MCP servers out of sessions that do not need them. `dx
  install` and `dx ui-capture install` register `playwright` and
  `chrome-devtools` at user scope so UI proof works everywhere, and the
  minimal-MCP launch keeps them out of the phases that need none. On a shared
  host you can still narrow them by hand: remove them at user scope and add
  them in the frontend repositories only (`claude mcp remove --scope user
  playwright`, then `dx ui-capture install --project` or `--local` there).
- Disable language-server plugins on large repositories (`/plugin disable
  typescript-lsp@claude-plugins-official`); Anthropic's own guidance for
  memory issues is the same.
- Cap terminal scrollback, or run lifecycles under `tmux` with a bounded
  history, or use `/tui fullscreen`, which keeps output out of the terminal's
  buffer.
- Keep Claude Code current. Releases 2.1.208 through 2.1.257 each fixed a
  class of unbounded growth (MCP stderr, LSP documents, subagent results,
  large tool results, headless tool payloads).
- If `fseventsd` grows, it is indexing the file churn of installs and builds.
  Shared caches remove most of it; the rest is watchers from dev servers and
  language servers that a phase should have stopped.

## Diagnosing a host that is already struggling

```bash
dx status                                   # sessions, sidecars, browsers, budget
dx ps                                       # what each session owns, and its orphans
ps -Ao pid,ppid,rss,etime,command | sort -k3 -nr | head -40
ps -Ao pid,lstart,command | grep -i 'chrom' | grep -v Helper   # orphaned browsers
memory_pressure | tail -1                   # macOS free percentage
```

For anything a Dex session started, `dx ps` is the supported version of that
grep — it names the owning session, and `dx ps --reap-orphans` stops the ones
whose session is gone. The `ps` line still has a job, because a browser nothing
in Dex started is not in `dx ps`.

A `python -m unittest`, `jest`, `cargo test` or `next dev` near the top of
that list, with a `claude` parent, is a session that started something it
should have scoped or stopped. Inside a fat session, `/heapdump` writes a
diagnostics file that says whether the growth is JavaScript heap or native.

## One screen, and one sweep

`dx doctor` answers "what is already running on this machine?" in about a
dozen lines, read-only, in well under a second. It reuses the readers the rest
of Dex already has rather than measuring anything of its own: the session
process tokens behind `dx ps`, the `heavy` / `waves` / `checks` lease pools,
the measured host facts above (including the `fallback=` markers when a reader
could not answer), and the `ps` listing `dx status` groups by provider
session.

```
Dex — doctor

Sessions:
  1 Dex session(s) own processes: repo-app-worktree-ticket-853
  4 of 20 Claude Code session record(s) still running
Pools:
  heavy   1 held (limit 2), 0 queued
  waves   0 held (limit 3), 0 queued
  checks  0 held (limit 4), 0 queued
Orphans:
  1 session(s) whose process token is dead, 3 process(es) still running
  'dx ps' lists them, 'dx ps --reap-orphans' stops them, 'dxclean' shows the rest.
Host:
  12 CPU(s), 24 GB memory, load 3.21, 35% memory free (floor 10%)
  2 test job(s) per session
Trees:
    574M   31 process(es)  pid 68447   claude   repo-app-worktree-ticket-853
    493M   20 process(es)  pid 5176    claude   (no Dex session)
    340M   15 process(es)  pid 25274   codex    (no Dex session)
```

Live is the cheap test: the PID that opened the session's process token still
answers. `dx ps` confirms it by scanning for the token itself, so `dx doctor`
can under-report an orphan and never invents one. The trees are every provider
process tree on the host, largest first, annotated with the Dex session whose
token holder is an ancestor — a tree with no annotation is a `claude` or
`codex` nobody here started.

`dxclean` does the other half. Its first four passes are unchanged: stale
worktrees, gone branches, orphan branches, old state files, all in the current
checkout. It then reports — and with `--apply` removes — what sessions that
are gone have left on the machine as a whole:

| Reported | Removed by `--apply` |
|---|---|
| Session temp roots and process tokens whose holder is dead | Through `dx ps --reap-orphans`, which stops the processes first and keeps the token of any that would not die |
| Browser profiles Dex minted, as `$DX_SESSION_TMP/browser-profiles.txt` records them | Directly, and only inside Dex's own state directory — the file is a record of what Dex minted, not a licence to remove any path in it |
| `*.gate-receipts` directories of a session with no phase state, no loop state and no process token left | Directly |
| Orphan token-carrying processes, from `dx ps` | Through `dx ps --reap-orphans`, never a second kill path. It re-derives the orphan list when it runs, so the set it acts on is the set that is still orphaned then, not the one printed seconds earlier; a reconciliation line says how many processes were actually stopped and how many of the reported temp roots went |
| What this project's `orphan_resources` probe reports, minus any line naming a worktree Dex or git still lists | By running its own `before_remove` hook per line, the way `dx worktree audit --apply` does |

Without `--apply` nothing in that list is touched, and the token scan only
runs when a session is actually gone, so the report costs nothing on a healthy
host — when something is gone, it costs a full `dx ps` listing. `dx sessions
forget`, `dx_cleanup_session` and `dxclean`'s own worktree pass all leave a
`.process` directory behind on purpose — the token is the only way to find
those processes again — which is why this sweep exists.

**A live worktree is never an orphan here either.** A probe of the ordinary
shape lists the resources of every worktree it can see, including the one
someone is working in, so `dxclean` checks each reported line against the
directories under `.dex/worktrees/` and the worktrees git has registered —
basenames and resolved paths, case-folded — before it offers to tear anything
down. A match is printed as `reported, but Dex still has this worktree — not
touched` and `--apply` skips it. This is the same rule
[docs/worktree-hooks.md](worktree-hooks.md) states for `dx worktree audit`.

The probe's own outcome is four different facts, and only one of them is
reassuring: it reported these lines, this project declares no probe, the probe
ran and reported nothing, or **the probe failed** — in which case the report
says `the orphan_resources probe failed; Dex cannot tell whether this project
is clean` rather than showing an empty list.
