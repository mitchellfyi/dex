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
| `project-state.sh` | Init ownership snapshots and conservative project cleanup | `dx_project_state_begin()`, `dx_project_state_finalize()`, `dx_project_state_remove_managed()` |
| `review.sh` | Scope-bound review selection/state, evidence, deterministic baselines, wrapper-clock metrics, retained proofs, ledgers, receipts, result parsing, churn detection, and telemetry JSON | `dx_review_evidence_valid()`, `dx_review_baseline_publish()`, `dx_review_metrics_mark()`, `dx_review_ledger_valid()`, `dx_review_write_receipt()`, `dx_review_event_json()` |
| `review-capacity.sh` | Host-wide FIFO admission, PID-reuse-safe stale-owner recovery, and separate review/check capacity limits | `dx_review_capacity_limit()`, `dx_review_capacity_wait()`, `dx_review_capacity_release()` |
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
| `session.sh` | Session ID derivation, state file paths | `dx_session_id()`, `dx_provider_state_file()`, `dx_cleanup_session()` |
| `session-management.sh` | Strict internal lifecycle-session cleanup transactions | `__dx_session_management_cleanup_exact()` |
| `output.sh` | Formatted user-facing output | `dx_done()`, `dx_ok()`, `dx_warn()`, `dx_error()`, etc. |
| `host-budget.sh` | Per-session host budget: test-job count, runner environment (`DX_TEST_JOBS`, vitest, pytest-xdist, cargo, go, make), subagent caps, and the free-memory probe behind review-wave admission | `dx_host_test_jobs()`, `dx_host_budget_env()`, `dx_host_memory_free_percent()`, `dx_host_memory_low()` |
| `ui-capture.sh` | Playwright/UI capture tooling, artifact paths, MCP bootstrap | `dx_install_ui_capture_tooling()`, `dx_ui_capture_run_dir()`, `dx_ui_capture_playwright_ready()` |
| `triage.sh` | Standalone ticket triage arguments, provider launch, and isolated cleanup | `dx_triage_run()`, `dx_triage_cleanup()` |
| `worker.sh` | DexCode worker registration and the poll/claim/lease/settle daemon | `dx_worker_command()`, `dx_worker_register()`, `dx_worker_daemon()` |
| `worktree.sh` | Worktree management utilities | `dx_wt_branch()`, `dx_wt_remove()`, `dx_cleanup_last_session()`, `dx_cleanup_stale_files()` |

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
| `DEX_REVIEW_TIER` | Canonical explicit review-risk override (`small`, `normal`, or `complex`); takes precedence over `DEX_REVIEW_PROFILE` | agent-selected |
| `DEX_REVIEW_PROFILE` | Legacy review-depth alias (`light`, `standard`, or `thorough`) | unset |
| `DX_REVIEW_PROFILE` | Older spelling of `DEX_REVIEW_PROFILE`, still read as a fallback | unset |
| `DEX_REVIEW_CLEAN_PASSES` | Optional higher clean-wave requirement; cannot lower the selected tier's global policy gate | global policy (1/2/3) |
| `DEX_REVIEW_DISABLE_MCP` | Disable inherited MCP servers in review waves (`0` restores them); read-only assessors always disable them | `1` |
| `DEX_REVIEW_PASS_TIMEOUT` | Seconds a review wave or risk assessment may run before its provider process tree is stopped and review pauses; `0` disables it | Profile-based: 15m assessment/light, 30m standard, 60m thorough |
| `DEX_REVIEW_PASS_RECHECK_SECONDS` | Seconds the Stop hook quietly polls for a busy Phase 3 review pass to finish | 45 (45s) |
| `DEX_TEST_JOBS` | Test-runner workers each Dex-launched session may use (1 to 32); exported to every launch as `DX_TEST_JOBS` and the runner variables listed in [docs/host-budget.md](host-budget.md) | half the cores shared across `DEX_REVIEW_MAX_ACTIVE_WAVES` sessions, capped at 4 |
| `DEX_MIN_FREE_MEMORY_PERCENT` | Free-memory floor below which a review wave waits before joining waves already running; `0` disables the check | 10 |
| `DEX_MAX_CONCURRENT_SUBAGENTS` | Subagents one Dex-launched session may run at once (`CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`); review waves use their scout parallelism instead | 4 |
| `DEX_MAX_SUBAGENT_SPAWN_DEPTH` | How deep subagents may nest in a Dex-launched session (`CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH`); review waves use 1 | 2 |
| `DEX_VERIFY_FULL_SUITE` | `ci` makes CI the full-test-suite gate: Phase 4 runs the focused tests locally and reports the suite as `CI`, and Phase 6 fixes a CI failure like any other verification failure | unset (run locally) |
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
