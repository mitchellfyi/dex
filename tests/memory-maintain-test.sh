#!/usr/bin/env bash
set -euo pipefail

# The memory store keeps itself in check without a human queue. `maintain`
# promotes a candidate that independent sessions corroborate, retires what
# stayed stale, idle or unused past its window, and reopens a retired lesson
# when it is observed again. `review-export` tells the curator what changed
# and whether a review is due. `curate-apply` takes the curator's decisions,
# validates every one (an id that exists, a reason, a live merge target) and
# applies the valid ones to the store, never to tracked files.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-memory-maintain-test.XXXXXX")"
cleanup() { chmod -R u+w "$TMP_DIR" 2>/dev/null || true; rm -rf "$TMP_DIR"; }
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_RUN_ROOT="$TMP_DIR/runs"
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR" "$DX_RUN_ROOT"
# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"
# shellcheck disable=SC1091
source "$ROOT/lib/memory.sh"
STORE_PY="$ROOT/scripts/memory_store.py"

jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }
jline() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$1" "$2"; }

REPO="$TMP_DIR/repo"
mkdir -p "$REPO/lib" "$REPO/.dex/memory/domains"
git init -q -b main "$REPO"
git -C "$REPO" config user.email "dex@example.com"
git -C "$REPO" config user.name "Dex Test"
printf 'echo a\n' > "$REPO/lib/a.sh"
printf 'echo b\n' > "$REPO/lib/b.sh"
cat > "$REPO/.dex/memory/domains/ops.md" <<'MD'
# Ops

## M-001: Run the suite through the manifest runner
Status: active
Applies to paths: tests/
Applies to phases: 4
Recheck when: the runner changes
Depends on: lib/a.sh

Lesson:
Use the manifest runner.

Evidence:
tests/run-all.sh
MD
git -C "$REPO" add .
git -C "$REPO" -c commit.gpgsign=false commit -q -m "init"
SHA="$(git -C "$REPO" rev-parse HEAD)"

export DX_MEMORY_STORE_DIR="$TMP_DIR/store"
store() { python3 "$STORE_PY" "$DX_MEMORY_STORE_DIR" "$@"; }
ENTRIES="$DX_MEMORY_STORE_DIR/entries.json"

# Entries: an unchecked fact seen by two sessions, the same from one session
# twice, a hypothesis, a checked fact that will go stale, a checked fact that
# will be retrieved, and a checked fact nobody retrieves.
cat > "$TMP_DIR/s1.jsonl" <<'OBS'
{"lesson":"the deploy script needs the staging flag before the env name","evidence":"two runs failed without it","scope":"repo","type":"fact"}
{"lesson":"a lesson one session repeats to itself","evidence":"seen in this session","scope":"repo","type":"fact"}
{"lesson":"the suite might be faster with three workers","evidence":"one run took 40s","scope":"repo","type":"hypothesis"}
OBS
cat > "$TMP_DIR/s2.jsonl" <<'OBS'
{"lesson":"the deploy script needs the staging flag before the env name","evidence":"same failure, different task","scope":"repo","type":"fact"}
OBS
cat > "$TMP_DIR/s1-again.jsonl" <<'OBS'
{"lesson":"a lesson one session repeats to itself","evidence":"seen in this session","scope":"repo","type":"fact"}
OBS
cat > "$TMP_DIR/s3.jsonl" <<OBS
{"lesson":"lib/a.sh prints a; the entry point is there","evidence":"lib/a.sh@${SHA}","scope":"repo","type":"fact"}
{"lesson":"lib/b.sh prints b and is retrieved by sessions touching it","evidence":"lib/b.sh@${SHA}","scope":"repo","type":"fact"}
{"lesson":"nobody ever asks about this verified fact","evidence":"lib/b.sh@${SHA} line 1","scope":"repo","type":"fact"}
OBS
store ingest --repo "$REPO" --source "mission:s1" "$TMP_DIR/s1.jsonl" > /dev/null
store ingest --repo "$REPO" --source "mission:s2" "$TMP_DIR/s2.jsonl" > /dev/null
store ingest --repo "$REPO" --source "mission:s1" "$TMP_DIR/s1-again.jsonl" > /dev/null
store ingest --repo "$REPO" --source "mission:s3" "$TMP_DIR/s3.jsonl" > /dev/null

