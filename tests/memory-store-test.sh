#!/usr/bin/env bash
set -euo pipefail

# The external memory store is where observations go before anything is
# promoted into .dex/memory. Ingest validates and deduplicates them, checks
# their evidence against the repository and records what each one depends on.
# Retrieve returns the few entries that match the paths at hand (curated
# domain entries plus verified observations), and writes a trace of what it
# loaded and skipped. Recheck marks an entry stale when a file it depends on
# changed. Two repositories never share a store, even with the same name.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-memory-store-test.XXXXXX")"
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

make_repo() {
  local dir="$1"
  mkdir -p "$dir/lib" "$dir/docs"
  git init -q -b main "$dir"
  git -C "$dir" config user.email "dex@example.com"
  git -C "$dir" config user.name "Dex Test"
  printf 'echo a\n' > "$dir/lib/a.sh"
  printf 'docs\n' > "$dir/docs/x.md"
  git -C "$dir" add .
  git -C "$dir" -c commit.gpgsign=false commit -q -m "init"
}
REPO_A="$TMP_DIR/one/repo"; make_repo "$REPO_A"
REPO_B="$TMP_DIR/two/repo"; make_repo "$REPO_B"

# ── stores are keyed by repository identity, not by name ───────────────────
STORE_A="$(dx_memory_store_dir "$REPO_A")"
STORE_B="$(dx_memory_store_dir "$REPO_B")"
[[ -n "$STORE_A" && "$STORE_A" != "$STORE_B" ]] || assert_at $LINENO
[[ "$STORE_A" == "$HOME/.claude/.dex-memory/"* ]] || assert_at $LINENO
[[ "$(DX_MEMORY_STORE_DIR="$TMP_DIR/override" dx_memory_store_dir "$REPO_A")" == "$TMP_DIR/override" ]] || assert_at $LINENO

# ── ingest: validate, check evidence, record dependencies, deduplicate ─────
SHA_A="$(git -C "$REPO_A" rev-parse HEAD)"
cat > "$TMP_DIR/obs.jsonl" <<OBS
{"lesson":"lib/a.sh prints a; the CLI entry is there","evidence":"lib/a.sh@${SHA_A}","scope":"repo","type":"fact"}
{"lesson":"tests might be faster with 3 workers","evidence":"one run took 40s","scope":"repo","type":"hypothesis"}
{"lesson":"something without proof","evidence":"","scope":"repo","type":"fact"}
{"lesson":"lib/a.sh prints a; the CLI entry is there","evidence":"lib/a.sh@${SHA_A}","scope":"repo","type":"fact"}
{"lesson":"the suite takes 90s on this host","evidence":"bash tests/run-all.sh fast: 90s","scope":"environment","type":"measurement"}
OBS
python3 "$STORE_PY" "$STORE_A" ingest --repo "$REPO_A" --source "mission:test" "$TMP_DIR/obs.jsonl" > "$TMP_DIR/ingest.json"
[[ "$(jget "$TMP_DIR/ingest.json" 'd["ingested"]')" == "4" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/ingest.json" 'd["duplicates"]')" == "1" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/ingest.json" 'len(d["rejected"])')" == "1" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/ingest.json" 'd["rejected"][0]["reason"]')" == "missing evidence" ]] || assert_at $LINENO
[[ -f "$STORE_A/entries.json" ]] || assert_at $LINENO
[[ "$(stat -f '%Lp' "$STORE_A/entries.json" 2>/dev/null || stat -c '%a' "$STORE_A/entries.json")" == "600" ]] || assert_at $LINENO
FACT_ID="$(python3 -c 'import json,sys; e=json.load(open(sys.argv[1]))["entries"]; print(next(k for k,v in e.items() if v["type"]=="fact"))' "$STORE_A/entries.json")"
[[ "$(jget "$STORE_A/entries.json" "d['entries']['$FACT_ID']['seen']")" == "2" ]] || assert_at $LINENO
[[ "$(jget "$STORE_A/entries.json" "d['entries']['$FACT_ID']['source_checked']")" == "True" ]] || assert_at $LINENO
[[ "$(jget "$STORE_A/entries.json" "d['entries']['$FACT_ID']['status']")" == "active" ]] || assert_at $LINENO
[[ "$(jget "$STORE_A/entries.json" "d['entries']['$FACT_ID']['depends_on'][0].split('@')[0]")" == "lib/a.sh" ]] || assert_at $LINENO
HYP_ID="$(python3 -c 'import json,sys; e=json.load(open(sys.argv[1]))["entries"]; print(next(k for k,v in e.items() if v["type"]=="hypothesis"))' "$STORE_A/entries.json")"
[[ "$(jget "$STORE_A/entries.json" "d['entries']['$HYP_ID']['status']")" == "candidate" ]] || assert_at $LINENO
[[ "$(wc -l < "$STORE_A/observations.jsonl" | tr -d ' ')" == "5" ]] || assert_at $LINENO

