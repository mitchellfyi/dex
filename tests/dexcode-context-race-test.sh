#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-dexcode-context-race-test.XXXXXX")"

cleanup() {
  [[ -n "${RACER_PID:-}" ]] && kill "$RACER_PID" 2>/dev/null || true
  [[ -n "${RACER_PID:-}" ]] && wait "$RACER_PID" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_RTK_ENABLED=0
mkdir -p "$HOME"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

REPO="$TMP_DIR/repo"
RULES="$REPO/.dex/rules"
EXTERNAL_SECRET="$TMP_DIR/external-secret.md"
EXTERNAL_MCP="$TMP_DIR/external-mcp.json"
EXTERNAL_SETTINGS="$TMP_DIR/external-settings.json"
STOP_FILE="$TMP_DIR/stop"
mkdir -p "$RULES" "$REPO/.claude"
printf '# Project context\n' > "$REPO/.dex/dex.md"
printf '# Safe rule\n' > "$RULES/race.md"
printf 'context-race-must-not-leak\n' > "$EXTERNAL_SECRET"
printf '{"mcpServers":{"context-race-external-mcp":{"env":{"OUTSIDE_SENTINEL":"must-not-leak"}}}}\n' > "$EXTERNAL_MCP"
printf '{"mcpServers":{"context-race-external-settings":{"env":{"OUTSIDE_SETTINGS":"must-not-leak"}}}}\n' > "$EXTERNAL_SETTINGS"
printf '{"mcpServers":{"safe-local":{"command":"safe"}}}\n' > "$REPO/.mcp.json"
printf '{"mcpServers":{"safe-settings":{"command":"safe"}}}\n' > "$REPO/.claude/settings.json"

DX_TEST_RACE_PATH="$RULES/race.md" \
DX_TEST_EXTERNAL_SECRET="$EXTERNAL_SECRET" \
DX_TEST_MCP_PATH="$REPO/.mcp.json" \
DX_TEST_EXTERNAL_MCP="$EXTERNAL_MCP" \
DX_TEST_SETTINGS_PATH="$REPO/.claude/settings.json" \
DX_TEST_EXTERNAL_SETTINGS="$EXTERNAL_SETTINGS" \
DX_TEST_STOP_FILE="$STOP_FILE" python3 - <<'PY' &
import json
import os
from pathlib import Path

stop = Path(os.environ["DX_TEST_STOP_FILE"])
targets = [
    (
        Path(os.environ["DX_TEST_RACE_PATH"]),
        Path(os.environ["DX_TEST_EXTERNAL_SECRET"]),
        b"# Safe rule\n",
    ),
    (
        Path(os.environ["DX_TEST_MCP_PATH"]),
        Path(os.environ["DX_TEST_EXTERNAL_MCP"]),
        json.dumps({"mcpServers": {"safe-local": {"command": "safe"}}}).encode() + b"\n",
    ),
    (
        Path(os.environ["DX_TEST_SETTINGS_PATH"]),
        Path(os.environ["DX_TEST_EXTERNAL_SETTINGS"]),
        json.dumps({"mcpServers": {"safe-settings": {"command": "safe"}}}).encode() + b"\n",
    ),
]
counter = 0
while not stop.exists():
    counter += 1
    for index, (path, external, safe_body) in enumerate(targets):
        link = path.with_name(f".race-link-{index}-{counter}")
        try:
            link.symlink_to(external)
            os.replace(link, path)
        except OSError:
            try:
                link.unlink()
            except OSError:
                pass
        regular = path.with_name(f".race-file-{index}-{counter}")
        try:
            regular.write_bytes(safe_body)
            os.replace(regular, path)
        except OSError:
            try:
                regular.unlink()
            except OSError:
                pass
PY
RACER_PID=$!

for index in $(seq 1 100); do
  payload="$TMP_DIR/context-$index.json"
  dx_dexcode_context_payload "$REPO" "$payload"
  DX_TEST_PAYLOAD="$payload" python3 - <<'PY'
import json
import os
from pathlib import Path

payload = json.loads(Path(os.environ["DX_TEST_PAYLOAD"]).read_text(encoding="utf-8"))
encoded = json.dumps(payload, sort_keys=True)
assert "context-race-must-not-leak" not in encoded, payload
assert "context-race-external-mcp" not in encoded, payload
assert "context-race-external-settings" not in encoded, payload
allowed = {"MCP: safe-local", "MCP: safe-settings"}
assert {item["name"] for item in payload["integrations"]} <= allowed, payload
PY
done

: > "$STOP_FILE"
wait "$RACER_PID"
RACER_PID=""

printf 'dexcode-context-race-test passed\n'
