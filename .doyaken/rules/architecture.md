# Architecture Patterns

## Hook Integration

Hooks defined in `settings.json`, referenced by paths to Doyaken scripts:

| Hook | Event | Script | Purpose |
|------|-------|--------|---------|
| SessionStart | Startup | `load-ticket-context.sh` | Load ticket context, detect focus areas |
| UserPromptSubmit | User prompt | `user-prompt-submit.sh` | Pause scheduled Phase 6 watchers during manual user work |
| PreToolUse | Before Bash/Edit/Write | `guard-handler.py` | Block/warn on dangerous patterns |
| PostToolUse | After `git commit` | `post-commit-guard.sh` | Validate commit format via guards |
| Stop | Claude tries to stop | `phase-loop.sh`, `stop-sound.sh` | Phase audit loop plus best-effort macOS sound notification |
| PreCompact | Before compaction | `pre-compact.sh` | Preserve Doyaken context across compaction |
| SessionEnd | Session ends | `session-end.sh` | Record session end metadata |

## Phase Audit Loops

When `DOYAKEN_LOOP_ACTIVE=1`, the Stop hook intercepts Claude's exit, injects a phase-specific audit prompt, and loops until a `.complete` signal file is written or max iterations (default 30) are reached.

Phases: Plan → Implement → Review → Verify & Commit → PR → Complete

## Session IDs

Derived from a stable repo key plus worktree names (`worktree-<name>`) or branch names (fallback). Used to key all state files. Path-based derivation keeps worktree sessions stable across branch renames while the repo key prevents cross-repo collisions in the global state directories.

## Worktree Isolation

Each ticket gets its own git worktree in `.doyaken/worktrees/`. The `dk` shell function manages creation, cleanup, and resumption.

Symlinked directories (configured in `settings.json`): `node_modules`, `.venv`, `vendor`, `target`, `.next`, `.nuxt`.

## Guard Handler

`guard-handler.py` is Python 3 (stdlib only). It:
- Parses YAML frontmatter from guard `.md` files (regex-based, flat key-value only)
- Evaluates Python regexes against tool input
- Exit code 0 = pass/warn, exit code 2 = block
- Pass subprocess arguments as lists, never `shell=True` with user input

## Security

- Hooks run with the user's full permissions — treat all hook code as security-sensitive
- Exit code 2 means "block" in guards — other non-zero exits are errors, not blocks
- Never store secrets in state files or `settings.json`
- Session IDs are not cryptographically random
- Keep guard patterns efficient — they run on every tool invocation
