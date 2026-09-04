# Workflow Operations

Durable lessons about the Dex lifecycle: phase ownership, in-place vs
worktree branch modes, runtime leases, and shared global state Dex touches
outside the repo.

## M-002: Phase gates stay owned while Git history follows the work

Domain: workflow-operations
Status: active
Scope: dx.sh phase routing, skills/dx*/SKILL.md, prompts/phase-audits/*.md, hooks/phase-loop.sh, hooks/user-prompt-submit.sh
Applies to phases: plan, implement, review, verify, pr, complete
Applies to paths: dx.sh, skills/, prompts/phase-audits/, hooks/phase-loop.sh, hooks/user-prompt-submit.sh
Last verified: 2026-09-03
Recheck when: a new phase is introduced, phase ownership changes, or phase audit prompts are rewritten

Lesson:
Dex's six-phase lifecycle (Plan → Implement → Review → Verify → PR → Complete)
keeps each gate with its owning phase while Git history follows the work. Phase
2 commits and pushes coherent implementation checkpoints. The active Phase 3
wave may commit and push accepted review fixes after it has exclusive ownership
of the checkout; the lifecycle parent remains quiescent while that child runs.
Phase 4 is the final PR verification gate and records any repair checkpoints it
produces. Phase 5 owns PR creation and must leave the PR ready for review.
Phase 6 owns external reviewer polling and resolves actionable feedback, but a
missing review or approval does not block completion. A full verification pass
is not a prerequisite for committing or pushing, but it must pass before PR
handoff.

Evidence:
- `c8f3660 fix(dex): defer draft PR creation to Phase 5 (/dxpr)` — Phase 5
  owns PR creation; earlier phases must not create one.
- `d868c38 fix: pause phase three while reviews run` — review wave must not race
  the calling phase.
- `d6983ef fix(watchers): pause phase 6 watchers on user prompts` — only Phase 6
  watches external reviewers; watcher scope is pinned.
- `05b7ced fix: gate phase one audit until plan approval` — Phase 1 audit must
  wait for explicit plan approval.
- `e33d9dc fix(dex): skip go-ahead prompt between plan approval and
  implementation` — handoff stays inside the lifecycle.
- `1b2c00e fix: make dxreview dispatch to review loop` — `/dxreview` must
  dispatch into the review wave loop, not freelance.
- `457697c feat(lifecycle): make Phase 5 publish ready PRs` — Phase 5 owns the
  ready-for-review transition; Phase 6 keeps an idempotent repair path.
- `ade235f fix(lifecycle): stop gating completion on PR approval` — reviewer
  rows route notifications, while Phase 6 reports merge-review state without
  waiting solely for an approval.
- `prompts/commit-format.md`, `skills/dxcommit/SKILL.md`, and
  `skills/dxverify/SKILL.md` define commits as working-history checkpoints and
  final verification as the PR gate.
- `lib/review-loop.sh` gives the active lifecycle review wave its publication
  boundary while continuing to forbid branch switches and PR changes.
- `.dex/review-rules.md` § `skills/*/SKILL.md` and § `prompts/phase-audits/`
  already codify these constraints.

Future agent behavior:
- When editing a lifecycle skill or phase-audit prompt, re-verify the phase
  boundaries in `dx.sh` and `hooks/phase-loop.sh` before changing what the
  skill or audit triggers.
- Do not make a green full-suite result a prerequisite for a coherent commit or
  push. Keep failing and pending checks explicit, and require the final
  pipeline before PR handoff.
- Only the active Phase 3 review wave records its accepted fixes. The lifecycle
  parent must remain quiescent until the review-child fence clears.
- A Phase 3 single-wave audit may complete with `FINDINGS_FIXED:N`; the outer
  `/dxreviewloop` owns the selected tier's consecutive-`CLEAN` gate.
- Do not add PR creation, reviewer requests, readiness transitions, or external
  reviewer polling outside the phase that owns them. Phase 5 must leave the PR
  ready; Phase 6 may repair readiness but must not treat approval as its gate.
- When a new phase audit prompt is added, confirm its completion criteria match
  the state/result files read by `dx.sh` and `hooks/phase-loop.sh`.

## M-003: In-place lifecycle mode is a first-class peer to worktree mode

Domain: workflow-operations
Status: active
Scope: dx.sh lifecycle and cleanup helpers, bin/uninit.sh, hooks/session-end.sh, lib/session.sh, lib/worktree.sh
Applies to phases: implement, verify, complete (cleanup paths), and any session lifecycle change
Applies to paths: dx.sh, bin/uninit.sh, hooks/session-end.sh, lib/session.sh, lib/worktree.sh
Last verified: 2026-09-03
Recheck when: branch-mode handling changes, worktree creation/cleanup logic changes, or session ID derivation changes

Lesson:
Dex supports two workspace modes — worktree mode and in-place mode (where
the user works directly on a feature branch). Cleanup, resume, session-end, and
state file logic must protect active in-place lifecycle branches just as
carefully as worktree directories. In-place branches can be renamed, and stale
session files must be removed without destroying active state.

Evidence:
- `043685c feat: support in-place lifecycle branches` introduces the mode.
- `02028e5 fix(cleanup): preserve active in-place lifecycle state` (149 LoC in
  dx.sh) protects active in-place branches during cleanup, handles renamed
  branches, and removes stale session files for branch-only cleanup.
- `b190695 fix: harden in-place lifecycle resumes`.
- `088cc27 fix: scope session-end branch state`.
- `39d811c fix: harden task lifecycle branch state`.
- `c61b8b1 fix: recover inline hooks from stale phase env`.
- `24d8a8f fix(lifecycle): let a dirty in-place checkout keep its pure branch
  rename` confirms that dirty-tree rejection belongs only on operations that
  move the working tree, not on in-place bookkeeping or a pure branch rename.
- `dx.sh` line 218+ and 387+ branches explicitly on `workspace_mode == in-place`.

Future agent behavior:
- When editing cleanup, resume, session-end, or branch-state code, exercise
  both `workspace_mode == in-place` and worktree code paths before merging.
- Do not assume the session is tied to a `.dex/worktrees/` directory —
  in-place sessions key off the branch name plus repo key, not a worktree path.
- Cleanup logic must skip active in-place branches and handle branch renames
  without deleting state.
- Permit an already-authorized dirty in-place checkout to record state or
  rename its current branch without rejecting it merely for being dirty. Keep
  dirty-tree checks on branch switches, fast-forward merges, and hard resets.
- New session/branch state files must be cleaned up by `dx_cleanup_session`
  and legacy migration when appropriate (per `.dex/review-rules.md` §
  `lib/*.sh`).

## M-004: Dex-owned global state must be tracked separately from user state

Domain: workflow-operations
Status: active
Scope: bin/install-settings.sh, bin/uninstall.sh, bin/config.sh, settings.json install/uninstall paths, MCP server configuration
Applies to phases: install, uninstall, config (outside the per-ticket lifecycle)
Applies to paths: bin/install-settings.sh, bin/uninstall.sh, bin/config.sh, ~/.claude/.dex-install-state.json
Last verified: 2026-05-27
Recheck when: install/uninstall logic changes, settings.json schema changes, MCP server config rules change, or the install-state file moves

Lesson:
The user's global `~/.claude/settings.json` and MCP server configuration are
shared user-owned state. Dex install and uninstall must preserve existing
user entries (worktree symlinks, MCP server definitions, hooks, permissions) and
must only remove entries that Dex itself wrote. Provenance is tracked via
`~/.claude/.dex-install-state.json`. Existing-settings installs require
`jq`; fail closed when it is missing rather than overwriting JSON blindly.

Evidence:
- `d442a7b fix(settings): preserve user-owned global config` (188 lines added
  across `bin/install-settings.sh`, `bin/uninstall.sh`, `bin/config.sh`):
  preserves worktree symlinks during install/uninstall, tracks Dex-owned
  entries with install-state provenance, fails existing-settings installs
  without jq, avoids overwriting global MCP server definitions.
- `bin/install-settings.sh` declares `INSTALL_STATE_FILE="$CLAUDE_DIR/.dex-install-state.json"`.
- `71ab07b feat(tooling): bootstrap RTK token reduction` adds the new
  `rtk-claude-hook.sh` to the Dex-owned hook provenance detector in
  `bin/install-settings.sh`, confirming new hooks are registered for scoped
  uninstall rather than left untracked (see [[architecture-decisions]] M-008).

Future agent behavior:
- When modifying install or uninstall logic for `~/.claude/settings.json` or
  MCP config, never overwrite the file wholesale. Merge using `jq`, scoped to
  the keys Dex owns according to the install-state file.
- Track every newly written entry in `.dex-install-state.json` so a future
  uninstall can remove only what Dex added.
- If `jq` is missing on a system with existing settings, fail closed with a
  clear error rather than degrading to a destructive overwrite.
- Apply the same separation to any future shared global config (hooks,
  permissions, environment, MCP servers).

## M-010: Runtime lock lineage gates mutations, not durable reads or recovery

Domain: workflow-operations
Status: active
Scope: lifecycle runtime records, mutation locks, health checks, restart, and recovery
Applies to phases: any lifecycle phase; session resume, recovery, cleanup, and maintenance
Applies to paths: lib/session-runtime.sh, lib/session.sh, lib/session-management.sh, hooks/session-end.sh, tests/session-runtime*.sh
Last verified: 2026-09-04
Recheck when: the runtime record schema changes, lock identity fields change, a new runtime mutation is added, or restart/recovery ownership rules change

Lesson:
Runtime records are durable across reboots and state-directory moves, but their
stored lock device, inode, and generation describe the lock held when the lease
was published. macOS can change a volume's device number after reboot, and a
synced state directory can carry an entirely foreign lock identity. Public
reads, health checks, restart, and recovery therefore validate the record
without requiring its old lock identity to match the current lock. A new lease
must acquire the live mutation lock and bind the published record to that lock.
Heartbeat, finish, purge, and publication mutate a live lease, so they must
still require the record's lock lineage and authenticated owner token.

Evidence:
- Commit `8b28129 fix(runtime): resume records with stale lock identities after
  reboots` separates durable reads, restart, and recovery from live-lease
  mutation checks and adds rebooted-device and foreign-state-directory cases to
  `tests/session-runtime-core-test.sh`.
- `lib/session-runtime.sh` documents the split beside `require_record_lock()`:
  publication and lease mutations require the recorded lineage; starts,
  recovery, and public reads deliberately do not.
- `publish_record()` verifies the held lock before and after its atomic write,
  then checks the published record against the live lock. Heartbeat, finish,
  and purge acquire that lock and authenticate the lease token and owner.
- Commits `0affea8 fix(lock): record the acquiring process, not the top-level
  shell` and `d7e2bcd fix: second-wave robustness pass over hooks, control, and
  periphery` reinforce the same rule at callers: lock ownership belongs to the
  process that acquires the lock, except where a documented command-substitution
  boundary intentionally delegates ownership to its caller.

Future agent behavior:
- Do not reject a validated runtime record only because its stored lock device,
  inode, or generation differs from the current lock during a public read,
  restart, or dead-owner recovery.
- Acquire and revalidate the live mutation lock before publishing a new lease,
  and write that lock's current identity into the record.
- Keep heartbeat, finish, purge, and any new live-lease mutation bound to the
  recorded lock lineage, lease token, and stable process identity.
- When passing a lock owner PID through a helper or command substitution, use
  the process that actually owns the critical section and document deliberate
  exceptions.
- Exercise rebooted-device, foreign-state-directory, replaced-lock, stale-owner,
  and token-mismatch cases when changing runtime ownership semantics.
