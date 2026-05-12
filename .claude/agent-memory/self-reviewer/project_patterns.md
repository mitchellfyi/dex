---
name: project_patterns
description: Recurring patterns, known issues, and common mistakes in the doyaken codebase
type: project
---

## State File Cleanup Patterns

dk_cleanup_session() in lib/session.sh is the canonical way to remove all loop+phase state files for a session. It covers loop files including .state, .complete, .active, .prompt, .findings, .debt, .config, handoff/paused/watch/provider/review/complete state, and phase marker files, plus phase files including .phase, .times, .system-context, .log, and .branch.

dkloop (shell function) intentionally does a SUBSET cleanup (only loop files, no .active or phase files) because it never creates .config or phase state. This is not an inconsistency.

dkclean stale file cleanup (dk_cleanup_stale_files) now covers the loop/session extensions that can otherwise accumulate, including prompt, config, findings, debt, provider, phase markers, watch pause/lock files, plus phase/timing/context/log/branch files. Do not report missing findings/debt/config stale cleanup as a current gap without re-checking dk.sh.

## Install/Uninstall Symmetry

install.sh checks for existing install with: `grep -q 'doyaken/dk.sh' "$ZSHRC"` — this assumes DOYAKEN_DIR path contains 'doyaken'. This is a pre-existing assumption.

install.sh has an upgrade path for existing source lines that lack `export DOYAKEN_DIR=...`: it inserts the export before the source line. The old regression where re-running install skipped the export is fixed.

uninstall.sh uses `grep -v 'DOYAKEN_DIR'` to remove the export line — this is intentionally broad and will also remove any user-written DOYAKEN_DIR references in .zshrc.

## awk ENVIRON Pattern

config.sh uses `_DKTMP="$path" awk '... ENVIRON["_DKTMP"] ...'` to pass file paths to awk programs. This is the correct pattern to avoid: (1) shell injection via string interpolation, (2) BSD awk multiline -v bugs, (3) whitespace/quoting issues in paths.

## Session ID Derivation

dk_session_id() without args reads from the Doyaken worktree path or current branch name. With an arg it derives a worktree session. All normal session IDs are prefixed with a stable repo key such as `repo-doyaken-cli-3495066660-...` to prevent cross-repo collisions. IDs are NOT cryptographically random — documented in session.sh.

dk_unique_session_id() (added 2026-03-21): appends PID + epoch to branch-based ID. Used by dkloop to prevent collisions across concurrent invocations. The unique ID is passed via DOYAKEN_SESSION_ID env var so phase-loop.sh and skills (dkloop, dkcomplete) use the correct ID.

Implication: dkloop generates a new session ID every run. Stale files from interrupted unique-ID runs are not found by the next run by name, but dkclean prunes old loop/session files after 7 days, including prompts and review/debt/config/provider markers.

## dkloop Two-Phase Architecture (as of 2026-03-21)

dkloop now runs two sequential Claude sessions: (1) Plan session in --permission-mode plan (no stop hook), (2) Implement session in bypassPermissions with stop hook active. DOYAKEN_SESSION_ID is set for both sessions. Plan interruption exits early and cleans up all state files.

## lib/worktree.sh (added 2026-03-21)

New library providing: dk_wt_branch, dk_wt_remove, dk_cleanup_last_session, dk_cleanup_stale_files. Sourced via common.sh. The header claims "Used by bin scripts (uninit.sh)" but uninit.sh does not call any functions from worktree.sh directly — it uses session.sh functions only. The header is inaccurate for uninit.sh.

## phase-loop.sh: .config Ordering (fixed)

phase-loop.sh reads the per-session `.config` before applying `.active` prompt-loop defaults, so file-backed phase/promise/audit values are no longer overridden when hook env vars are missing. Do not report the old `.active` default-ordering bug without re-checking phase-loop.sh.

## Atomic Write Consistency

phase-loop.sh's atomic write pattern includes `rm -f "$TEMP_FILE"` cleanup on failure. dk.sh's `__dk_write_state` now also includes `rm -f "$tmp"` on failure (fixed as of 2026-03-27). Both are now consistent.