# ── retrieve: scoped, traced, verified only ────────────────────────────────
mkdir -p "$REPO_A/.dex/memory/domains"
cat > "$REPO_A/.dex/memory/domains/ops.md" <<'DOMAIN'
# Ops

## M-001: Library scripts are sourced by zsh too

Domain: ops
Status: active
Scope: lib/
Applies to phases: implement, review
Applies to paths: lib/
Last verified: 2026-09-01
Recheck when: lib/common.sh changes how modules load

Lesson:
Do not use zsh-reserved names in lib/.

Evidence:
- tests/zsh-reserved-names.py

Future agent behavior:
- Run the reserved-names check.

## M-002: A candidate about lib

Domain: ops
Status: candidate
Scope: lib/
Applies to phases: implement
Applies to paths: lib/
Last verified: 2026-09-01
Recheck when: never

Lesson:
Unproven.

Evidence:
- none yet

Future agent behavior:
- none

## M-003: Docs are linted

Domain: ops
Status: active
Scope: docs/
Applies to phases: implement
Applies to paths: docs/
Last verified: 2026-09-01
Recheck when: the docs linter changes

Lesson:
Run the docs check.

Evidence:
- tests/docs-consistency-test.sh

Future agent behavior:
- Run it.
DOMAIN
printf '# Memory\n' > "$REPO_A/.dex/memory/index.md"
python3 "$STORE_PY" "$STORE_A" retrieve --repo "$REPO_A" --paths lib/a.sh,lib/b.sh --session s1 --role lead > "$TMP_DIR/retrieve.txt"
assert_contains "M-001" "$TMP_DIR/retrieve.txt"
assert_contains "zsh-reserved names" "$TMP_DIR/retrieve.txt"
assert_not_contains "M-002" "$TMP_DIR/retrieve.txt"
assert_not_contains "M-003" "$TMP_DIR/retrieve.txt"
assert_contains "lib/a.sh prints a" "$TMP_DIR/retrieve.txt"
assert_not_contains "3 workers" "$TMP_DIR/retrieve.txt"
assert_not_contains "90s" "$TMP_DIR/retrieve.txt"
[[ -s "$STORE_A/retrieval.log" ]] || assert_at $LINENO
TRACE="$(tail -1 "$STORE_A/retrieval.log")"
[[ "$(jline "$TRACE" 'd["session"]')" == "s1" ]] || assert_at $LINENO
[[ "$(jline "$TRACE" 'd["role"]')" == "lead" ]] || assert_at $LINENO
[[ "$(jline "$TRACE" '"M-001" in d["loaded"]')" == "True" ]] || assert_at $LINENO
[[ "$(jline "$TRACE" 'sorted(s["id"] for s in d["skipped"] if s["id"].startswith("M-"))')" == "['M-002', 'M-003']" ]] || assert_at $LINENO
[[ "$(jline "$TRACE" 'any(s["id"].startswith("obs:") and s["reason"] for s in d["skipped"])')" == "True" ]] || assert_at $LINENO

# No matching paths: nothing is loaded, and the trace says so.
python3 "$STORE_PY" "$STORE_A" retrieve --repo "$REPO_A" --paths README.md --session s2 --role lead > "$TMP_DIR/retrieve2.txt"
assert_not_contains "M-001" "$TMP_DIR/retrieve2.txt"
[[ "$(jline "$(tail -1 "$STORE_A/retrieval.log")" 'len(d["loaded"])')" == "0" ]] || assert_at $LINENO

