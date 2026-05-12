# Shell Conventions

## Language Boundaries — Critical

| Location | Language | Notes |
|----------|----------|-------|
| `dk.sh` | **zsh only** | Uses `${(j: :)@}`, zsh arrays, `unalias/unfunction` guards |
| `hooks/*.sh` | **bash** | `#!/usr/bin/env bash` shebang |
| `bin/*.sh` | **bash** | `#!/usr/bin/env bash` shebang |
| `lib/*.sh` | **bash/zsh-compatible** | Sourced by both dk.sh and hooks/bin scripts |

Never introduce zsh-only syntax in `lib/` or `hooks/`. Only `dk.sh` may use zsh features.

## Error Handling

All scripts use `set -euo pipefail`. Use early returns, not deep nesting.

## Naming

- **Functions:** `dk_` prefix (public), `__dk_` prefix (internal), snake_case
- **Variables:** `local` for locals, `SCREAMING_SNAKE_CASE` with `DOYAKEN_` or `DK_` prefix for exported env vars
- **Files:** kebab-case for scripts and directories

## Library Sourcing

```bash
source "$DOYAKEN_DIR/lib/common.sh"
```

Sourcing `common.sh` automatically sources `git.sh`, `session.sh`, `output.sh`, `worktree.sh`, `provider.sh`, `codex.sh`, and `ui-capture.sh`.

## Output

Use `lib/output.sh` helpers (`dk_done`, `dk_ok`, `dk_warn`, `dk_skip`, `dk_info`, `dk_error`) for user-facing messages. Never raw `echo` for status output.

## Re-sourcing Safety

In `dk.sh`, every function definition is preceded by:
```zsh
unalias <name> 2>/dev/null; unfunction <name> 2>/dev/null
```

## Atomic File Operations

When writing shared files (e.g., `~/.claude/settings.json`), use temp files + atomic `mv`.

## State Files

All ephemeral state goes under `~/.claude/.doyaken-phases/` or `~/.claude/.doyaken-loops/`, keyed by session ID. Never store state inside the repo (except `.doyaken/worktrees/` which is gitignored).

## Modularizing dk.sh

Extract to `lib/` when:
- Same logic appears in 2+ functions
- A function exceeds ~50 lines of self-contained logic
- Logic is needed by both zsh (`dk.sh`) and bash (`hooks/`, `bin/`)

Keep in `dk.sh`: functions using zsh-specific syntax, `unalias/unfunction` guards, and public commands (`dk`, `dkloop`, `dkrm`, `dkls`, `dkclean`, `doyaken`).
