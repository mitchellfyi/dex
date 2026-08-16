#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-completion-receipt-test.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
export DX_TOOL_DIR="$TMP_DIR/tools"
export DX_RUN_ROOT="$TMP_DIR/runs"
export PATH="$TMP_DIR/bin:$PATH"
export TEST_REPO="$TMP_DIR/repo"
export TEST_TMP_DIR="$TMP_DIR"
mkdir -p "$HOME" "$TMP_DIR/bin" "$TEST_REPO"

printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP_DIR/bin/claude"
chmod +x "$TMP_DIR/bin/claude"

git -C "$TEST_REPO" init -q
git -C "$TEST_REPO" config user.email dex@example.test
git -C "$TEST_REPO" config user.name "Dex Test"
printf '# repo\n' > "$TEST_REPO/README.md"
git -C "$TEST_REPO" add README.md
git -C "$TEST_REPO" commit -q -m init
export TEST_DEFAULT_BRANCH
TEST_DEFAULT_BRANCH=$(git -C "$TEST_REPO" branch --show-current)

zsh -fc '
source "$DEX_DIR/dx.sh"
set -e

export DX_PROVIDER_ENGINE=codex-plugin
session_id="inline-missing-receipt"
state_file="$(dx_state_file "$session_id")"
times_file="$(dx_times_file "$session_id")"

__dx_claude() { return 0; }

if __dx_run_phases_inline "repo" "$TEST_REPO" "$TEST_DEFAULT_BRANCH" 0 "$state_file" "$times_file" "dx test" "in-place" "$session_id" "test" > "$TEST_TMP_DIR/inline-receipt.out" 2>&1; then
  printf "%s\n" "inline lifecycle accepted a provider exit without completion" >&2
  exit 1
fi

grep -q "Claude session exited at Phase 0" "$TEST_TMP_DIR/inline-receipt.out"
[[ ! -f "$(dx_active_file "$session_id")" ]]
run_id="$(dx_run_read_for_session "$session_id")"
python3 - "$(dx_run_summary_file "$run_id")" <<"PY"
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    assert json.load(handle)["status"] == "blocked"
PY
'

zsh -fc '
source "$DEX_DIR/dx.sh"
cd "$TEST_REPO"

__dx_refresh_provider() {
  export DX_PROVIDER_ENGINE=claude
  DX_CLAUDE_FLAGS=()
  DX_PLAN_FLAGS=()
}
__dx_claude() { return 0; }

if dxloop "test missing receipt" > "$TEST_TMP_DIR/dxloop-receipt.out" 2>&1; then
  printf "%s\n" "dxloop accepted a provider exit without completion" >&2
  exit 1
fi
grep -q "provider exited without a completion receipt" "$TEST_TMP_DIR/dxloop-receipt.out"
'

printf '#!/usr/bin/env bash\nprintf "17\\n"\n' > "$TMP_DIR/bin/gh"
chmod +x "$TMP_DIR/bin/gh"

zsh -fc '
source "$DEX_DIR/dx.sh"
cd "$TEST_REPO"

__dx_refresh_provider() {
  export DX_PROVIDER_ENGINE=claude
  DX_CLAUDE_FLAGS=()
  DX_PLAN_FLAGS=()
}
__dx_claude() { return 0; }

if dxcomplete > "$TEST_TMP_DIR/dxcomplete-receipt.out" 2>&1; then
  printf "%s\n" "dxcomplete accepted a provider exit without completion" >&2
  exit 1
fi
grep -q "provider exited without a completion receipt" "$TEST_TMP_DIR/dxcomplete-receipt.out"
'

printf 'completion receipt tests passed\n'