id_of() { python3 - "$ENTRIES" "$1" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for identity, entry in data["entries"].items():
    if entry["lesson"].startswith(sys.argv[2]):
        print(identity); break
PY
}
DEPLOY="$(id_of "the deploy script")"
SELFREPEAT="$(id_of "a lesson one session")"
HYPO="$(id_of "the suite might")"
STALE="$(id_of "lib/a.sh prints a")"
USED="$(id_of "lib/b.sh prints b")"
UNUSED="$(id_of "nobody ever asks")"
[[ -n "$DEPLOY" && -n "$SELFREPEAT" && -n "$HYPO" && -n "$STALE" && -n "$USED" && -n "$UNUSED" ]] || assert_at $LINENO
[[ "$(jget "$ENTRIES" "d['entries']['$DEPLOY']['status']")" == "candidate" ]] || assert_at $LINENO

# ── maintain: independent corroboration promotes; self-repetition does not ──
OUT="$(store maintain --repo "$REPO" --now 2026-10-01T00:00:00Z)"
[[ "$(jline "$OUT" "d['promoted']")" == "['$DEPLOY']" ]] || assert_at $LINENO
[[ "$(jget "$ENTRIES" "d['entries']['$DEPLOY']['status']")" == "active" ]] || assert_at $LINENO
[[ "$(jget "$ENTRIES" "d['entries']['$DEPLOY']['trust']")" == "corroborated" ]] || assert_at $LINENO
[[ "$(jget "$ENTRIES" "d['entries']['$SELFREPEAT']['status']")" == "candidate" ]] || assert_at $LINENO
[[ "$(jget "$ENTRIES" "d['entries']['$HYPO']['status']")" == "candidate" ]] || assert_at $LINENO
[[ "$(jline "$OUT" "d['retired']")" == "[]" ]] || assert_at $LINENO
[[ "$(jget "$ENTRIES" "d.get('last_maintained_at')")" == "2026-10-01T00:00:00Z" ]] || assert_at $LINENO
[[ -f "$DX_MEMORY_STORE_DIR/maintenance.log" ]] || assert_at $LINENO

# A promoted entry is retrieved like any active fact.
# No file to depend on, so it surfaces for paths that share a distinctive word.
store retrieve --repo "$REPO" --paths scripts/deploy.sh --session t --role lead > "$TMP_DIR/r0.out" 2>&1
assert_contains "obs:$DEPLOY" "$TMP_DIR/r0.out"

# ── maintain: stale past the window retires; inside the window waits ──────
printf 'echo changed\n' > "$REPO/lib/a.sh"
store recheck --repo "$REPO" > /dev/null
[[ "$(jget "$ENTRIES" "d['entries']['$STALE']['status']")" == "needs-recheck" ]] || assert_at $LINENO
STALE_AT="$(jget "$ENTRIES" "d['entries']['$STALE']['stale_at']")"
[[ -n "$STALE_AT" ]] || assert_at $LINENO
python3 - "$ENTRIES" "$STALE" <<'PY'
import json, sys
path, identity = sys.argv[1], sys.argv[2]
data = json.load(open(path))
data["entries"][identity]["stale_at"] = "2026-09-01T00:00:00Z"
open(path, "w").write(json.dumps(data, sort_keys=True, indent=1) + "\n")
PY
OUT="$(store maintain --repo "$REPO" --now 2026-09-10T00:00:00Z --stale-days 14)"
[[ "$(jget "$ENTRIES" "d['entries']['$STALE']['status']")" == "needs-recheck" ]] || assert_at $LINENO
OUT="$(store maintain --repo "$REPO" --now 2026-09-20T00:00:00Z --stale-days 14 --idle-days 365 --unused-days 365)"
[[ "$(jline "$OUT" "d['retired']")" == "['$STALE']" ]] || assert_at $LINENO
[[ "$(jget "$ENTRIES" "d['entries']['$STALE']['status']")" == "retired" ]] || assert_at $LINENO
[[ "$(jget "$ENTRIES" "d['entries']['$STALE']['retired_reason']")" == stale:* ]] || assert_at $LINENO