# ── recheck: a changed dependency makes the entry stale, not wrong ─────────
printf 'echo b\n' > "$REPO_A/lib/a.sh"
python3 "$STORE_PY" "$STORE_A" recheck --repo "$REPO_A" > "$TMP_DIR/recheck.json"
[[ "$(jget "$TMP_DIR/recheck.json" "'$FACT_ID' in d['stale']")" == "True" ]] || assert_at $LINENO
[[ "$(jget "$STORE_A/entries.json" "d['entries']['$FACT_ID']['status']")" == "needs-recheck" ]] || assert_at $LINENO
python3 "$STORE_PY" "$STORE_A" retrieve --repo "$REPO_A" --paths lib/a.sh --session s3 --role lead > "$TMP_DIR/retrieve3.txt"
assert_not_contains "lib/a.sh prints a; the CLI entry is there" "$TMP_DIR/retrieve3.txt"
assert_contains "needs recheck" "$TMP_DIR/retrieve3.txt"
# Unrelated entries keep their status.
[[ "$(jget "$STORE_A/entries.json" "d['entries']['$HYP_ID']['status']")" == "candidate" ]] || assert_at $LINENO
# Restoring the file to its recorded content clears the stale mark.
git -C "$REPO_A" checkout -q -- lib/a.sh
python3 "$STORE_PY" "$STORE_A" recheck --repo "$REPO_A" > "$TMP_DIR/recheck2.json"
[[ "$(jget "$STORE_A/entries.json" "d['entries']['$FACT_ID']['status']")" == "active" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/recheck2.json" "'$FACT_ID' in d['restored']")" == "True" ]] || assert_at $LINENO

# ── isolation: repository B sees none of A's knowledge ─────────────────────
python3 "$STORE_PY" "$STORE_B" retrieve --repo "$REPO_B" --paths lib/a.sh --session s4 --role lead > "$TMP_DIR/retrieve-b.txt"
assert_not_contains "lib/a.sh prints a" "$TMP_DIR/retrieve-b.txt"
assert_not_contains "M-001" "$TMP_DIR/retrieve-b.txt"

# ── a bad store line is reported, not silently skipped ─────────────────────
printf 'not json\n' >> "$STORE_A/observations.jsonl"
set +e
python3 "$STORE_PY" "$STORE_A" verify > "$TMP_DIR/verify.out" 2>&1
RC=$?
set -e
[[ "$RC" == "1" ]] || assert_at $LINENO

# ── the mission hooks feed the store ───────────────────────────────────────
SID="memory-store-session"
printf 'Build.\n' > "$TMP_DIR/brief.md"
bash "$ROOT/bin/mission.sh" "$SID" init --mission-id m-mem --brief-file "$TMP_DIR/brief.md" \
  --workspace "$REPO_B" --branch main --base-revision "$(git -C "$REPO_B" rev-parse HEAD)" > /dev/null
# The lead submits a verified fact directly: ledger reference plus store entry.
(cd "$REPO_B" && bash "$ROOT/bin/mission.sh" "$SID" observe --actor lead \
  --json '{"lesson":"docs/x.md is the docs index","evidence":"docs/x.md","scope":"repo","type":"fact"}' > /dev/null)
[[ "$(jget "$DX_STATE_DIR/$SID.mission/current.json" 'd["counts"]["observation-ref"]')" == "1" ]] || assert_at $LINENO
python3 "$STORE_PY" "$STORE_B" retrieve --repo "$REPO_B" --paths docs/x.md --session s5 --role lead > "$TMP_DIR/retrieve-b2.txt"
assert_contains "docs/x.md is the docs index" "$TMP_DIR/retrieve-b2.txt"
# A helper's observations (written by the SubagentStop hook into the mission
# overlay) reach the store when the session ends.
printf '%s\n' '{"lesson":"lib/a.sh is sourced by the CLI","evidence":"lib/a.sh","scope":"repo","type":"fact","recorded_at":"2026-10-01T00:00:00Z","agent_id":"impl-1","agent_type":"dx-implementer","revision":"x","trust":"candidate"}' \
  > "$DX_STATE_DIR/$SID.mission/observations.jsonl"
chmod 600 "$DX_STATE_DIR/$SID.mission/observations.jsonl"
printf 'start:1\n' > "$(dx_times_file "$SID")"
(cd "$REPO_B" && printf '{"session_id":"c9"}' | DX_MISSION_ACTIVE=1 DEX_SESSION_ID="$SID" bash "$ROOT/hooks/session-end.sh" > /dev/null)
python3 "$STORE_PY" "$STORE_B" retrieve --repo "$REPO_B" --paths lib/a.sh --session s6 --role lead > "$TMP_DIR/retrieve-b3.txt"
assert_contains "lib/a.sh is sourced by the CLI" "$TMP_DIR/retrieve-b3.txt"
# Ending the session again does not ingest the same observations twice.
(cd "$REPO_B" && printf '{"session_id":"c9"}' | DX_MISSION_ACTIVE=1 DEX_SESSION_ID="$SID" bash "$ROOT/hooks/session-end.sh" > /dev/null)
[[ "$(python3 -c 'import json,sys; e=json.load(open(sys.argv[1]))["entries"]; print(sum(1 for v in e.values() if "sourced by the CLI" in v["lesson"]))' "$STORE_B/entries.json")" == "1" ]] || assert_at $LINENO

echo "memory-store-test: ok"
