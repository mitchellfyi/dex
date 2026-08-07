#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-headless-provider-test.XXXXXX")"
REAL_BASH=$(command -v bash)

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export CODEX_HOME="$HOME/.codex"
export DEX_DIR="$ROOT"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_RTK_ENABLED=0
export DX_RUN_ROOT="$TMP_DIR/runs"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_TOOL_DIR="$TMP_DIR/tools"
export DX_PROVIDER_PROFILE=codex-subscription
export DEXCODE_SYNC=0
export TEST_CODEX_LOG="$TMP_DIR/codex.log"
export TEST_INIT_LOG="$TMP_DIR/init.log"
export REAL_BASH
mkdir -p "$HOME" "$TMP_DIR/bin"

cat > "$TMP_DIR/bin/bash" <<'SH'
#!/bin/sh
if [ "${1:-}" = "$DEX_DIR/bin/init.sh" ]; then
  printf '%s\n' "$PWD" >> "$TEST_INIT_LOG"
  mkdir -p "$PWD/.dex/rules"
  printf '%s\n' '# Dex' '## Tech Stack' 'Shell' '## Quality Gates' 'Tests' '## Project Structure' 'Repository' > "$PWD/.dex/dex.md"
  printf '%s\n' '# Rule' > "$PWD/.dex/rules/base.md"
  exit 0
fi
exec "$REAL_BASH" "$@"
SH
chmod +x "$TMP_DIR/bin/bash"

cat > "$TMP_DIR/bin/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_CODEX_LOG"
if [[ "${1:-}" == "login" && "${2:-}" == "status" ]]; then
  printf '%s\n' "Logged in with ChatGPT"
  exit 0
fi
if [[ "${1:-}" == "exec" && "${2:-}" == "--help" ]]; then
  printf '%s\n' "--ignore-user-config" "--dangerously-bypass-approvals-and-sandbox"
  exit 0
fi
if [[ "${1:-}" == "exec" && "${2:-}" == "review" && "${3:-}" == "--help" ]]; then
  printf '%s\n' "--ignore-user-config" "--dangerously-bypass-approvals-and-sandbox"
  exit 0
fi
if [[ "${1:-}" == "exec" ]]; then
  exit 0
fi
exit 0
SH
chmod +x "$TMP_DIR/bin/codex"

# Keep real language/package installations out of the tooling bootstrap so the
# regression cannot install anything or contact a package registry.
python_path=$(command -v python3)
ln -s "$python_path" "$TMP_DIR/bin/python3"
export PATH="$TMP_DIR/bin:/usr/bin:/bin:/usr/sbin:/sbin"

make_repo() {
  local repo="$1" with_dex="$2"
  git init -q "$repo"
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name Test
  printf '%s\n' '# Repo' > "$repo/README.md"
  if [[ "$with_dex" == "1" ]]; then
    mkdir -p "$repo/.dex/rules" "$repo/.dex/memory"
    printf '%s\n' '# Dex' '## Tech Stack' 'Shell' '## Quality Gates' 'Tests' '## Project Structure' 'Repository' > "$repo/.dex/dex.md"
    printf '%s\n' '# Rule' > "$repo/.dex/rules/base.md"
    printf '%s\n' '# Memory' > "$repo/.dex/memory/index.md"
  fi
  git -C "$repo" add .
  git -C "$repo" commit -qm init
}

SYNC_REPO="$TMP_DIR/sync-repo"
make_repo "$SYNC_REPO" 1
(
  cd "$SYNC_REPO"
  "$REAL_BASH" "$ROOT/bin/sync.sh" --dry-run --no-pr --budget-minutes 1
) > "$TMP_DIR/sync.out" 2>&1
grep -Fq 'Sync complete for: sync-repo' "$TMP_DIR/sync.out"
if grep -Fq '[error] Claude Code CLI not found' "$TMP_DIR/sync.out"; then
  printf 'Codex-backed sync still required Claude\n' >&2
  exit 1
fi

MAINTAIN_REPO="$TMP_DIR/maintain-repo"
make_repo "$MAINTAIN_REPO" 1
(
  cd "$MAINTAIN_REPO"
  "$REAL_BASH" "$ROOT/bin/maintain.sh" --mode report --no-sync --budget-minutes 1
) > "$TMP_DIR/maintain.out" 2>&1
grep -Fq 'Maintain run complete for: maintain-repo' "$TMP_DIR/maintain.out"
if grep -Fq '[error] Claude Code CLI not found' "$TMP_DIR/maintain.out"; then
  printf 'Codex-backed maintenance still required Claude\n' >&2
  exit 1
fi

MISSING_REPO="$TMP_DIR/missing-repo"
make_repo "$MISSING_REPO" 0
(
  cd "$MISSING_REPO"
  "$REAL_BASH" "$ROOT/bin/sync.sh" --no-pr --budget-minutes 1
) > "$TMP_DIR/missing.out" 2>&1
if ! grep -Eq '/missing-repo$' "$TEST_INIT_LOG"; then
  printf 'sync did not run baseline init for a repository without .dex\n' >&2
  cat "$TMP_DIR/missing.out" >&2
  [[ -f "$TEST_INIT_LOG" ]] && cat "$TEST_INIT_LOG" >&2
  exit 1
fi
grep -Fq 'No .dex/ directory found; running baseline project analysis first' "$TMP_DIR/missing.out"

grep -Fq 'exec --ignore-user-config --dangerously-bypass-approvals-and-sandbox' "$TEST_CODEX_LOG"

printf 'headless provider tests passed\n'
