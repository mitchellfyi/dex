# Reference tables

Lookup tables that AGENTS.md points at. They live here rather than in AGENTS.md
because that file is read into every session, and these are needed only when
you are actually looking something up.

## Shared library modules

Every module in `lib/`. `common.sh` sources all of them except itself and
`router.sh`, which `lib/provider.sh` sources lazily when a routed launch needs
it.

| Module | Purpose | Key functions |
|--------|---------|---------------|
| `common.sh` | Bootstrap, constants, sources all others | `dx_repo_root()` |
| `lock.sh` | Advisory directory locks with owner records and serialized stale recovery | `dx_lock_acquire()`, `dx_lock_release()`, `dx_lock_with()` |
| `agent-tools.sh` | Conservative Claude/Codex tooling bootstrap | `dx_bootstrap_agent_tooling()`, `dx_install_safe_official_claude_plugins()`, `dx_install_openai_docs_mcp_servers()` |
| `attribution.sh` | Commit/PR attribution installation, hook chaining, and restoration | `dx_install_repo_attribution()`, `dx_uninstall_repo_attribution()`, `dx_commit_attribution_message()` |
| `codex.sh` | Codex CLI skill installation helpers | `dx_install_codex_skills()`, `dx_count_dex_skills()`, `dx_codex_dex_skills_complete()`, `dx_uninstall_codex_skills()` |
| `completion.sh` | Generation-bound completion expectations, receipts, validation, and cleanup | `dx_completion_issue()`, `dx_completion_write_receipt()`, `dx_completion_consume()` |
| `dexcode.sh` | DexCode login, org connections, run registration/sync, artifact upload | `dx_dexcode_login()`, `dx_dexcode_command()`, `dx_dexcode_prepare_run_sync()`, `dx_dexcode_upload_artifact()` |
| `events.sh` | Run IDs, local run directories, JSONL event journals, redacted logs, artifact manifests, summaries | `dx_run_prepare()`, `dx_event_emit()`, `dx_run_log_append()`, `dx_run_register_artifact()`, `dx_run_write_summary()` |
| `factory.sh` | Optional Dex Factory event sync over HTTP | `dx_factory_sync_pending_events()`, `dx_factory_events_endpoint()`, `dx_factory_sync_requested()` |
| `git.sh` | Git helpers, including safe tracker-branch adoption | `dx_default_branch()`, `dx_ticket_branch_prepare()`, `dx_slugify()` |
| `lifecycle-control.sh` | Human/agent lifecycle pause, stop, phase transition, ownership, and audit receipts | `dx_write_lifecycle_control()`, `dx_lifecycle_control_read()`, `dx_lifecycle_control_lock_acquire()` |
| `maintenance.sh` | Background maintenance config, workflow install, run IDs, locks, and reviewer normalization | `dx_maintenance_event_mode()`, `dx_maintenance_install_workflow()`, `dx_maintenance_run_id()`, `dx_maintenance_request_reviewer()`, `dx_maintenance_pr_review_state()` |
| `override.sh` | Session policy journal, validation, expiry, and effective-value resolution | `dx_override_set()`, `dx_override_clear()`, `dx_override_list()`, `dx_override_effective()` |
| `provider.sh` | Provider/model profile resolution, launch wrapping, and diagnostics | `dx_provider_apply()`, `dx_provider_claude()`, `dx_provider_command()`, `dx_provider_doctor()` |
| `project-state.sh` | Init ownership snapshots, conservative project cleanup, and the machine-readable `.dex/dex.md` contract reader | `dx_project_state_begin()`, `dx_project_state_finalize()`, `dx_project_state_remove_managed()`, `dx_project_contract_values()`, `dx_project_worktree_hook()` |
| `review.sh` | Scope-bound review selection/state, evidence, deterministic baselines, wrapper-clock metrics, retained proofs, ledgers, receipts, result parsing, churn detection, and telemetry JSON | `dx_review_evidence_valid()`, `dx_review_baseline_publish()`, `dx_review_metrics_mark()`, `dx_review_ledger_valid()`, `dx_review_write_receipt()`, `dx_review_event_json()` |
| `review-capacity.sh` | Host-wide FIFO admission with named pools (`waves`, `checks`, `heavy`), PID-reuse-safe stale-owner recovery, and a per-pool limit | `dx_review_capacity_limit()`, `dx_review_capacity_wait()`, `dx_review_capacity_release()`, `dx_capacity_pool_wait()`, `dx_capacity_pool_release()`, `dx_capacity_pool_queue_status()` |
| `review-loop.sh` | The review loop itself plus its helpers: wave orchestration, tier assessment, run telemetry, pause and interrupt handling, scope snapshots. `dxreviewloop` in dx.sh is a thin wrapper over it | `dx_review_loop_run()`, `__dx_review_emit_event()`, `__dx_review_scope_snapshot()` |
| `review-controller.sh` | Pure review-loop state transitions and atomic findings history | `dx_review_transition()`, `dx_review_findings_history_append()` |
| `review-acceptance.sh` | Durable wave handoff, retained authorization, and idempotent parent checkpoint recovery | `dx_review_acceptance_begin()`, `dx_review_acceptance_finish()` |
| `review-diagnostics.sh` | Bounded failure evidence retained before child cleanup | `__dx_review_cleanup_pass()` |
| `review-policy.sh` | Trusted default-branch clean-pass policy resolution and binding | `dx_review_policy_resolve()`, `dx_review_policy_for_tier()` |
| `rtk.sh` | RTK token-reduction bootstrap and checks | `dx_install_rtk_tooling()`, `dx_check_rtk_tooling()`, `dx_rtk_resolved_binary()` |
| `router.sh` | Lazy optional CCR CLI and provider launch bridge | `dx_router_node_check()`, `dx_router_command()`, `dx_router_launch()` |
| `run-spec.sh` | Structured headless run spec validation, fetch, normalization, and journal prep | `dx_run_spec_normalize()`, `dx_run_spec_fetch()`, `dx_run_spec_prepare_journal()` |
| `session-catalog.sh` | Read-only, repo-scoped lifecycle inventory and exact selector resolution | `dx_session_catalog_records()`, `dx_session_catalog_record()`, `dx_session_catalog_select()` |
| `session-runtime.sh` | PID-reuse-safe lifecycle runtime leases and health | `dx_session_runtime_start()`, `dx_session_runtime_heartbeat()`, `dx_session_runtime_finish()` |
| `session.sh` | Session ID derivation, state file paths, and per-command timeouts | `dx_session_id()`, `dx_provider_state_file()`, `dx_cleanup_session()`, `dx_run_with_timeout()` |
| `session-process.sh` | Session process ownership: the per-phase token, carrier scans, the reap at session end, phase exit and orphan sweep, `dx ps` process descriptions, and the per-session gate, peak-RSS and summary telemetry | `dx_session_process_token_attach()`, `dx_session_finish_processes()`, `dx_session_process_describe()`, `dx_session_gate_record()`, `__dx_session_summary()` |
| `session-management.sh` | Strict internal lifecycle-session cleanup transactions | `__dx_session_management_cleanup_exact()` |
| `output.sh` | Formatted user-facing output | `dx_done()`, `dx_ok()`, `dx_warn()`, `dx_error()`, etc. |
| `host-budget.sh` | Measured host facts (cores, memory, load, cgroup limits, free memory) with recorded fallbacks; the per-session test-job budget and runner environment (`DX_TEST_JOBS`, vitest, pytest-xdist, cargo, go, make); the `heavy` admission limit, the per-phase host snapshot, the reduced-priority wrappers, and heavy-gate receipts | `dx_host_cpu_count()`, `dx_host_memory_total_gb()`, `dx_host_load1()`, `dx_host_test_jobs()`, `dx_host_budget_env()`, `dx_host_heavy_limit()`, `dx_host_snapshot()`, `dx_host_handoff_line()`, `dx_host_priority_wrapper()`, `dx_gate_receipt_write()`, `dx_gate_receipt_lookup()` |
| `ui-capture.sh` | Playwright/UI capture tooling, artifact paths, MCP bootstrap | `dx_install_ui_capture_tooling()`, `dx_ui_capture_run_dir()`, `dx_ui_capture_playwright_ready()` |
| `triage.sh` | Standalone ticket triage arguments, provider launch, and isolated cleanup | `dx_triage_run()`, `dx_triage_cleanup()` |
| `worker.sh` | DexCode worker registration and the poll/claim/lease/settle daemon | `dx_worker_command()`, `dx_worker_register()`, `dx_worker_daemon()` |
| `worktree.sh` | Worktree management utilities, shared build-cache links, and the project's `## Worktree Hooks` lifecycle commands | `dx_wt_branch()`, `dx_wt_remove()`, `dx_worktree_hook_run()`, `dx_worktree_orphan_resources()`, `dx_cleanup_last_session()`, `dx_cleanup_stale_files()` |

