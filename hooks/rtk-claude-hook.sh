#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2016,SC2034
# Fail-open Claude Code hook that delegates Bash command rewrites to RTK.
set -euo pipefail

# This runs on every Bash tool call, so load only the modules it reads
# (the status line uses the same fast path). A broken or partial install
# must not surface here: this hook enhances output, it never gates it.
DX_COMMON_MODULES="output rtk"
dex_common="${DEX_DIR:-$HOME/work/dex}/lib/common.sh"
# A missing source target is fatal in bash even inside a guard, so probe it.
if [[ ! -r "$dex_common" ]]; then
  exit 0
fi
if ! source "$dex_common" 2>/dev/null; then
  exit 0
fi
unset DX_COMMON_MODULES

if ! dx_rtk_enabled; then
  exit 0
fi

if ! rtk_binary=$(dx_rtk_resolved_binary 2>/dev/null); then
  exit 0
fi

payload=$(cat)
if [[ -z "$payload" ]]; then
  exit 0
fi

if ! hook_output=$(printf '%s' "$payload" | "$rtk_binary" hook claude 2>/dev/null); then
  exit 0
fi

if [[ -z "$hook_output" ]]; then
  exit 0
fi

if command -v python3 >/dev/null 2>&1; then
  if transformed=$(printf '%s' "$hook_output" | python3 -c '
import json
import shlex
import sys

rtk_dir = sys.argv[1]
data = json.load(sys.stdin)
updated = data.get("hookSpecificOutput", {}).get("updatedInput", {})
cmd = updated.get("command")
if isinstance(cmd, str) and "rtk " in f"{cmd} ":
    updated["command"] = f"PATH={shlex.quote(rtk_dir)}:\"$PATH\" {cmd}"
print(json.dumps(data, separators=(",", ":")))
' "$(dirname "$rtk_binary")" 2>/dev/null); then
    printf '%s\n' "$transformed"
    exit 0
  fi
fi

printf '%s\n' "$hook_output"