# ── maintain: idle candidates and unused actives retire, used ones stay ────
store retrieve --repo "$REPO" --paths lib/b.sh --session t1 --role lead > "$TMP_DIR/r1.out"
assert_contains "obs:$USED" "$TMP_DIR/r1.out"
assert_contains "obs:$UNUSED" "$TMP_DIR/r1.out"
# The unused one was loaded once too (same path); push its last retrieval back.
python3 - "$DX_MEMORY_STORE_DIR/retrieval.log" "$UNUSED" <<'PY'
import json, sys
path, identity = sys.argv[1], sys.argv[2]
rows = [json.loads(l) for l in open(path) if l.strip()]
for row in rows:
    if f"obs:{identity}" in row.get("loaded", []):
        row["loaded"] = [i for i in row["loaded"] if i != f"obs:{identity}"]
rows.append({"ts": "2026-01-01T00:00:00Z", "session": "old", "role": "lead", "paths": ["lib/b.sh"],
             "loaded": [f"obs:{identity}"], "skipped": [], "stale": [], "chars": 10})
open(path, "w").write("".join(json.dumps(r, sort_keys=True) + "\n" for r in rows))
PY
python3 - "$ENTRIES" "$HYPO" "$UNUSED" "$SELFREPEAT" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
for identity in sys.argv[2:]:
    data["entries"][identity]["last_seen"] = "2026-01-01T00:00:00Z"
open(path, "w").write(json.dumps(data, sort_keys=True, indent=1) + "\n")
PY
OUT="$(store maintain --repo "$REPO" --now 2026-10-01T00:00:00Z --idle-days 45 --unused-days 90)"
RETIRED="$(jline "$OUT" "sorted(d['retired'])")"
[[ "$RETIRED" == "$(python3 -c 'import sys; print(sorted(sys.argv[1:]))' "$HYPO" "$UNUSED" "$SELFREPEAT")" ]] || assert_at $LINENO
[[ "$(jget "$ENTRIES" "d['entries']['$HYPO']['retired_reason']")" == idle* ]] || assert_at $LINENO
[[ "$(jget "$ENTRIES" "d['entries']['$UNUSED']['retired_reason']")" == unused* ]] || assert_at $LINENO
[[ "$(jget "$ENTRIES" "d['entries']['$USED']['status']")" == "active" ]] || assert_at $LINENO
[[ "$(jget "$ENTRIES" "d['entries']['$DEPLOY']['status']")" == "active" ]] || assert_at $LINENO

# Retired entries are not retrieved; a second pass changes nothing.
store retrieve --repo "$REPO" --paths lib/b.sh --session t2 --role lead > "$TMP_DIR/r2.out"
assert_contains "obs:$USED" "$TMP_DIR/r2.out"
! grep -q "obs:$UNUSED" "$TMP_DIR/r2.out" || assert_at $LINENO
OUT="$(store maintain --repo "$REPO" --now 2026-10-01T00:00:00Z --idle-days 45 --unused-days 90)"
[[ "$(jline "$OUT" "d['retired']")" == "[]" && "$(jline "$OUT" "d['promoted']")" == "[]" ]] || assert_at $LINENO

# ── a retired lesson observed again reopens ───────────────────────────────
cat > "$TMP_DIR/s4.jsonl" <<'OBS'
{"lesson":"the suite might be faster with three workers","evidence":"another run, 38s","scope":"repo","type":"hypothesis"}
OBS
store ingest --repo "$REPO" --source "mission:s4" "$TMP_DIR/s4.jsonl" > /dev/null
[[ "$(jget "$ENTRIES" "d['entries']['$HYPO']['status']")" == "candidate" ]] || assert_at $LINENO
[[ -n "$(jget "$ENTRIES" "d['entries']['$HYPO'].get('reopened_at','')")" ]] || assert_at $LINENO
[[ "$(jget "$ENTRIES" "d['entries']['$HYPO'].get('retired_reason','')")" == "" ]] || assert_at $LINENO
[[ "$(jget "$ENTRIES" "d['entries']['$HYPO']['seen']")" == "2" ]] || assert_at $LINENO

