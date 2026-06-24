# Guards

Dex uses markdown-based guard rules to block or warn about dangerous patterns before they happen. Guards are evaluated by `hooks/guard-handler.py` on PreToolUse (before Bash/Edit/Write). Post-commit validation (after git commit) is handled by `hooks/post-commit-guard.sh`, which checks conventional commit format and then delegates to `guard-handler.py` for markdown-based guard evaluation of committed files.

These are Claude Code hooks — see [Claude Code hooks documentation](https://docs.anthropic.com/en/docs/claude-code/hooks) for how hooks integrate with the tool lifecycle.

## How It Works

1. Claude invokes a tool (Bash, Edit, Write)
2. Claude Code passes hook payload JSON to `guard-handler.py` on stdin
3. The handler loads all enabled guard `.md` files
4. Each guard's regex pattern is checked against the input
5. Matching guards trigger a **warn** (message is returned as hook context, tool proceeds) or **block** (tool prevented, exit code 2)

## Guard File Format

Guards are markdown files with YAML frontmatter, stored in:
- `hooks/guards/*.md` — built-in guards (ship with Dex)
- `.dex/guards/*.md` — project-specific guards (per-repo)

```markdown
---
name: guard-name
enabled: true
event: bash|file|commit|all
pattern: regex-pattern
detector: optional-built-in-detector
action: warn|block
---

Message shown when the guard triggers.
Supports **markdown** formatting.
```

### Fields

| Field | Required | Values | Description |
|-------|----------|--------|-------------|
| `name` | yes | string | Unique identifier for the guard |
| `enabled` | yes | true/false/yes/no | Toggle without deleting the file |
| `event` | yes | bash, file, commit, all | When to evaluate this guard |
| `pattern` | yes unless `detector` is set | Python regex | Pattern to match against tool input |
| `detector` | no | built-in detector id | Use a built-in parser instead of a regex for syntax-sensitive checks |
| `action` | yes | warn, block | Warn returns hook context; block prevents the action |
| `case_sensitive` | no | true/false/yes/no | If true, pattern matching is case-sensitive (default: false) |
| `allow_pattern` | no | Python regex | If this pattern matches, suppress this guard even when `pattern` matches |
| `env_var` | no | string | Only evaluate this guard when the named environment variable is set |
| `env_value` | no | string | With `env_var`, require this exact environment variable value |

When using `env_value` values that look like booleans (`true`, `false`, `yes`, `no`), quote them so the simple frontmatter parser keeps them as strings.

For `env_var: DX_PROVIDER_ENGINE`, `guard-handler.py` treats the current Dex session provider state as authoritative when `DEX_SESSION_ID` is present, then falls back to the hook environment and provider config defaults. Without an explicit session id, a hook-provided `DX_PROVIDER_ENGINE` value wins over any launch-scoped fallback state so stale state files cannot silently expand provider-scoped guards.

### Event Types

| Event | Triggers On | Input Checked |
|-------|------------|---------------|
| `bash` | PreToolUse for Bash commands | The command string |
| `file` | PreToolUse for Edit/Write/MultiEdit | The file content being written |
| `commit` | PostToolUse after `git commit` | Committed file paths + commit message |
| `all` | All of the above | Varies by context |

## Built-in Guards

| Guard | Event | Action | What It Catches |
|-------|-------|--------|----------------|
| `block-destructive-commands` | bash | block | `rm -rf /`, `rm -rf /*`, `rm -rf ~`, `rm -rf ~/.`, `rm -rf ~/*`, `rm -rf ~+`, `rm -rf ~+/*`, `rm -rf $HOME`, `rm -rf $HOME/.`, `rm -rf $HOME/*`, `rm -rf $PWD`, `rm -rf $PWD/.`, `rm -rf $PWD/*`, `rm -rf .`, `rm -rf ./`, `rm -rf ./.`, `rm -rf *`, `rm -rf ./*`, including parameter-expanded equivalents, split/reordered flags, common wrappers, and shell-nested `bash -c`/`eval` payloads (but NOT `rm -rf /tmp` or `rm -rf ./build`), `dd if=`, `mkfs`, `format` |
| `block-claude-attribution` | bash | block | PR and commit commands containing Claude generated-by/co-author attribution; use Dex attribution instead |
| `block-raw-codex-delegation` | bash | block | Raw Codex agent-work commands while the resolved provider engine is `codex-plugin`, including `codex`, `codex exec`, `codex e`, `codex review`, direct `dx_provider_codex` helper delegation, API-key login forms, shell-nested forms including literal variable-expanded and escape-decoded `bash -c`/`eval`/stdin payloads, generated heredoc scripts, direct executable script paths, readable executed or sourced script files, Python/Node/Ruby/Perl interpreter payloads that launch Codex, launch wrappers such as `nice`, `timeout`, `xargs`, and `find -exec`, and fail-closed shell execution from unresolved/unreadable script paths or unknown stdin/process-substitution producers; also blocks versioned/scoped package-runner forms such as `npx @openai/codex@latest` and runner shell payloads such as `npx -c "codex exec ..."` and `npm exec --call "codex exec ..."`; use `bin/dxcodex.sh` instead |
| `warn-sensitive-files` | commit | warn | `.env`, credentials, keys, certs in commits |
| `warn-hardcoded-secrets` | file | warn | `API_KEY = "..."`, `ACCESS_KEY`, `JWT_SECRET`, and other credential patterns in code |
| `warn-await-in-loop` | file | warn | `await` directly inside a `for`/`while` loop body (N+1 query / sequential I/O). Uses the `await-in-loop` detector: brace-aware, skips `for await` async iteration and awaits inside closures collected for a later `Promise.all` |

### Built-in detectors

Some guards set `detector:` instead of `pattern:` to use a parser in `hooks/guard-handler.py` (registered in `guard_detector_matches`) for checks regex can't express reliably:

| Detector | Used by | What it parses |
|----------|---------|----------------|
| `destructive-commands` | `block-destructive-commands` | Shell tokenization of `rm -rf` / `dd` / `mkfs` targets, incl. wrappers and nested payloads |
| `raw-codex-delegation` | `block-raw-codex-delegation` | Shell/script delegation to the Codex CLI under the `codex-plugin` provider |
| `await-in-loop` | `warn-await-in-loop` | Brace-matched `for`/`while` bodies, flagging an `await` that isn't inside a nested closure |

Note: Conventional commit format validation is handled by `hooks/post-commit-guard.sh` directly (not via guards) because commit events combine file paths and the message into a single text, making it impossible to write a guard pattern that targets only the commit message.

Project-specific guards (e.g., framework-specific endpoint checks, worktree config protection) are generated during `dx init` in `.dex/guards/` within the repo.

## Adding Project-Specific Guards

Create a `.md` file in `.dex/guards/`:

```bash
# Example: block force-push in this repo
cat > .dex/guards/no-force-push.md << 'EOF'
---
name: no-force-push
enabled: true
event: bash
pattern: git\s+push\s+.*--force
action: block
---

BLOCKED: Force-push is not allowed in this repository.

Use `git push --force-with-lease` instead for safer force-pushing.
EOF
```

Guards in `.dex/guards/` are repo-specific and take effect immediately — no restart needed.

## Disabling a Guard

Edit the guard file and set `enabled: false`:

```yaml
---
name: guard-name
enabled: false
...
---
```

## Pattern Syntax

Guards use Python regex (`re.MULTILINE`). Matching is case-insensitive by default; add `case_sensitive: true` to the frontmatter for exact-case matching:

| Pattern | Matches |
|---------|---------|
| `rm\s+-[a-z]*rf[a-z]*\s+/\s` | `rm -rf / ` (slash then space — anchors to path boundary, won't match `rm -rf /tmp`) |
| `\.env$` | Files ending in `.env` |
| `console\.log\(` | `console.log(...)` |
| `(eval|exec)\(` | `eval(...)` or `exec(...)` |
| `API_KEY\s*[=:]\s*['"]` | `API_KEY = "..."` or `API_KEY: '...'` |

## Testing Guards

```bash
# Test a bash guard
printf '%s\n' '{"tool_input":{"command":"rm -rf /"}}' \
  | DEX_GUARD_EVENT=bash python3 hooks/guard-handler.py
echo "Exit: $?"

# Test a file guard
printf '%s\n' '{"tool_input":{"file_path":"app.py","content":"API_KEY = \"secret123\""}}' \
  | DEX_GUARD_EVENT=file python3 hooks/guard-handler.py
echo "Exit: $?"

# Test a commit guard
DEX_GUARD_EVENT=commit CLAUDE_TOOL_USE_INPUT=$'config.toml\nfeat: add api' python3 hooks/guard-handler.py
echo "Exit: $?"
```

`CLAUDE_TOOL_USE_INPUT` is also supported as a plain-text fallback for manual tests and post-commit integration.

Exit code 0 = no block, exit code 2 = blocked.
