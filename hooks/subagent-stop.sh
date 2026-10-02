#!/usr/bin/env bash
# SubagentStop hook — a mission helper has finished. Read the dx-result block
# from its last message, record the assignment's outcome in the mission ledger,
# release its write lease if it held one, and keep the observations it
# submitted for the memory pipeline. A missing or unparseable block is
# recorded as UNREPORTED rather than guessed. The block is data: only its
# known fields are read, and nothing in it can grant or keep a lease. Outside
# a mission, or for an agent that is not a Dex role, this does nothing. It
# never blocks the stop.
set -euo pipefail

[[ "${DX_MISSION_ACTIVE:-0}" == 1 ]] || exit 0

# shellcheck disable=SC2034  # read by lib/common.sh while it is sourced
DX_COMMON_MODULES="lock session session-process mission"
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

HOOK_INPUT=$(cat 2>/dev/null || true)
[[ -n "$HOOK_INPUT" ]] || exit 0

SESSION_ID="${DEX_SESSION_ID:-$(dx_session_id)}"
LEDGER_DIR=$(dx_mission_dir "$SESSION_ID")
REVISION_AFTER=$(git rev-parse HEAD 2>/dev/null || printf 'unknown')

# One Python pass: identify the helper, parse the result block, append its
# observations to the mission overlay, and hand the shell what the ledger
# needs. Anything odd in the message degrades to UNREPORTED.
RESULT=$(DX_HOOK_INPUT="$HOOK_INPUT" DX_LEDGER_DIR="$LEDGER_DIR" DX_REVISION_AFTER="$REVISION_AFTER" python3 - <<'PY'
import json
import os
import re
import sys
from datetime import datetime, timezone

ROLES = ("dx-implementer", "dx-investigator", "dx-reviewer")
STATUSES = ("IMPLEMENTED", "BLOCKED", "FINDING", "INVESTIGATED", "REVIEWED",
            "CHECK_RESULT", "CHECK_REQUESTED")

try:
    payload = json.loads(os.environ["DX_HOOK_INPUT"])
except Exception:
    sys.exit(0)
if not isinstance(payload, dict):
    sys.exit(0)
agent_id = payload.get("agent_id")
agent_type = payload.get("agent_type")
if not isinstance(agent_id, str) or not agent_id or agent_type not in ROLES:
    sys.exit(0)
ledger_dir = os.environ["DX_LEDGER_DIR"]
if not os.path.isfile(os.path.join(ledger_dir, "records.jsonl")):
    sys.exit(0)

message = payload.get("last_assistant_message")
if not isinstance(message, str):
    message = ""
block = None
match = re.search(r"```dx-result\s*\n(.*?)\n```", message, re.S)
if match:
    try:
        block = json.loads(match.group(1))
    except ValueError:
        block = None
if not isinstance(block, dict):
    block = None

def strings(value, limit=50, width=400):
    if not isinstance(value, list):
        return []
    return [str(item)[:width] for item in value[:limit]]

status = "UNREPORTED"
reported_status = None
summary = None
changed_paths = []
checks = []
findings = 0
observations = []
remaining = None
if block is not None:
    reported_status = str(block.get("status", ""))[:40]
    if reported_status in STATUSES:
        status = reported_status
    summary = str(block.get("summary", ""))[:1000] or None
    changed_paths = strings(block.get("changed_paths"))
    checks = strings(block.get("checks"))
    findings = len(block.get("findings") or []) if isinstance(block.get("findings"), list) else 0
    remaining = str(block.get("remaining_uncertainty", ""))[:500] or None
    raw = block.get("observations")
    if isinstance(raw, list):
        for item in raw[:20]:
            if not isinstance(item, dict) or not isinstance(item.get("lesson"), str):
                continue
            observations.append({
                "lesson": item["lesson"][:600],
                "evidence": str(item.get("evidence", ""))[:600],
                "scope": str(item.get("scope", "mission"))[:40],
                "type": str(item.get("type", "hypothesis"))[:40],
            })

# A helper that ended without the block is asked once to add it; a second
# stop without it is recorded as it is. The flag lives in the ledger snapshot,
# so a restart does not nudge twice.
nudge = False
if block is None:
    try:
        current = json.load(open(os.path.join(ledger_dir, "current.json")))
        already = (current.get("assignments") or {}).get(agent_id, {}).get("nudged", False)
    except Exception:
        already = True
    nudge = not already

if observations:
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    path = os.path.join(ledger_dir, "observations.jsonl")
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        for item in observations:
            row = dict(item)
            row.update({"recorded_at": now, "agent_id": agent_id, "agent_type": agent_type,
                        "revision": os.environ["DX_REVISION_AFTER"], "trust": "candidate"})
            os.write(fd, (json.dumps(row, sort_keys=True) + "\n").encode("utf-8"))
        os.fsync(fd)
    finally:
        os.close(fd)

print(json.dumps({
    "agent_id": agent_id,
    "agent_type": agent_type,
    "assignment": {
        "id": agent_id, "status": status, "reported_status": reported_status,
        "summary": summary, "changed_paths": changed_paths, "checks": checks,
        "findings": findings, "observations": len(observations),
        "remaining_uncertainty": remaining, "reported": block is not None,
        "revision_after": os.environ["DX_REVISION_AFTER"],
        "nudged": nudge or (block is None),
    },
    "nudge": nudge,
}))
PY
) || exit 0
[[ -n "$RESULT" ]] || exit 0

AGENT_ID=$(printf '%s' "$RESULT" | python3 -c 'import json, sys; print(json.load(sys.stdin)["agent_id"])')
ASSIGNMENT=$(printf '%s' "$RESULT" | python3 -c 'import json, sys; print(json.dumps(json.load(sys.stdin)["assignment"]))')
dx_mission_write "$SESSION_ID" record assignment --actor "$AGENT_ID" --json "$ASSIGNMENT" >/dev/null 2>&1 || true

HOLDER=$(dx_mission_ledger "$SESSION_ID" lease show 2>/dev/null \
  | python3 -c 'import json, sys
try:
    print(json.load(sys.stdin).get("holder", ""))
except Exception:
    print("")' 2>/dev/null || true)
NUDGE=$(printf '%s' "$RESULT" | python3 -c 'import json, sys; print("1" if json.load(sys.stdin).get("nudge") else "0")')
if [[ "$NUDGE" == "1" ]]; then
  # Ask once for the structured result; keep the lease so the helper can
  # finish. The second stop is recorded whatever it says.
  python3 -c 'import json; print(json.dumps({"decision": "block", "reason": "Your final message has no dx-result block. End with one: ```dx-result {\"status\": \"IMPLEMENTED | BLOCKED | FINDING | INVESTIGATED | REVIEWED | CHECK_RESULT\", \"summary\": \"...\", \"changed_paths\": [], \"checks\": [], \"findings\": [], \"observations\": []} ``` so the lead can record your result."}))'
  exit 0
fi
if [[ -n "$HOLDER" && "$HOLDER" == "$AGENT_ID" ]]; then
  dx_mission_write "$SESSION_ID" lease release --holder "$AGENT_ID" \
    --revision-after "$REVISION_AFTER" --actor "$AGENT_ID" >/dev/null 2>&1 || true
fi
exit 0
