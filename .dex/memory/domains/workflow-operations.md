# Workflow Operations

Durable lessons about the Dex lifecycle: phase ownership, in-place vs
worktree branch modes, and shared global state Dex touches outside the repo.

## M-002: Each lifecycle phase owns its outputs strictly — no spillover

Domain: workflow-operations
Status: active
Scope: dx.sh phase routing, skills/dx*/SKILL.md, prompts/phase-audits/*.md, hooks/phase-loop.sh, hooks/user-prompt-submit.sh
Applies to phases: plan, implement, review, verify, pr, complete
Applies to paths: dx.sh, skills/, prompts/phase-audits/, hooks/phase-loop.sh, hooks/user-prompt-submit.sh
Last verified: 2026-05-15
Recheck when: a new phase is introduced, phase ownership changes, or phase audit prompts are rewritten

Lesson:
Dex's six-phase lifecycle (Plan → Implement → Review → Verify & Commit →
PR → Complete) enforces strict ownership: no commits in Phase 3, no PR creation
before Phase 5, no external reviewer polling before Phase 6, and no work begins
in Phase 2 before plan approval finishes in Phase 1. Phase audit prompts and
skills must not duplicate or cross another phase's gate.

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
- `.dex/review-rules.md` § `skills/*/SKILL.md` and § `prompts/phase-audits/`
  already codify these constraints.

Future agent behavior:
- When editing a lifecycle skill or phase-audit prompt, re-verify the phase
  boundaries in `dx.sh` and `hooks/phase-loop.sh` before changing what the
  skill or audit triggers.
- A Phase 3 single-wave audit may complete with `FINDINGS_FIXED:N`; the outer
  `/dxreviewloop` owns the three-consecutive-`CLEAN` gate.
- Do not add PR creation, reviewer requests, draft-PR transitions, or external
  reviewer polling outside the phase that owns them.
- When a new phase audit prompt is added, confirm its completion criteria match
  the state/result files read by `dx.sh` and `hooks/phase-loop.sh`.

## M-003: In-place lifecycle mode is a first-class peer to worktree mode

Domain: workflow-operations
Status: active
Scope: dx.sh lifecycle and cleanup helpers, bin/uninit.sh, hooks/session-end.sh, lib/session.sh, lib/worktree.sh
Applies to phases: implement, verify, complete (cleanup paths), and any session lifecycle change
Applies to paths: dx.sh, bin/uninit.sh, hooks/session-end.sh, lib/session.sh, lib/worktree.sh
Last verified: 2026-05-15
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
- `dx.sh` line 218+ and 387+ branches explicitly on `workspace_mode == in-place`.

Future agent behavior:
- When editing cleanup, resume, session-end, or branch-state code, exercise
  both `workspace_mode == in-place` and worktree code paths before merging.
- Do not assume the session is tied to a `.dex/worktrees/` directory —
  in-place sessions key off the branch name plus repo key, not a worktree path.
- Cleanup logic must skip active in-place branches and handle branch renames
  without deleting state.
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