## Environment variables

The environment values below are launch defaults. Active lifecycle consumers
re-read the corresponding `dx control override` records without a provider
relaunch. Review can use an override-bound lower target; named assurance
waivers remain separate from passed results. See `docs/autonomous-mode.md` for
the gate map.

| Variable | Purpose | Default |
|----------|---------|---------|
| `DEX_DIR` | Installation directory | `$HOME/work/dex` |
| `DX_STATE_DIR` | Phase state directory | `~/.claude/.dex-phases` |
| `DX_LOOP_DIR` | Loop state directory | `~/.claude/.dex-loops` |
| `DX_ARTIFACT_DIR` | Dex-generated screenshots, videos, traces, and logs | `~/.claude/.dex-artifacts` |
| `DX_TOOL_DIR` | Dex-managed external tooling cache | `~/.claude/.dex-tools` |
| `DEX_ROUTER_HOT_RELOAD` | `0` turns off the router gateway's automatic reload of changed `scripts/ccr/` sources; read by `dx router start` | on |
| `DX_RUN_ROOT` | Dex run directories, event journals, summaries, and run artifacts | `~/.dex/runs` |
| `DEX_RUN_ID` | Current run ID passed into hooks/provider subprocesses | unset |
| `DEX_HEADLESS_RUN` | Internal marker for lifecycle sessions started by `dx run` | unset |
| `DEX_HEADLESS_RUN_SPEC_FILE` | Normalized run spec path passed into the launched lifecycle | unset |
| `DEX_HEADLESS_REQUIRES_PLAN_APPROVAL` | Whether Phase 1 must wait for interactive plan approval | spec value |
| `DX_RTK_ENABLED` | Enable RTK token-reduction bootstrap (`0` disables) | `1` |
| `DX_RTK_BIN` | Override RTK binary path used by Dex hooks/checks | unset |
| `DX_RTK_INSTALL_DIR` | RTK binary install directory | `$DX_TOOL_DIR/rtk/bin` |
| `DX_RTK_VERSION` | Pin RTK release installed by Dex | latest GitHub release |
| `DX_RTK_HTTP_TIMEOUT_SECONDS` | Seconds one RTK download may take | 20 for release metadata, 180 for the binary |
| `DX_SESSION_RUNTIME_OWNER_START_TIMEOUT_MILLISECONDS` | Internal wait for a runtime supervisor to publish ready state; retry-time override, not a lifecycle gate | 15000 |
| `DX_SESSION_RUNTIME_OWNER_FINISH_TIMEOUT_MILLISECONDS` | Internal wait for a runtime supervisor to publish terminal state; retry-time override, not a lifecycle gate | 5000 |
| `DX_TIMEOUT_PROCESS_SCAN_TIMEOUT_SECONDS` | Internal bound for one macOS `lsof` scan while cleaning up a supervised process tree; invalid values fall back to the default | 3 |
| `DX_TOKEN_SCAN_METHOD` | `lsof` skips the first-choice ownership scan (`/proc` on Linux, libproc on macOS) and asks `lsof` directly — for a host whose first-choice answer is known wrong, and for tests that must reach the fallback on a host where the first choice works. Anything else is `auto` | `auto` |
| `DX_SESSION_PROCESS_TOKEN` | Session process-ownership token, exported into the provider session and inherited by every process it starts; the same value is held open on fd 8 so a detached descendant stays identifiable. Set by Dex, not by a user | unset |
| `DX_SESSION_TMP` | Temp root exported to the provider, one per lifecycle phase (a provider session is one phase), removed after that phase's reaper runs. Put scratch files, browser profiles, and gate logs here so they go with the phase | `$DX_LOOP_DIR/<session>.process/tmp` |
| `DX_HOST_ACTIVE_SESSIONS` | Dex sessions owning processes on this host when the session was launched or the phase handed off. Published by Dex for the agent to read, not set by a user | measured |
| `DX_HOST_ACTIVE_HEAVY` | Heavy leases held on this host at the same moment. Published by Dex, not set by a user | measured |
| `DX_HOST_CPUS` | Logical CPUs Dex measured for the session, cgroup-clamped. Published by Dex for the agent to read; `DX_HOST_CPUS_OVERRIDE` is the input | measured |
| `DX_HOST_MEM_GB` | Whole gigabytes of memory Dex measured, cgroup-clamped. Published by Dex; `DX_HOST_MEM_GB_OVERRIDE` is the input | measured |
| `DX_HOST_LOAD1` | One-minute load average when the session was launched or the phase handed off. Published by Dex; `DX_HOST_LOAD1_OVERRIDE` is the input | measured |
| `DX_HOST_FALLBACKS` | Space-separated `fallback=<name>` markers naming each host fact that could not be measured and got a conservative default. Published **empty** when every measurement answered, so an inherited marker cannot outlive the condition that earned it | measured |
| `DEX_LOOP_ACTIVE` | Enable phase audit loop | unset |
| `DEX_LOOP_PHASE` | Current phase (1-6 or "prompt-loop") | unset |
| `DEX_PHASE_HANDOFF` | Same-session phase handoff marker (`inline` for `dx`) | unset |
| `DEX_LOOP_PROMISE` | Human-readable completion acknowledgement; the generated receipt command carries authorization | unset |
| `DEX_LOOP_MAX_ITERATIONS` | Max loop iterations | 30 |
| `DEX_PHASE_TIMEOUT` | Seconds any one phase may run; `0` disables it | `0` (the session budget covers it) |
| `DEX_PHASE_<N>_TIMEOUT` | Same, for one phase only (e.g. `DEX_PHASE_2_TIMEOUT=3600`); wins over `DEX_PHASE_TIMEOUT` | unset |
| `DEX_STOP_SOUND` | Play a sound when Claude stops (macOS only); `0` turns it off | `1` |
| `DEX_STOP_SOUND_FILE` | Play this sound file instead of a random system one | unset |
| `DEX_SKIP_TOOL_BOOTSTRAP` | `1` makes `dx init` skip the Claude/Codex tooling bootstrap, for callers that already ran it | `0` |
| `DEX_SYNC_BUDGET_MINUTES` | Runtime budget for one `dx sync` provider run | 60 |
| `DEX_MAINTAIN_BUDGET_MINUTES` | Runtime budget for one scheduled maintenance run | 60 |
| `DEX_MAINTAIN_RESPOND_BUDGET_MINUTES` | Runtime budget for one maintenance PR feedback run | 30 |
| `DEX_REVIEW_TIER` | Canonical explicit review-risk override (`trivial`, `small`, `normal`, or `complex`); takes precedence over `DEX_REVIEW_PROFILE` | agent-selected |
| `DEX_REVIEW_SCOUT_PARALLELISM` | Provider-native review scouts allowed at once (0 to 3); `0` means the wave runs its lens groups sequentially | `0`, except `thorough` on an idle host with a diff above `review_scout_min_files` |
| `DEX_REVIEW_LEDGER_FILE` | Set by the loop: the findings ledger a wave reads and appends to (`<session>.review-findings.json`) | per session |
| `DEX_REVIEW_CONFIRMATION` | Set by the loop: `1` when this wave already has clean credit. It re-verifies the ledger and the delta, then — like every pass that would be declared clean — reviews the whole ticket diff with the coherence lens | `0` |
| `DEX_REVIEW_PROFILE` | Legacy review-depth alias (`light`, `standard`, or `thorough`) | unset |
| `DX_REVIEW_PROFILE` | Older spelling of `DEX_REVIEW_PROFILE`, still read as a fallback | unset |
| `DEX_REVIEW_CLEAN_PASSES` | Optional higher clean-wave requirement; cannot lower the selected tier's global policy gate | global policy (1/1/2/3 for trivial/small/normal/complex) |
| `DEX_REVIEW_DISABLE_MCP` | Disable inherited MCP servers in review waves (`0` restores them); read-only assessors always disable them | `1` |
| `DEX_REVIEW_PASS_TIMEOUT` | Seconds a review wave or risk assessment may run before its provider process tree is stopped and review pauses; `0` disables it | Profile-based: 15m assessment/light, 30m standard, 60m thorough |
| `DEX_REVIEW_PASS_RECHECK_SECONDS` | Seconds the Stop hook quietly polls for a busy Phase 3 review pass to finish | 45 (45s) |
| `DEX_TEST_JOBS` | Test-runner workers each Dex-launched session may use (1 to 32); exported to every launch as `DX_TEST_JOBS` and the runner variables listed in [docs/host-budget.md](host-budget.md) | half the cores shared across `DEX_REVIEW_MAX_ACTIVE_WAVES` sessions, capped at 4 |
| `DEX_MAX_ACTIVE_HEAVY` | Heavy commands (project gates, test suites, builds — never a dev server, which starts directly and is session-owned) admitted at once across every Dex session on this host (1 to 8) | `max(1, min(cpus/4, mem_gb/8))`, capped at 8 |
| `DEX_GATE_TIMEOUT` | Seconds one `dx run-gate` command may run before its process tree is stopped; `0` means no deadline, which is the point — a completed result is never discarded | `0` |
| `DEX_GATE_HEARTBEAT_SECONDS` | How often `dx run-gate` prints its queue position while it waits (1 to 9999) | 30 |
| `DEX_GATE_PRIORITY` | Pin the reduced-priority wrapper heavy commands run under: `none`, `nice`, `nice+taskpolicy`, `nice+ionice`, `systemd-run`, `systemd-run+ionice`, or `auto` to probe this host | `auto` |
| `DX_HOST_CPUS_OVERRIDE` | Replace the logical-CPU probe. For a container that knows its own share, and for tests. A malformed value is ignored. Separate from the published `DX_HOST_CPUS` so a nested launch re-measures instead of repeating its parent's snapshot | measured, lowered to a cgroup v2 `cpu.max` quota when one is smaller |
| `DX_HOST_MEM_GB_OVERRIDE` | Replace the total-memory probe, in whole gigabytes. A malformed value fails the reader, the way `DX_HOST_MEMORY_FREE_PERCENT` does | measured, lowered to a cgroup v2 `memory.max` limit when one is smaller |
| `DX_HOST_LOAD1_OVERRIDE` | Replace the one-minute load-average probe. Load is the one fact that changes minute to minute, so the published `DX_HOST_LOAD1` is never read back as an input | `/proc/loadavg`, else `sysctl -n vm.loadavg` |
| `DX_HOST_CGROUP_DIR` | Where to look for the cgroup v2 limit files `cpu.max` and `memory.max` | `/sys/fs/cgroup` |
| `DEX_MIN_FREE_MEMORY_PERCENT` | Free-memory floor below which a review wave waits before joining waves already running; `0` disables the check | 10 |
| `DEX_MAX_CONCURRENT_SUBAGENTS` | Subagents one Dex-launched session may run at once (`CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`); review waves use their scout parallelism instead | 4 |
| `DEX_MAX_SUBAGENT_SPAWN_DEPTH` | How deep subagents may nest in a Dex-launched session (`CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH`); review waves use 1 | 2 |
| `DEX_WORKTREE_SHARED_DIRS` | Ignored top-level directories a new worktree links from the main checkout instead of rebuilding; empty disables | `node_modules target .venv vendor .next .nuxt` |
| `DEX_WATCH_CYCLE_TIMEOUT_SECONDS` | Maximum runtime budget for one scheduled Phase 6 watcher invocation; a cycle past it hands over to the next tick, and a watcher that exits hands over at once. `0` means no budget | 120 (2m 0s) |
| `DEX_WATCH_COMMAND_TIMEOUT_SECONDS` | Maximum runtime for one GitHub/local shell command inside a watcher cycle | 30 (30s) |
| `DEX_WATCH_PAUSE_TTL_SECONDS` | Seconds scheduled Phase 6 watchers stay paused after a direct user prompt | 3600 (1h 0m) |
| `DEX_COMPLETE_MAX_CYCLES` | Max idle PR watch cycles before Phase 6 pauses for manual follow-up | 3 |
| `DEX_COMPLETE_WAIT_MINUTES` | Minimum wait window per Phase 6 cycle (minutes) | 5 |
| `DEX_SESSION_ID` | Unique session ID (set by dxloop for stop hook) | unset |
| `DEX_REVIEW_ASSESSMENT_ACTIVE` | Internal marker for the read-only preflight risk assessor | unset |
| `DEX_REVIEW_PASS_ACTIVE` | Marks a session as a single-shot review-wave pass so its Stop hook can never run the parent lifecycle's inline phase handoff | unset |
| `CODEX_HOME` | Codex config root used for Dex skill links | `~/.codex` |
| `DX_AGENT` / `DX_AGENT_OVERRIDE` | Agent override (`claude` or `codex`) | profile/default |
| `DX_MODEL` / `DX_MODEL_OVERRIDE` | Model override for the selected agent | profile/default |
| `DX_PROVIDER_PROFILE` | Provider profile override (`claude-subscription`, `codex-subscription`, or custom) | config/default |
| `DX_CLAUDE_MODEL` | Override Claude Code model passed to `--model` | profile model, else session default |
| `DX_PLAN_MODEL` | Override Phase 1/plan model | `DX_CLAUDE_MODEL`, profile plan model, else session default |
| `DX_CODEX_MODEL` | Resolved Codex model passed through `bin/dxcodex.sh` | profile codex model, else Codex default |
| `DX_CODEX_READ_ONLY` | Internal marker that switches Codex delegation to an ephemeral read-only sandbox and forbids dangerous bypass flags | `0` |
| `DX_CLAUDE_EFFORT` | Override Claude Code `--effort` | profile effort, else session default |
| `DX_PLAN_EFFORT` | Override Phase 1/plan effort | `DX_CLAUDE_EFFORT`, profile plan effort, else session default |
| `DX_ALLOW_API_BILLED_AUTH` | Allow `dx provider doctor` to tolerate API/gateway env vars | `0` |
| `DX_ALLOW_REPO_GATEWAY_PROVIDER` | Explicitly allow a trusted repo-local gateway/API provider profile for the current invocation | `0` |
| `DX_ALLOW_FORK_PR_CHECKOUT` | Skill-level opt-in letting `/dxprreview` check out fork PRs | `0` |
| `DEX_LIFECYCLE_MINIMAL_MCP` | Launch the lifecycle phases that never open a browser (4 Verify, 5 PR, 6 Complete, and 1 Plan when the launch ends with the phase) with no MCP servers, the way review waves already launch; `0` keeps whatever the session inherited. Phases 0, 2 and 3, standalone sessions, and interactive `claude` are untouched | `1` |
| `DEX_UI_MCP_SCOPE` | Claude MCP scope `dx ui-capture install` registers the browser servers in (`user`, `project`, or `local`), same as its `--user`/`--project`/`--local` flags; `project` writes the repository's tracked `.mcp.json` at the checkout root and falls back to `user` outside a checkout. `dx install` always uses user scope | `user` |
| `DEX_SESSION_RSS_SAMPLE_SECONDS` | How often the runtime supervisor samples the peak resident size of the session's token-carrying process tree, on the heartbeat it already runs. Clamped to 1..3600; a malformed value falls back to the default rather than refusing to supervise | 30 |
| `DEX_WORKTREE_HOOK_TIMEOUT` | Seconds one `## Worktree Hooks` command (`after_create`, `before_remove`, `on_session_end`, `orphan_resources`) may run before its process tree is stopped; `0` removes the deadline, except for `on_session_end`, which is capped at 5 s whatever this says because the host gives the whole SessionEnd hook ten seconds. A hook that is stopped, or that fails, warns and never blocks the create or remove. See [docs/worktree-hooks.md](worktree-hooks.md) | 300 (5m 0s) |
| `DEX_REVIEW_CHECK_TIMEOUT` | Seconds one deterministic check may run before `bin/review-check.sh` reports it `over-budget`. It no longer stops the command: a late result keeps its real exit code and duration and is cached like any other | 900 (15m 0s) |
| `DEX_REVIEW_CHECK_HARD_TIMEOUT` | The only deadline that stops a check. Reaching it is exit 124 with no reusable result, the way the execution budget used to behave | 4 × `DEX_REVIEW_CHECK_TIMEOUT` (3600) |
| `DEX_REVIEW_CHECK_QUEUE_TIMEOUT` | Seconds a check may wait for the host check pool before it gives up with the `queued` status — exit 75, nothing ran, ask again later. `0` waits with a heartbeat, because waiting is not a failure | `0` |
| `DEX_REVIEW_CHECK_HEARTBEAT_SECONDS` | How often a queued check prints its queue position and the age of the oldest running check (1 to 9999) | 30 × `DEX_REVIEW_CAPACITY_RECHECK_SECONDS` |
| `$DX_STATE_DIR/guard-heavy-commands.json` | Not a variable, but the one file `hooks/guard-handler.py` writes: each repository's parsed `heavy_commands`, keyed by its `.dex/dex.md` path, mtime and size, so the advisory does not re-import the contract parser on every Bash call. Advisory cache only — deleting it costs one re-parse. 0600, capped at 32 repositories | `~/.claude/.dex-phases/guard-heavy-commands.json` |
