# Shell Conventions

## Language Boundaries — Critical

| Location | Language | Notes |
|----------|----------|-------|
| `dx.sh` | **zsh only** | Uses `${(j: :)@}`, zsh arrays, `unalias/unfunction` guards |
| `hooks/*.sh` | **bash** | `#!/usr/bin/env bash` shebang |
| `bin/*.sh` | **bash** | `#!/usr/bin/env bash` shebang |
| `lib/*.sh` | **bash/zsh-compatible** | Sourced by both dx.sh and hooks/bin scripts |

Never introduce zsh-only syntax in `lib/` or `hooks/`. Only `dx.sh` may use zsh features.

## Error Handling

All scripts use `set -euo pipefail`. Use early returns, not deep nesting.

## Naming

- **Functions:** `dx_` prefix (public), `__dx_` prefix (internal), snake_case
- **Variables:** `local` for locals, `SCREAMING_SNAKE_CASE` with `DEX_` or `DX_` prefix for exported env vars
- **Files:** kebab-case for scripts and directories

## Library Sourcing

```bash
source "$DEX_DIR/lib/common.sh"
```

Sourcing `common.sh` automatically sources `git.sh`, `session.sh`, `output.sh`, `worktree.sh`, `provider.sh`, `codex.sh`, `ui-capture.sh`, `rtk.sh`, `events.sh`, `factory.sh`, `run-spec.sh`, `agent-tools.sh`, and `maintenance.sh`.

## Output

Use `lib/output.sh` helpers (`dx_done`, `dx_ok`, `dx_warn`, `dx_skip`, `dx_info`, `dx_error`) for user-facing messages. Never raw `echo` for status output.

## Re-sourcing Safety

In `dx.sh`, every function definition is preceded by:
```zsh
unalias <name> 2>/dev/null; unfunction <name> 2>/dev/null
```

## Atomic File Operations

When writing shared files (e.g., `~/.claude/settings.json`), use temp files + atomic `mv`.

## State Files

All ephemeral state goes under `~/.claude/.dex-phases/` or `~/.claude/.dex-loops/`, keyed by session ID. Never store state inside the repo (except `.dex/worktrees/` which is gitignored).

## Modularizing dx.sh

Extract to `lib/` when:
- Same logic appears in 2+ functions
- A function exceeds ~50 lines of self-contained logic
- Logic is needed by both zsh (`dx.sh`) and bash (`hooks/`, `bin/`)

Keep in `dx.sh`: functions using zsh-specific syntax, `unalias/unfunction` guards, and public commands (`dx`, `dxloop`, `dxrm`, `dxls`, `dxclean`, `dex`, `dexter`).
