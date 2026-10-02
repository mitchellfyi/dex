#!/usr/bin/env bash
set -euo pipefail

# Every lifecycle leaves signals behind and used to delete most of them at
# completion: review-ledger findings, the reason behind each override or
# waiver, failed gates, waived or skipped phases, and the guard warnings the
# agent saw. The harvest turns those artifacts into observations for the
# memory store, with no model call, and runs before the state is removed.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/dex-lifecycle-harvest-test.XXXXXX")" && pwd -P)"
cleanup() { chmod -R u+w "$TMP_DIR" 2>/dev/null || true; rm -rf "$TMP_DIR"; }
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_RUN_ROOT="$TMP_DIR/runs"
export DX_MEMORY_STORE_DIR="$TMP_DIR/store"
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR" "$DX_RUN_ROOT"
# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"
# shellcheck disable=SC1091
source "$ROOT/lib/memory.sh"
HARVEST="$ROOT/scripts/lifecycle_harvest.py"

jline() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$1" "$2"; }

REPO="$TMP_DIR/repo"
mkdir -p "$REPO/lib" "$REPO/tests"
git init -q -b main "$REPO"
git -C "$REPO" config user.email "dex@example.com"
git -C "$REPO" config user.name "Dex Test"
printf 'echo a\n' > "$REPO/lib/a.sh"
printf 'echo t\n' > "$REPO/tests/a-test.sh"
git -C "$REPO" add . && git -C "$REPO" -c commit.gpgsign=false commit -q -m init

SID="repo-fixture-worktree-ticket-9"

# ── the artifacts a lifecycle leaves ──────────────────────────────────────
cat > "$DX_LOOP_DIR/$SID.review-findings.json" <<'JSON'
[
 {"id": "f1", "file": "lib/a.sh", "lens": "correctness", "status": "fixed", "evidence": "the retry loop never slept between attempts", "wave_found": 1, "wave_fixed": 2},
 {"id": "f2", "file": "lib/a.sh", "lens": "security", "status": "open", "evidence": "secret read from argv is visible in ps", "wave_found": 2, "wave_fixed": null},
 {"id": "f3", "file": "tests/a-test.sh", "lens": "tests", "status": "note", "evidence": "a nit about naming", "wave_found": 1, "wave_fixed": null},
 {"id": "f4", "file": "lib/a.sh", "lens": "correctness", "status": "checked", "evidence": "implementer self-review before Phase 3", "wave_found": 0, "wave_fixed": null},
 {"id": "f5", "file": "lib/a.sh", "lens": "style", "status": "rejected", "evidence": "reviewer disagreed", "wave_found": 1, "wave_fixed": null}
]
JSON
printf '%s\n' $'created_at\tgeneration\taction\tgate\tvalue\tscope\tphase\tsource\texpires_at\treason' \
  $'1700000000\tg1\toverride\treview.max-waves\t9\tsession\t3\thuman\t\tthe generated client churns on every wave; waves are not finding real defects' \
  $'1700000100\tg2\twaive\tverify.ui-evidence\t\tphase\t4\tagent\t\tno UI in this change' \
  > "$DX_STATE_DIR/$SID.overrides"
printf '%s\n' $'recorded_at\tphase\toutcome\tsource\tgeneration\treason' \
  $'1700000200\t5\twaived\tagent\tg3\tno-remote' \
  $'1700000300\t4\tcompleted\tagent\tg4\tgate-passed' \
  > "$DX_STATE_DIR/$SID.phase-outcomes"
mkdir -p "$DX_LOOP_DIR/$SID.gate-receipts"
cat > "$DX_LOOP_DIR/$SID.gate-receipts/tests.json" <<JSON
{"schema_version": 2, "session": "$SID", "gate": "tests", "command": ["bash", "tests/run-all.sh"], "exit_code": 1, "duration_seconds": 42, "log": "$TMP_DIR/gate-tests.log", "recorded_at": "2026-10-01T00:00:00Z"}
JSON
cat > "$DX_LOOP_DIR/$SID.gate-receipts/lint.json" <<JSON
{"schema_version": 2, "session": "$SID", "gate": "lint", "command": ["bash", "tests/check.sh"], "exit_code": 0, "duration_seconds": 3, "log": "", "recorded_at": "2026-10-01T00:00:00Z"}
JSON
printf 'running tests\nFAIL a-test.sh: expected 3 got 2\ntoken=sk-live-abcdefghijklmnopqrstuvwxyz0123456789\n== 11 passed, 1 failed ==\n' > "$TMP_DIR/gate-tests.log"
printf '%s\n' '{"recorded_at":"2026-10-01T00:00:00Z","session":"'"$SID"'","command":"npm test"}' \
  '{"recorded_at":"2026-10-01T00:01:00Z","session":"'"$SID"'","command":"npm test -- --watch=false"}' \
  > "$DX_LOOP_DIR/$SID.gate-receipts/ungated.jsonl"
printf '%s\n' \
  '{"recorded_at":"2026-10-01T00:00:00Z","session":"'"$SID"'","guard":"warn-destructive-commands","event":"bash","head":"rm -rf \"$TMP\" in a heredoc"}' \
  '{"recorded_at":"2026-10-01T00:02:00Z","session":"'"$SID"'","guard":"warn-destructive-commands","event":"bash","head":"rm -rf \"$WORK\""}' \
  '{"recorded_at":"2026-10-01T00:03:00Z","session":"'"$SID"'","guard":"warn-detached-processes","event":"bash","head":"nohup node server.js &"}' \
  > "$DX_LOOP_DIR/$SID.guard-warnings.jsonl"