## DK_PHASE_TIMEOUTS Off-By-One (fixed 2026-03-27)

The 9801e2f commit missed DK_PHASE_TIMEOUTS when converting arrays from 0-indexed to 1-indexed. Fixed by removing the leading "" element.

## dkclean Gone Branch Deletion Scope (fixed 2026-03-27)

dkclean step 2 now only targets `worktree-ticket-*` and `worktree-task-*` branches, matching the step 3 prefix filter. Non-doyaken branches with gone upstreams are no longer affected.

## dkclean Missing .log Extension (fixed 2026-03-27)

dkclean stale file cleanup now includes "log" extension, matching dk_cleanup_session()'s coverage.

## Error Output on Wrong Stream (fixed 2026-03-27)

All `echo "ERROR: ..."` calls in dk.sh (except line 24, which runs before lib/output.sh is available) now use `dk_error()` / `dk_info()` for proper stderr routing and formatted output.

## max-iter Status: Dead Code

`__dk_classify_exit` documents and the `format_status` in log.sh handles a "max-iter" status, but this status is never produced. `phase-loop.sh` exits 0 (not a distinct code) when max iterations are reached, so `__dk_classify_exit` always returns "advance" for exit 0. The log.sh `max-iter` case is dead code.

## Watchdog Process Tree Pattern

The phase timeout watchdog must not assume the launched subshell owns a process group. The current pattern uses `__dk_kill_process_tree` to terminate the wrapper and descendants. If changing timeout code, preserve child-process cleanup rather than reverting to negative-PID process-group kills.

## Commit Message Pattern

All commits in this repo use single-word messages ("init", "fix", "rename") — this is the established style.

## Research Harness: Node.js require() Fallback Pattern

In rubric.sh files, the pattern `require('./src/cart.js') || require('./cart.js')` does NOT work as a fallback. `require()` throws `MODULE_NOT_FOUND` (does not return null/undefined), so the `||` branch never executes. The correct pattern is a try/catch or pre-checking the path with `fs.existsSync`.

## Research Harness: Subshell Process Kill Pattern

`(cd "$ws" && cmd) &` followed by `server_pid=$!` and `kill "$server_pid"` kills the bash subshell wrapper, NOT necessarily the inner `cmd` process. Rubrics that start servers this way should use a cleanup helper that tries process-group cleanup and direct-PID fallback. The auth-jwt-api rubric uses `_kill_auth_server` for this.

## Research Harness: RUN_ID Capture via tail -1

loop.sh captures run.sh's RUN_ID via `2>&1 | tail -1`. This works because `echo "$RUN_ID"` is the absolute last output line in run.sh. If a new echo or log statement is added after that line in run.sh, the capture breaks silently. This is a fragile coupling. Same pattern in orchestrate.sh for both run.sh and improve.sh captures.

## Research Harness: 'local' Outside Function in loop.sh (fixed 2026-03-27)

Fixed by removing `local` keyword from top-level variables `applied` and `part_idx` in loop.sh.

## Research Harness: Rubric Function Pollution (fixed 2026-03-27)

Fixed by adding `unset -f` loop for all `rubric_*` functions before sourcing each scenario's rubric.sh in score_scenario().

## Research Harness: access_token Injection Into node -e (fixed 2026-03-27)

Fixed in auth-jwt-api/rubric.sh by passing the JWT token via `ACCESS_TOKEN` env var and reading with `process.env.ACCESS_TOKEN` instead of string interpolation. Server cleanup uses `_kill_auth_server`, which tries process-group cleanup and direct-PID fallback from a RETURN trap.

## Research Harness: LLM Judge Response Triple-Quote Corruption (fixed 2026-03-27)

Fixed by passing judge_result via `_JR` env var and reading with `os.environ.get('_JR','')` instead of Python triple-quote interpolation.

## Research Harness: orchestrate.sh Skips Branch/Clean Safety Checks (fixed 2026-03-27)

