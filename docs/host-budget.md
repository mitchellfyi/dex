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

**Review waves are capped harder.** A wave already ran with no MCP servers and
no browser integration. It now also gets a hard subagent cap equal to its
scout parallelism and no nested subagents, so a wave cannot fan out past what
the wave prompt asks for.

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

**Prompts ask for less.** Phase 2 audits run the tests that cover the
change, not the suite, on every pass; the complete pipeline runs once, in
Phase 4. Review waves run targeted tests. Every phase is told to stop the
servers, browsers, watchers and runners it started, never to use watch mode,
and to stay within `DX_TEST_JOBS`. `prompts/guardrails.md` carries the rule
set under "Resource Discipline".

**The full suite can move to CI.** With `DEX_VERIFY_FULL_SUITE=ci`, Phase 4
runs the focused tests locally and reports the full-suite gate as `CI`;
Phase 6 already watches CI and fixes failures. This is policy, not a waiver.

## Recommended settings for a shared host

Put these in the shell that launches `dx` on a machine that runs several
lifecycles at once. Start with the first block; add the second on 16 GB
machines or when browsers are involved.

```bash
# Fewer concurrent review waves, one scout at a time inside each.
export DEX_REVIEW_MAX_ACTIVE_WAVES=1
export DEX_REVIEW_SCOUT_PARALLELISM=1

# Let CI run the full suite; run focused tests locally.
export DEX_VERIFY_FULL_SUITE=ci

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
  install` registers `playwright` and `chrome-devtools` at user scope so UI
  proof works everywhere; on a shared host, remove them at user scope and add
  them at project scope in the frontend repositories only (`claude mcp remove
  --scope user playwright`, then `claude mcp add --scope project ...` from
  `dx ui-capture install`'s command line).
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
ps -Ao pid,ppid,rss,etime,command | sort -k3 -nr | head -40
ps -Ao pid,lstart,command | grep -i 'chrom' | grep -v Helper   # orphaned browsers
memory_pressure | tail -1                   # macOS free percentage
```

A `python -m unittest`, `jest`, `cargo test` or `next dev` near the top of
that list, with a `claude` parent, is a session that started something it
should have scoped or stopped. Inside a fat session, `/heapdump` writes a
diagnostics file that says whether the growth is JavaScript heap or native.
