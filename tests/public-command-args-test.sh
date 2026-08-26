#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-public-command-args.XXXXXX")"

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
export TEST_REPO="$TMP_DIR/repo"
mkdir -p "$HOME" "$TEST_REPO"
git -C "$TEST_REPO" init -q

zsh -fc '
  source "$DEX_DIR/dx.sh"
  set -e
  cd "$TEST_REPO"

  __dx_refresh_provider() {
    print -u2 -- "provider resolution ran during argument validation"
    return 97
  }

  for command_name in dxloop dxrefine dxcomplete dxreviewloop dxrm dxls dxcd dxclean; do
    "$command_name" --help > "$TEST_REPO/$command_name-help.out"
    grep -Fq "Usage:" "$TEST_REPO/$command_name-help.out"
  done

  dx reload --help > "$TEST_REPO/reload-help.out"
  grep -Fq "Usage: dx reload" "$TEST_REPO/reload-help.out"
  if grep -Fq "Reloaded Dex shell functions" "$TEST_REPO/reload-help.out"; then
    print -u2 -- "dx reload --help reloaded the shell"
    exit 1
  fi
  if dx reload unexpected > /dev/null 2> "$TEST_REPO/reload-invalid.out"; then
    print -u2 -- "dx reload accepted an unexpected argument"
    exit 1
  fi
  grep -Fq "does not accept arguments" "$TEST_REPO/reload-invalid.out"

  mkdir -p "$HOME/.claude"
  print -r -- "{}" > "$HOME/.claude/settings.json"
  dx reload > "$TEST_REPO/reload.out"
  dx_claude_settings_complete
  grep -Fq "Reloaded Dex shell functions and refreshed Claude hook settings" \
    "$TEST_REPO/reload.out"

  invalid_cases=(
    "dxcomplete unexpected"
    "dxreviewloop unexpected"
    "dxls unexpected"
    "dxcd first second"
    "dxclean unexpected"
  )
  for invalid_case in "${invalid_cases[@]}"; do
    words=("${(z)invalid_case}")
    if "${words[@]}" > /dev/null 2> "$TEST_REPO/invalid.out"; then
      print -u2 -- "public command accepted invalid arguments: $invalid_case"
      exit 1
    fi
    if grep -Fq "provider resolution ran" "$TEST_REPO/invalid.out"; then
      print -u2 -- "provider resolution ran before rejecting: $invalid_case"
      exit 1
    fi
  done

  dx help > "$TEST_REPO/dx-help.out"
'

python3 - "$HOME/.claude/settings.json" <<'PY'
import json
import sys

settings = json.load(open(sys.argv[1], encoding="utf-8"))
entries = settings["hooks"]["UserPromptSubmit"]
timeouts = [
    hook.get("timeout")
    for entry in entries
    for hook in entry.get("hooks", [])
    if "hooks/user-prompt-submit.sh" in hook.get("command", "")
]
if timeouts != [120]:
    raise SystemExit(f"unexpected Dex UserPromptSubmit timeouts: {timeouts!r}")
PY

# `dx help` is the only listing most people read, and it had quietly fallen
# behind the dispatcher: `dx worker` and `dx dexcode` were both reachable and
# documented elsewhere while being absent from it. Compare the two directly.
python3 - "$ROOT" "$TEST_REPO/dx-help.out" <<'PY'
import re
import sys
from pathlib import Path

root, help_path = Path(sys.argv[1]), Path(sys.argv[2])
source = (root / "dx.sh").read_text(encoding="utf-8")
body = re.search(r"^__dx_cli\(\) \{$(.*?)^\}$", source, re.S | re.M).group(1)

# Case labels at the dispatcher's own indent level, minus the help aliases it
# cannot list as commands and `revert`/`log`, which the worktree section covers.
listed_elsewhere = {"help", "--help", "-h", "revert", "log"}
commands = set()
for match in re.finditer(r"^ {4}([a-z|_-]+)\)", body, re.M):
    commands.update(match.group(1).split("|"))
commands -= listed_elsewhere

help_text = help_path.read_text(encoding="utf-8")
missing = sorted(c for c in commands if not re.search(rf"^\s+dx {re.escape(c)}\b", help_text, re.M))
if missing:
    print("dx help does not list: " + ", ".join(missing), file=sys.stderr)
    raise SystemExit(1)
print(f"dx help lists all {len(commands)} dispatcher commands")
PY

printf 'public command argument tests passed\n'