Fixed by adding `safety_check_branch` and `safety_check_clean` calls to pre-flight section. Also fixed duplicate arg parsing (positional `$1/$2` overwritten by `--flag` loop) by removing the positional defaults.

## lib/ Cross-Shell BASH_SOURCE Pattern (Intentionally Correct — Do Not Flag)

common.sh uses `_dk_self="${BASH_SOURCE[0]:-$0}"`. In bash, BASH_SOURCE[0] = sourced file path. In zsh, BASH_SOURCE[0] = empty string (not an error), $0 = sourced file path. Both cases are correct. This is an intentional idiom. Do NOT flag it.

## lib/session.sh: DK_STATE_DIR / DK_LOOP_DIR Not Exported (Intentionally Correct — Do Not Flag)

Set (not exported) in common.sh. All consumers source common.sh in the same shell process before using them. Not exporting is correct. Do NOT flag "not exported" as a bug.

## lib/session.sh: SC2120/SC2119 Shellcheck Warnings (False Positive — Do Not Flag)

shellcheck SC2120 warns dk_session_id "references arguments but none are passed" — false positive because callers (dk.sh, hooks, bin/) all pass arguments. SC2119 is informational only. Not a real issue.

## dk_slugify: Unicode Passthrough in UTF-8 Locale (fixed 2026-03-27)

Fixed by using `LC_ALL=C sed 's/[^a-z0-9]/-/g'` instead of bash `${slug//[^a-z0-9]/-}` which is locale-dependent. The `LC_ALL=C` forces byte-level matching so multi-byte UTF-8 chars are replaced with dashes.

## output.sh: Write Tool Mislabeled as "Editing" in Progress Filter (fixed 2026-03-27)

Fixed by splitting the `('Write', 'Edit')` tuple into separate cases: Edit shows "Editing", Write shows "Writing". Also removed redundant initial `print('\r\033[K', end='')` before the Thinking message.

## dk_cleanup_stale_files: Empty find_args + Double-Find (fixed 2026-03-27)

Fixed both issues: (1) Added early return guard for empty `$extensions`, (2) Replaced two-pass find (count then delete) with single-pass `find ... -delete -print | wc -l` that atomically counts what it deletes.

## status-line.sh: Loop State File Format Mismatch (fixed 2026-03-27)

Fixed by using `cut -d: -f1` instead of raw `cat` to extract only the iteration number from the `ITERATION:EPOCH:STALL_COUNT` format.

## uninit.sh: Global last-session File Removed Too Broadly (fixed 2026-03-27)

Fixed by replacing unconditional `rm -f "$DK_STATE_DIR/last-session"` with a loop that calls `dk_cleanup_last_session` for each worktree, which checks ownership before deleting.

## config.sh: MCP Server Names Display with JSON Quotes (fixed 2026-03-27)

Fixed by adding `-r` flag to `jq -s` → `jq -rs` so server names are output as raw strings instead of JSON-quoted.

## guard-handler.py: Missing 'event' Field in Guard Silently Skipped (fixed 2026-03-27)

Fixed by adding a warning log (matching the existing 'pattern' warning style) when a guard is missing the 'event' frontmatter field, before skipping it.

## Research Harness: json_field Shell Injection (fixed 2026-03-27)

research/lib/common.sh json_field() interpolated file path and key directly into Python code via `open('$file')` and `d.get('$key')`. Fixed by passing both via env vars `_JF_FILE` and `_JF_KEY` and reading with `os.environ[]`.

## dk.sh: Revert Hint Wrong for Task Worktrees (fixed 2026-03-27)

`${wt_name##*-}` stripped to last segment, breaking for multi-segment names like `task-fix-login` → `login`. Fixed by passing the full `$wt_name`.

## dk.sh: dkloop Empty Slug Fallback (fixed 2026-03-27)

When prompt contains only non-alphanumeric characters, `dk_slugify` returns empty string, leaving `session_name=""`. Fixed by falling back to `dkloop-$(date +%s)` when slug is empty.