# ── harvest: one observation per signal worth keeping, nothing invented ───
python3 "$HARVEST" "$SID" --repo "$REPO" > "$TMP_DIR/harvest.jsonl"
COUNT=$(wc -l < "$TMP_DIR/harvest.jsonl" | tr -d ' ')
[[ "$COUNT" -ge 7 ]] || { cat "$TMP_DIR/harvest.jsonl" >&2; assert_at $LINENO; }
python3 - "$TMP_DIR/harvest.jsonl" <<'PY' || assert_at $LINENO
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
for row in rows:
    assert {"lesson", "evidence", "scope", "type", "signal"} <= set(row), row
    assert row["scope"] in ("repo", "environment"), row
lessons = "\n".join(r["lesson"] for r in rows)
# Findings that were real (fixed or still open) are kept with their file and lens.
assert any(r["signal"] == "review-finding" and "lib/a.sh" in r["lesson"] and "correctness" in r["lesson"] and "never slept" in r["lesson"] for r in rows), lessons
assert any(r["signal"] == "review-finding" and "security" in r["lesson"] and "visible in ps" in r["lesson"] for r in rows), lessons
# Notes, the implementer's own seeded rows and rejected findings are not lessons.
assert "a nit about naming" not in lessons and "self-review" not in lessons and "reviewer disagreed" not in lessons, lessons
# Overrides and waivers carry their reason, as decisions.
assert any(r["signal"] == "override" and r["type"] == "decision" and "review.max-waves" in r["lesson"] and "churns on every wave" in r["lesson"] for r in rows), lessons
assert any(r["signal"] == "override" and "verify.ui-evidence" in r["lesson"] and "no UI in this change" in r["lesson"] for r in rows), lessons
# A waived phase is a decision; a completed one is not news.
assert any(r["signal"] == "phase-outcome" and "Phase 5" in r["lesson"] and "waived" in r["lesson"] and "no-remote" in r["lesson"] for r in rows), lessons
assert not any(r["signal"] == "phase-outcome" and "Phase 4" in r["lesson"] for r in rows), lessons
# A failed gate names its command and carries a capped, redacted log tail; a passed gate is silent.
failed = [r for r in rows if r["signal"] == "gate-failure"]
assert len(failed) == 1 and "tests/run-all.sh" in failed[0]["lesson"] and "exit 1" in failed[0]["lesson"], failed
assert "expected 3 got 2" in failed[0]["evidence"] and "sk-live-abcdefghij" not in failed[0]["evidence"], failed[0]
# Heavy work outside a gate is a measurement, not a retrievable lesson.
ungated = [r for r in rows if r["signal"] == "ungated-heavy"]
assert len(ungated) == 1 and ungated[0]["type"] == "measurement" and "2 " in ungated[0]["lesson"], ungated
# Guard warnings are aggregated per guard with an example.
guards = {r["lesson"]: r for r in rows if r["signal"] == "guard-warning"}
assert any("warn-destructive-commands" in k and "2 time" in k for k in guards), guards.keys()
assert any("warn-detached-processes" in k and "1 time" in k for k in guards), guards.keys()
print("harvest rows ok:", len(rows))
PY

# Idempotent: the same artifacts produce the same rows.
python3 "$HARVEST" "$SID" --repo "$REPO" > "$TMP_DIR/harvest-2.jsonl"
cmp -s "$TMP_DIR/harvest.jsonl" "$TMP_DIR/harvest-2.jsonl" || assert_at $LINENO

# A session with no artifacts harvests nothing and exits 0.
python3 "$HARVEST" "no-such-session" --repo "$REPO" > "$TMP_DIR/empty.jsonl"
[[ ! -s "$TMP_DIR/empty.jsonl" ]] || assert_at $LINENO

# ── the library step ingests the harvest into the store, once ────────────
OUT="$(dx_memory_harvest_session "$SID" "$REPO")"
[[ "$(jline "$OUT" "d['ingested']")" -ge 7 ]] || { echo "$OUT" >&2; assert_at $LINENO; }
ENTRIES="$DX_MEMORY_STORE_DIR/entries.json"
python3 - "$ENTRIES" <<'PY' || assert_at $LINENO
import json, sys
data = json.load(open(sys.argv[1]))
entries = data["entries"].values()
# Review findings about lib/a.sh depend on that file and are active facts.
finding = next(e for e in entries if "never slept" in e["lesson"])
assert finding["status"] == "active" and any(d.startswith("lib/a.sh@") for d in finding["depends_on"]), finding
assert any(s.startswith("lifecycle:") for s in finding["sources"]), finding["sources"]
# The measurement is kept as calibration, not retrieved.
measurement = next(e for e in entries if e["type"] == "measurement")
assert measurement["scope"] == "environment", measurement
PY
# A second harvest of the same session adds nothing new (the cursor holds).
OUT2="$(dx_memory_harvest_session "$SID" "$REPO")"
[[ "$(jline "$OUT2" "d.get('skipped', '')")" == "already harvested" ]] || { echo "$OUT2" >&2; assert_at $LINENO; }
[[ -f "$DX_STATE_DIR/$SID.harvested" ]] || assert_at $LINENO

printf 'lifecycle harvest tests passed\n'
