# RTK Token Reduction Integration

Dex now bootstraps [RTK](https://github.com/rtk-ai/rtk) as part of `dx install`,
`dx init`, `dx sync`, and `dx tools bootstrap`.

## Research Summary

RTK is a single Rust CLI that wraps common development commands and filters
their output before it reaches an agent context. Its upstream docs describe
60-90% token savings for common operations, prebuilt binaries for macOS/Linux,
and an agent hook model that rewrites Bash commands such as `git status` into
`rtk git status`.

The upstream Codex integration is instruction-based rather than hook-based:
Codex is told to prefix shell commands with `rtk`. Claude Code supports a
PreToolUse hook with `updatedInput`, so Dex can use RTK's own `rtk hook claude`
entrypoint there without adding a large RTK instruction block to every project.

## What Dex Installs

- A verified RTK binary, preferring an existing valid `rtk` on `PATH`.
- A Dex-managed fallback binary in `~/.claude/.dex-tools/rtk/bin/rtk`.
- A fail-open Claude Code hook at `hooks/rtk-claude-hook.sh`.
- A Codex global `RTK.md` plus an absolute import in `$CODEX_HOME/AGENTS.md`.

Dex verifies the downloaded archive against the release's `checksums.txt`
before extraction, then checks the installed binary with
`rtk rewrite "git status"`. Missing, duplicate, malformed, or mismatched
checksum entries stop the install. The behavior check also avoids the known
package-name collision with the unrelated Rust Type Kit binary without
depending on RTK's own hook-install diagnostics. Before extraction, Dex also
rejects path traversal, links, special files, excessive entry counts, and
oversized expanded contents.

## Runtime Behavior

Claude Code Bash tool calls now run through Dex guards first. If a guard allows
the command, the RTK hook gets the same payload and may return an `updatedInput`
command. When `python3` is available, the wrapper prefixes rewritten commands
with RTK's install directory in `PATH`, so the generated `rtk ...` command
still works when the agent shell did not load `~/.local/bin`; without
`python3` the rewrite is passed through unprefixed. If RTK is unavailable or
fails, the wrapper exits successfully and leaves the original command
untouched.

Codex does not currently expose the same transparent Bash rewrite path through
Dex, so Codex receives compact global instructions. Those instructions prefer
RTK for commands where summarized output is enough and keep raw commands
available when exact output matters.

RTK's `gain` command may still warn that `rtk init -g` has not installed a hook,
because upstream RTK only recognizes a literal `rtk hook claude` settings entry.
Dex's hook is a wrapper around that same entrypoint so it can locate a
Dex-managed binary and fail open when RTK is unavailable. `dx status` reports
whether the RTK binary resolves; `dx tools doctor` also checks the Dex-managed
RTK hook wiring.

## Configuration

| Variable | Purpose |
|----------|---------|
| `DX_RTK_ENABLED=0` | Skip RTK install, checks, and hooks. |
| `DX_RTK_BIN=/path/to/rtk` | Force Dex to use a specific RTK binary. |
| `DX_RTK_INSTALL_DIR=/path` | Override Dex's RTK install directory. |
| `DX_RTK_VERSION=vX.Y.Z` | Pin the RTK release downloaded from GitHub. |
| `DX_RTK_HTTP_TIMEOUT_SECONDS=N` | Seconds one download may take. Defaults to 20 for release metadata and 180 for the binary; a single value here applies to both. |

## Manual Verification

This change was tested with an isolated temporary home directory and with the
real Dex tooling bootstrap.

- Isolated bootstrap installed RTK v0.42.0, created `.claude/settings.json`,
  wrote Codex `RTK.md`/`AGENTS.md`, and verified `rtk rewrite "git status"`.
- The Claude hook rewrote a Bash payload for `git status` into an RTK command
  and the rewritten command ran with `PATH=/usr/bin:/bin`.
- The fail-open path returned exit 0 with no output when RTK was unavailable.
- Real `dx tools bootstrap` installed RTK in `~/.claude/.dex-tools/rtk/bin/rtk`,
  linked `~/.local/bin/rtk`, refreshed Claude settings, and wrote Codex RTK
  instructions.
- `dx tools doctor`, `dx status`, `shellcheck`, `bash -n`, `zsh -n dx.sh`,
  `jq . settings.json`, and `git diff --check` passed.

## Sources

- RTK README: https://github.com/rtk-ai/rtk/blob/master/README.md
- RTK install guide: https://github.com/rtk-ai/rtk/blob/master/INSTALL.md
- RTK Codex awareness file: https://github.com/rtk-ai/rtk/blob/master/hooks/codex/rtk-awareness.md
- RTK Claude hook implementation: https://github.com/rtk-ai/rtk/blob/master/src/hooks/hook_cmd.rs