# ── review-export: what the curator sees, and whether it is due ───────────
EXPORT="$(store review-export --repo "$REPO" --now 2026-10-01T00:00:00Z --min-changes 5 --max-age-days 7)"
[[ "$(jline "$EXPORT" "d['due']")" == "False" ]] || assert_at $LINENO
[[ "$(jline "$EXPORT" "d['changed_since_curation']")" -ge 3 ]] || assert_at $LINENO
[[ "$(jline "$EXPORT" "sorted(e['id'] for e in d['entries'])")" == "$(python3 -c 'import sys; print(sorted(sys.argv[1:]))' "obs:$DEPLOY" "obs:$HYPO" "obs:$USED")" ]] || assert_at $LINENO
[[ "$(jline "$EXPORT" "[e['retrievals'] for e in d['entries'] if e['id']=='obs:$USED'][0]")" == "2" ]] || assert_at $LINENO
[[ "$(jline "$EXPORT" "[c['id'] for c in d['curated']]")" == "['M-001']" ]] || assert_at $LINENO
[[ "$(jline "$EXPORT" "d['retired_count']")" == "3" ]] || assert_at $LINENO
EXPORT="$(store review-export --repo "$REPO" --now 2026-10-01T00:00:00Z --min-changes 3 --max-age-days 7)"
[[ "$(jline "$EXPORT" "d['due']")" == "True" ]] || assert_at $LINENO

# ── curate-apply: validated decisions, applied to the store only ──────────
cat > "$TMP_DIR/decisions.json" <<JSON
{"decisions": [
  {"id": "obs:$USED", "action": "promote", "reason": "verified against lib/b.sh, used by two sessions, generalises"},
  {"id": "obs:$HYPO", "action": "rewrite", "type": "fact", "lesson": "the suite runs in 38-40s with the default workers; three workers were not faster", "evidence": "lib/b.sh@${SHA} and two timed runs", "reason": "two timings, not a hypothesis any more"},
  {"id": "obs:$DEPLOY", "action": "merge", "into": "obs:$USED", "reason": "the staging flag is part of the same deploy procedure"},
  {"id": "obs:does-not-exist", "action": "retire", "reason": "a reason for an id the store never had"},
  {"id": "obs:$USED", "action": "retire", "reason": ""},
  {"id": "obs:$USED", "action": "explode", "reason": "an action the store does not know"},
  {"id": "M-001", "action": "retire", "reason": "the manifest runner is documented in AGENTS.md; this duplicates it"}
]}
JSON
# Curation happens at real time: ingests are stamped with the clock, so the
# "changed since curation" checks below need a curation time after them.
OUT="$(store curate-apply --repo "$REPO" --actor "curator:test" "$TMP_DIR/decisions.json")"
[[ "$(jline "$OUT" "len(d['applied'])")" == "4" ]] || assert_at $LINENO
[[ "$(jline "$OUT" "len(d['rejected'])")" == "3" ]] || assert_at $LINENO
[[ "$(jline "$OUT" "sorted(r['reason'] for r in d['rejected'])")" == *"unknown id"* ]] || assert_at $LINENO
[[ "$(jline "$OUT" "sorted(r['reason'] for r in d['rejected'])")" == *"missing reason"* ]] || assert_at $LINENO
[[ "$(jline "$OUT" "sorted(r['reason'] for r in d['rejected'])")" == *"unknown action"* ]] || assert_at $LINENO
[[ "$(jget "$ENTRIES" "d['entries']['$USED'].get('curated')")" == "True" ]] || assert_at $LINENO
[[ "$(jget "$ENTRIES" "d['entries']['$USED']['trust']")" == "curated" ]] || assert_at $LINENO
[[ "$(jget "$ENTRIES" "d['entries']['$HYPO']['type']")" == "fact" ]] || assert_at $LINENO
[[ "$(jget "$ENTRIES" "d['entries']['$HYPO']['status']")" == "active" ]] || assert_at $LINENO
BLOB_B="$(git -C "$REPO" hash-object lib/b.sh)"
[[ "$(jget "$ENTRIES" "d['entries']['$HYPO']['depends_on']")" == "['lib/b.sh@${BLOB_B}']" ]] || assert_at $LINENO
[[ "$(jget "$ENTRIES" "d['entries']['$HYPO']['rewritten_from']")" == "the suite might be faster with three workers" ]] || assert_at $LINENO
[[ "$(jget "$ENTRIES" "d['entries']['$DEPLOY']['status']")" == "retired" ]] || assert_at $LINENO
[[ "$(jget "$ENTRIES" "d['entries']['$DEPLOY']['merged_into']")" == "$USED" ]] || assert_at $LINENO
[[ "$(jget "$ENTRIES" "d['entries']['$USED']['seen']")" -ge 3 ]] || assert_at $LINENO
CURATED_AT="$(jget "$ENTRIES" "d.get('last_curated_at')")"
[[ "$CURATED_AT" =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}T ]] || assert_at $LINENO
[[ "$(jget "$DX_MEMORY_STORE_DIR/curated-overlay.json" "d['M-001']['status']")" == "retired" ]] || assert_at $LINENO
[[ "$(jget "$DX_MEMORY_STORE_DIR/curated-overlay.json" "d['M-001']['actor']")" == "curator:test" ]] || assert_at $LINENO
# The tracked domain file is untouched: materialisation stays with dx sync.
[[ -z "$(git -C "$REPO" status --porcelain -- .dex/memory)" ]] || assert_at $LINENO
[[ -f "$DX_MEMORY_STORE_DIR/curation.log" ]] || assert_at $LINENO
[[ "$(rtk proxy grep -c 'curator:test' "$DX_MEMORY_STORE_DIR/curation.log" 2>/dev/null || grep -c 'curator:test' "$DX_MEMORY_STORE_DIR/curation.log")" -ge 4 ]] || assert_at $LINENO

