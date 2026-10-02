#!/usr/bin/env bash

# This file is the complete observer surface installed in the agent-facing
# runtime. It captures only the checkout and fields already emitted by Dex.

review_eval_agent_snapshot_checkout() {
  local workspace="$1" snapshot="$2"
  [[ -d "$workspace/.git" && ! -e "$snapshot" ]] || return 1
  REVIEW_EVAL_AGENT_WORKSPACE="$workspace" \
  REVIEW_EVAL_AGENT_SNAPSHOT="$snapshot" \
    python3 - <<'PY'
import os
import shutil
import stat
import subprocess
from pathlib import Path, PurePosixPath

workspace = Path(os.environ["REVIEW_EVAL_AGENT_WORKSPACE"]).resolve()
snapshot = Path(os.environ["REVIEW_EVAL_AGENT_SNAPSHOT"])
snapshot.mkdir(parents=True)
result = subprocess.run(
    ["git", "-C", str(workspace), "ls-files", "-co", "--exclude-standard", "-z"],
    check=True,
    stdout=subprocess.PIPE,
)
for raw in sorted(item for item in result.stdout.split(b"\0") if item):
    relative_text = os.fsdecode(raw)
    relative = PurePosixPath(relative_text)
    if relative.is_absolute() or any(part in ("", ".", "..") for part in relative.parts):
        raise SystemExit(f"unsafe snapshot path: {relative_text!r}")
    source = workspace.joinpath(*relative.parts)
    if not source.exists() and not source.is_symlink():
        continue
    target = snapshot.joinpath(*relative.parts)
    target.parent.mkdir(parents=True, exist_ok=True)
    mode = source.lstat().st_mode
    if stat.S_ISLNK(mode):
        target.symlink_to(os.readlink(source))
    elif stat.S_ISREG(mode):
        shutil.copy2(source, target, follow_symlinks=False)
PY
}

review_eval_agent_capture_wave() {
  local workspace="$1" result_dir="$2"
  shift 2
  local raw iteration="" pass_id="" snapshot_rel snapshot
  for raw in "$@"; do
    case "$raw" in
      iteration_int=*) iteration="${raw#*=}" ;;
      pass_id=*) pass_id="${raw#*=}" ;;
    esac
  done
  case "$iteration" in
    ""|*[!0-9]*|0) return 1 ;;
  esac
  [[ -n "$pass_id" ]] || return 1
  snapshot_rel=$(printf 'snapshots/wave-%04d' "$((10#$iteration))")
  snapshot="$result_dir/$snapshot_rel"
  mkdir -p "$result_dir"
  review_eval_agent_snapshot_checkout "$workspace" "$snapshot" || return 1

  REVIEW_EVAL_AGENT_JOURNAL="$result_dir/waves.jsonl" \
  REVIEW_EVAL_AGENT_SNAPSHOT_REL="$snapshot_rel" \
    python3 - "$@" <<'PY'
import json
import os
import re
import sys

payload = {}
for raw in sys.argv[1:]:
    key, separator, value = raw.partition("=")
    if not separator or not re.fullmatch(r"[a-z][a-z0-9_]*(?:_(?:int|bool))?", key):
        raise SystemExit("invalid observer field")
    if key.endswith("_int"):
        payload[key[:-4]] = int(value)
    elif key.endswith("_bool"):
        if value not in {"true", "false"}:
            raise SystemExit("invalid observer boolean")
        payload[key[:-5]] = value == "true"
    else:
        payload[key] = value
if "snapshot" in payload:
    raise SystemExit("reserved observer field")
payload["snapshot"] = os.environ["REVIEW_EVAL_AGENT_SNAPSHOT_REL"]
with open(os.environ["REVIEW_EVAL_AGENT_JOURNAL"], "a", encoding="utf-8") as handle:
    handle.write(json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n")
PY
}

review_eval_agent_record_assessment() {
  local result_dir="$1" record="$2" tier reason_codes extra
  IFS=$'\t' read -r tier reason_codes extra <<EOF
$record
EOF
  [[ -n "$tier" && -n "$reason_codes" && -z "${extra:-}" ]] || return 1
  case "$tier" in
    small|normal|complex) ;;
    *) return 1 ;;
  esac
  REVIEW_EVAL_AGENT_ASSESSMENT_FILE="$result_dir/assessment.jsonl" \
  REVIEW_EVAL_AGENT_ASSESSMENT_TIER="$tier" \
  REVIEW_EVAL_AGENT_ASSESSMENT_REASONS="$reason_codes" \
    python3 - <<'PY'
import json
import os

payload = {
    "reason_codes": os.environ["REVIEW_EVAL_AGENT_ASSESSMENT_REASONS"],
    "tier": os.environ["REVIEW_EVAL_AGENT_ASSESSMENT_TIER"],
}
with open(os.environ["REVIEW_EVAL_AGENT_ASSESSMENT_FILE"], "a", encoding="utf-8") as handle:
    handle.write(json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n")
PY
}
