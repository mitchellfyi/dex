# Architecture Patterns

## Hook Integration

Hooks defined in `settings.json`, referenced by paths to Dex scripts:

| Hook | Event | Script | Purpose |
|------|-------|--------|---------|
| SessionStart | Startup | `capture-provider-session.sh`, `load-ticket-context.sh` | Save the provider conversation ID; load ticket context and focus areas |
| UserPromptSubmit | User prompt | `user-prompt-submit.sh` | Pause scheduled Phase 6 watchers during manual user work |
| PreToolUse | Before Bash/Edit/Write | `guard-handler.py` | Warn on risky patterns; the agent decides |
| PreToolUse | Before Bash | `rtk-claude-hook.sh` | Fail-open RTK command rewrite; runs *after* `guard-handler.py` |
| PostToolUse | After `git commit` | `post-commit-guard.sh` | Validate commit format via guards |
| Stop | Claude tries to stop | `phase-loop.sh`, `stop-sound.sh` | Phase audit loop plus best-effort macOS sound notification |
| PreCompact | Before compaction | `pre-compact.sh` | Preserve Dex context across compaction |
| SessionEnd | Session ends | `session-end.sh` | Record session end metadata |

PreToolUse/Bash hooks run in registration order: `guard-handler.py` first
(it can deny with exit 2, though no built-in guard does), then `rtk-claude-hook.sh` (fail-open —
always exits 0). Security guards must precede any rewrite/enhancement hook so a
rewrite can never bypass a guard.

## Phase Audit Loops

When `DEX_LOOP_ACTIVE=1`, the Stop hook intercepts Claude's exit and injects a
phase-specific audit prompt. Normal gate advancement requires the exact
generation-bound completion receipt authorized for that session and phase. A
bare `.complete` marker does not authorize advancement. Direct human jumps and
waivers are recorded separately from passed gates. The loop pauses for
intervention after its configured audit limit, which defaults to 30.

The Phase 3 review loop has a separate soft outer-wave budget: 3 waves for
`small`, 6 for `normal`, and 9 for `complex`. An attributed
`review.max-waves` override may change that operational budget without changing
the clean-pass assurance requirement. Spending the budget pauses review and
preserves valid clean credit.

Phases: Plan → Implement → Review → Verify → PR → Complete

## Session IDs

Derived from a stable repo key plus worktree names (`worktree-<name>`) or branch names (fallback). Used to key all state files. Path-based derivation keeps worktree sessions stable across branch renames while the repo key prevents cross-repo collisions in the global state directories.

## Worktree Isolation

Each ticket gets its own git worktree in `.dex/worktrees/`. The `dx` shell function manages creation, cleanup, and resumption.

Symlinked directories (configured in `settings.json`): `node_modules`, `.venv`, `vendor`, `target`, `.next`, `.nuxt`.

## Guard Handler

`guard-handler.py` is Python 3 (stdlib only). It:
- Parses YAML frontmatter from guard `.md` files (regex-based, flat key-value only)
- Evaluates Python regexes against tool input
- Exit code 0 = pass or warn, exit code 2 = block; every built-in guard warns
- Pass subprocess arguments as lists, never `shell=True` with user input

Reading the shell command itself — wrappers, nested shells, aliases,
interpreter payloads, heredocs, xargs, `find -exec`, substitutions — is
`hooks/shell_parse.py`, shared with `hooks/git-commit-target.py`. Add a
capability there, not in one hook: `tests/parser-drift-test.sh` fails on a hook
that redefines a shared name, which is how the two copies drifted apart before.

## Security

- Hooks run with the user's full permissions — treat all hook code as security-sensitive
- Exit code 2 means "block" in guards — other non-zero exits are errors, not blocks. Built-in guards advise instead, so the agent reads the message and chooses
- Never store secrets in state files or `settings.json`
- Session IDs are not cryptographically random
- Keep guard patterns efficient — they run on every tool invocation