# Retrieval shows the curated entry first and skips the retired curated one.
store retrieve --repo "$REPO" --paths lib/b.sh,tests/x.sh --session t3 --role lead > "$TMP_DIR/r3.out"
assert_contains "obs:$USED" "$TMP_DIR/r3.out"
assert_contains "curated" "$TMP_DIR/r3.out"
! grep -q "M-001" "$TMP_DIR/r3.out" || assert_at $LINENO
! grep -q "obs:$DEPLOY" "$TMP_DIR/r3.out" || assert_at $LINENO

# After a curation the age rule applies: one change plus eight days is due;
# eight days with nothing new is not.
plus_days() { python3 -c 'import sys, datetime; t = datetime.datetime.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ") + datetime.timedelta(days=float(sys.argv[2])); print(t.strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1" "$2"; }
EXPORT="$(store review-export --repo "$REPO" --now "$(plus_days "$CURATED_AT" 3)" --min-changes 5 --max-age-days 7)"
[[ "$(jline "$EXPORT" "d['due']")" == "False" ]] || assert_at $LINENO
EXPORT="$(store review-export --repo "$REPO" --now "$(plus_days "$CURATED_AT" 8)" --min-changes 5 --max-age-days 7)"
[[ "$(jline "$EXPORT" "d['due']")" == "False" ]] || assert_at $LINENO
sleep 1
cat > "$TMP_DIR/s5.jsonl" <<OBS
{"lesson":"a brand new verified fact about lib/b.sh after curation","evidence":"lib/b.sh@${SHA}","scope":"repo","type":"fact"}
OBS
store ingest --repo "$REPO" --source "mission:s5" "$TMP_DIR/s5.jsonl" > /dev/null
EXPORT="$(store review-export --repo "$REPO" --now "$(plus_days "$CURATED_AT" 8)" --min-changes 5 --max-age-days 7)"
[[ "$(jline "$EXPORT" "d['due']")" == "True" ]] || assert_at $LINENO
EXPORT="$(store review-export --repo "$REPO" --now "$(plus_days "$CURATED_AT" 3)" --min-changes 5 --max-age-days 7)"
[[ "$(jline "$EXPORT" "d['due']")" == "False" ]] || assert_at $LINENO

# A decisions file that is not a decision list is refused without changes.
BEFORE="$(shasum "$ENTRIES")"
printf '{"nope": 1}\n' > "$TMP_DIR/bad.json"
if store curate-apply --repo "$REPO" --actor "curator:test" "$TMP_DIR/bad.json" > "$TMP_DIR/bad.out" 2>&1; then
  assert_at $LINENO
fi
[[ "$(shasum "$ENTRIES")" == "$BEFORE" ]] || assert_at $LINENO

# dx_memory_maintain runs the same pass through the library.
OUT="$(dx_memory_maintain "$REPO" --now 2026-10-10T00:00:00Z)"
[[ "$(jline "$OUT" "d['retired']")" == "[]" ]] || assert_at $LINENO

printf 'memory maintain tests passed\n'
