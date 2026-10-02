#!/usr/bin/env bash
set -euo pipefail

# Trusted memory lands in the repository on its own. `materialize` renders the
# curator-promoted store entries into `.dex/memory/domains/<domain>.md` and the
# index, and applies the overlay's status decisions to existing entries, as
# itemised edits. `dx memory land` does that in a throwaway worktree on a
# `dex/memory-*` branch, commits, pushes and opens an auto-merging PR when
# there is a remote; `--in-place` writes into the checkout for dx sync. The
# store remembers what landed so nothing lands twice, and retrieval serves the
# tracked entry instead of the store copy once it is in the checkout.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/dex-memory-land-test.XXXXXX")" && pwd -P)"
cleanup() { chmod -R u+w "$TMP_DIR" 2>/dev/null || true; rm -rf "$TMP_DIR"; }
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_RUN_ROOT="$TMP_DIR/runs"
export DX_MEMORY_STORE_DIR="$TMP_DIR/store"
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR" "$DX_RUN_ROOT" "$TMP_DIR/bin"
# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"
# shellcheck disable=SC1091
source "$ROOT/lib/memory.sh"
STORE_PY="$ROOT/scripts/memory_store.py"
ENTRIES="$DX_MEMORY_STORE_DIR/entries.json"

jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }
jline() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$1" "$2"; }
store() { python3 "$STORE_PY" "$DX_MEMORY_STORE_DIR" "$@"; }

# A repository with a bare origin and one curated memory domain.
ORIGIN="$TMP_DIR/origin.git"
git init -q --bare -b main "$ORIGIN"
REPO="$TMP_DIR/repo"
mkdir -p "$REPO/lib" "$REPO/.dex/memory/domains"
git init -q -b main "$REPO"
git -C "$REPO" config user.email "dex@example.com"
git -C "$REPO" config user.name "Dex Test"
git -C "$REPO" config commit.gpgsign false
printf 'echo a\n' > "$REPO/lib/a.sh"
printf 'echo b\n' > "$REPO/lib/b.sh"
printf '# dex\n' > "$REPO/.dex/dex.md"
cat > "$REPO/.dex/memory/index.md" <<'MD'
# Dex Memory Index

Read this first, then load only matching entries.

## Domains

| Domain | File | Loads For | Status |
|--------|------|-----------|--------|
| ops | domains/ops.md | Operating the scripts under lib/ | active |

## Entries

| ID | Domain | Summary |
|----|--------|---------|
| M-001 | ops | lib/a.sh is the entry point |

## Retrieval Rules

- Load only entries with `Status: active` whose scope matches the task.
MD
cat > "$REPO/.dex/memory/domains/ops.md" <<'MD'
# Ops

## M-001: lib/a.sh is the entry point
Domain: ops
Status: active
Scope: lib/a.sh
Applies to phases: implement
Applies to paths: lib/a.sh
Last verified: 2026-09-01
Recheck when: lib/a.sh changes
Depends on: lib/a.sh

Lesson:
Start from lib/a.sh.

Evidence:
- lib/a.sh
MD
git -C "$REPO" add .
git -C "$REPO" commit -q -m "init"
git -C "$REPO" remote add origin "$ORIGIN"
git -C "$REPO" push -q -u origin main
BLOB_B="$(git -C "$REPO" hash-object lib/b.sh)"
SHA="$(git -C "$REPO" rev-parse HEAD)"

cat > "$TMP_DIR/obs.jsonl" <<OBS
{"lesson":"lib/b.sh prints b; run it before lib/a.sh when both change","evidence":"lib/b.sh@${SHA}","scope":"repo","type":"procedure"}
{"lesson":"the tooling wrapper expects lib/b.sh to be executable","evidence":"lib/b.sh@${SHA} mode bits","scope":"repo","type":"fact"}
{"lesson":"an entry nobody promoted stays in the store","evidence":"lib/b.sh@${SHA}","scope":"repo","type":"fact"}
OBS
store ingest --repo "$REPO" --source "mission:s1" "$TMP_DIR/obs.jsonl" > /dev/null
id_of() { python3 - "$ENTRIES" "$1" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for identity, entry in data["entries"].items():
    if entry["lesson"].startswith(sys.argv[2]):
        print(identity); break
PY
}
FIRST="$(id_of "lib/b.sh prints b")"
SECOND="$(id_of "the tooling wrapper")"
THIRD="$(id_of "an entry nobody")"
[[ -n "$FIRST" && -n "$SECOND" && -n "$THIRD" ]] || assert_at $LINENO

cat > "$TMP_DIR/decisions.json" <<JSON
{"decisions": [
  {"id": "obs:$FIRST", "action": "promote", "domain": "ops", "reason": "verified against lib/b.sh; the order matters in every task touching both"},
  {"id": "obs:$SECOND", "action": "promote", "domain": "tooling", "reason": "verified mode bits; a new domain for the wrapper"},
  {"id": "M-001", "action": "retire", "reason": "lib/a.sh is no longer the entry point; lib/b.sh runs first"}
]}
JSON
store curate-apply --repo "$REPO" --actor "curator:test" "$TMP_DIR/decisions.json" > "$TMP_DIR/apply.out"
[[ "$(jget "$ENTRIES" "d['entries']['$FIRST'].get('domain')")" == "ops" ]] || assert_at $LINENO
[[ "$(jget "$ENTRIES" "d['entries']['$SECOND'].get('domain')")" == "tooling" ]] || assert_at $LINENO

# ── materialize without --write: the plan, and nothing touched ─────────────
PLAN="$(store materialize --repo "$REPO" --out-repo "$REPO" --now 2026-10-01T12:00:00Z)"
[[ "$(jline "$PLAN" "[l['id'] for l in d['landed']]")" == "['M-002', 'M-003']" ]] || assert_at $LINENO
[[ "$(jline "$PLAN" "[l['store_id'] for l in d['landed']]")" == "['$FIRST', '$SECOND']" ]] || assert_at $LINENO
[[ "$(jline "$PLAN" "[l['domain'] for l in d['landed']]")" == "['ops', 'tooling']" ]] || assert_at $LINENO
[[ "$(jline "$PLAN" "[(c['id'], c['status']) for c in d['status_changes']]")" == "[('M-001', 'retired')]" ]] || assert_at $LINENO
[[ "$(jline "$PLAN" "sorted(d['files'])")" == "['.dex/memory/domains/ops.md', '.dex/memory/domains/tooling.md', '.dex/memory/index.md']" ]] || assert_at $LINENO
[[ -z "$(git -C "$REPO" status --porcelain)" ]] || assert_at $LINENO

# ── land on a branch: the checkout is untouched, the branch carries the diff ─
bash "$ROOT/bin/memory.sh" --repo "$REPO" land --no-pr > "$TMP_DIR/land1.out" 2>&1 || { cat "$TMP_DIR/land1.out" >&2; assert_at $LINENO; }
assert_contains "landed 2" "$TMP_DIR/land1.out"
[[ -z "$(git -C "$REPO" status --porcelain)" ]] || assert_at $LINENO
BRANCH="$(git -C "$REPO" for-each-ref --format='%(refname:short)' 'refs/heads/dex/memory-*' | head -1)"
[[ -n "$BRANCH" ]] || { cat "$TMP_DIR/land1.out" >&2; assert_at $LINENO; }
[[ "$(git -C "$REPO" rev-list --count "main..$BRANCH")" == "1" ]] || assert_at $LINENO
SUBJECT="$(git -C "$REPO" log -1 --format=%s "$BRANCH")"
[[ "$SUBJECT" == "chore(memory): "* ]] || assert_at $LINENO
LAND_SHA="$(git -C "$REPO" rev-parse "$BRANCH")"
[[ "$(git -C "$REPO" diff --name-only "main..$BRANCH" | sort | tr '\n' ' ')" == ".dex/memory/domains/ops.md .dex/memory/domains/tooling.md .dex/memory/index.md " ]] || assert_at $LINENO
# The worktree used for landing is gone; only the branch remains.
[[ "$(git -C "$REPO" worktree list | wc -l | tr -d ' ')" == "1" ]] || assert_at $LINENO
# The store remembers what landed and where.
[[ "$(jget "$ENTRIES" "d['entries']['$FIRST']['landed']['id']")" == "M-002" ]] || assert_at $LINENO
[[ "$(jget "$ENTRIES" "d['entries']['$FIRST']['landed']['commit']")" == "$LAND_SHA" ]] || assert_at $LINENO
[[ "$(jget "$ENTRIES" "d['entries']['$SECOND']['landed']['id']")" == "M-003" ]] || assert_at $LINENO
[[ "$(jget "$ENTRIES" "'landed' in d['entries']['$THIRD']")" == "False" ]] || assert_at $LINENO
[[ "$(jget "$DX_MEMORY_STORE_DIR/curated-overlay.json" "d['M-001'].get('landed_commit')")" == "$LAND_SHA" ]] || assert_at $LINENO

# Nothing lands twice.
bash "$ROOT/bin/memory.sh" --repo "$REPO" land --no-pr > "$TMP_DIR/land2.out" 2>&1 || assert_at $LINENO
assert_contains "nothing to land" "$TMP_DIR/land2.out"
[[ "$(git -C "$REPO" for-each-ref 'refs/heads/dex/memory-*' | wc -l | tr -d ' ')" == "1" ]] || assert_at $LINENO

# ── the rendered entries, read back after the branch merges ────────────────
git -C "$REPO" merge -q --no-edit "$BRANCH"
# Landing branches from the default branch's upstream, as a real repo would
# after the auto-merge; keep the fixture's origin in step.
git -C "$REPO" push -q origin main
OPS="$REPO/.dex/memory/domains/ops.md"
assert_contains "## M-002: " "$OPS"
assert_contains "Depends on: lib/b.sh@${BLOB_B}" "$OPS"
assert_contains "Applies to paths: lib/b.sh" "$OPS"
assert_contains "Last verified: 2026-" "$OPS"
assert_contains "run it before lib/a.sh when both change" "$OPS"
assert_contains "Source: dex memory store obs:$FIRST" "$OPS"
# The retired entry kept its block; only its status changed.
python3 - "$OPS" <<'PY' || assert_at $LINENO
import re, sys
text = open(sys.argv[1]).read()
block = text.split("## M-001:")[1].split("## M-002:")[0]
assert "Status: retired" in block, block
assert "Lesson:\nStart from lib/a.sh." in block, block
assert text.count("## M-001:") == 1 and text.count("## M-002:") == 1
PY
TOOLING="$REPO/.dex/memory/domains/tooling.md"
[[ -f "$TOOLING" ]] || assert_at $LINENO
assert_contains "## M-003: " "$TOOLING"
assert_contains "Domain: tooling" "$TOOLING"
INDEX="$REPO/.dex/memory/index.md"
assert_contains "| M-002 | ops | " "$INDEX"
assert_contains "| M-003 | tooling | " "$INDEX"
assert_contains "| tooling | domains/tooling.md | " "$INDEX"
[[ "$(grep -c '^| M-001 ' "$INDEX")" == "1" ]] || assert_at $LINENO
# Rows land inside the Entries table, before the Retrieval Rules.
python3 - "$INDEX" <<'PY' || assert_at $LINENO
import sys
text = open(sys.argv[1]).read()
assert text.index("| M-003 |") < text.index("## Retrieval Rules")
PY

# Retrieval now serves the tracked entry and skips the store copy.
store retrieve --repo "$REPO" --paths lib/b.sh --session t1 --role lead > "$TMP_DIR/r1.out"
assert_contains "[M-002]" "$TMP_DIR/r1.out"
! grep -q "obs:$FIRST" "$TMP_DIR/r1.out" || assert_at $LINENO
assert_contains "obs:$THIRD" "$TMP_DIR/r1.out"
LAST_TRACE="$(tail -1 "$DX_MEMORY_STORE_DIR/retrieval.log")"
[[ "$(jline "$LAST_TRACE" "[s['reason'] for s in d['skipped'] if s['id']=='obs:$FIRST']")" == "['landed as M-002']" ]] || assert_at $LINENO
# M-001 is retired in the tracked file now, not only in the overlay.
! grep -q "M-001" "$TMP_DIR/r1.out" || assert_at $LINENO

# ── with a remote and gh: push, PR, auto-merge requested ───────────────────
GH_LOG="$TMP_DIR/gh.log"
cat > "$TMP_DIR/bin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_LOG"
if [[ "\$1" == "pr" && "\$2" == "create" ]]; then printf 'https://example.test/pr/7\n'; fi
exit 0
SH
chmod 700 "$TMP_DIR/bin/gh"
export DX_MEMORY_GH_BIN="$TMP_DIR/bin/gh"
printf '{"lesson":"a fourth lesson about lib/b.sh for the remote run","evidence":"lib/b.sh@%s","scope":"repo","type":"fact"}\n' "$SHA" > "$TMP_DIR/obs2.jsonl"
store ingest --repo "$REPO" --source "mission:s2" "$TMP_DIR/obs2.jsonl" > /dev/null
FOURTH="$(id_of "a fourth lesson")"
printf '{"decisions": [{"id": "obs:%s", "action": "promote", "domain": "ops", "reason": "verified for the remote landing case"}]}\n' "$FOURTH" > "$TMP_DIR/d2.json"
store curate-apply --repo "$REPO" --actor "curator:test" "$TMP_DIR/d2.json" > /dev/null
bash "$ROOT/bin/memory.sh" --repo "$REPO" land > "$TMP_DIR/land3.out" 2>&1 || { cat "$TMP_DIR/land3.out" >&2; assert_at $LINENO; }
assert_contains "landed 1" "$TMP_DIR/land3.out"
assert_contains "https://example.test/pr/7" "$TMP_DIR/land3.out"
BRANCH3="$(git -C "$REPO" for-each-ref --format='%(refname:short)' --sort=-creatordate 'refs/heads/dex/memory-*' | head -1)"
[[ "$BRANCH3" != "$BRANCH" ]] || assert_at $LINENO
git -C "$ORIGIN" rev-parse --verify -q "refs/heads/$BRANCH3" > /dev/null || assert_at $LINENO
assert_contains "pr create" "$GH_LOG"
assert_contains "--base main" "$GH_LOG"
assert_contains "pr merge" "$GH_LOG"
assert_contains "--auto" "$GH_LOG"
[[ "$(jget "$ENTRIES" "d['entries']['$FOURTH']['landed']['id']")" == "M-004" ]] || assert_at $LINENO
[[ "$(jget "$ENTRIES" "d['entries']['$FOURTH']['landed'].get('pr')")" == "https://example.test/pr/7" ]] || assert_at $LINENO

# ── --dry-run prints the plan and creates nothing ──────────────────────────
printf '{"lesson":"a fifth lesson about lib/b.sh for the dry run","evidence":"lib/b.sh@%s","scope":"repo","type":"fact"}\n' "$SHA" > "$TMP_DIR/obs3.jsonl"
store ingest --repo "$REPO" --source "mission:s3" "$TMP_DIR/obs3.jsonl" > /dev/null
FIFTH="$(id_of "a fifth lesson")"
printf '{"decisions": [{"id": "obs:%s", "action": "promote", "domain": "ops", "reason": "verified for the dry-run case"}]}\n' "$FIFTH" > "$TMP_DIR/d3.json"
store curate-apply --repo "$REPO" --actor "curator:test" "$TMP_DIR/d3.json" > /dev/null
BRANCHES_BEFORE="$(git -C "$REPO" for-each-ref 'refs/heads/dex/memory-*' | wc -l | tr -d ' ')"
bash "$ROOT/bin/memory.sh" --repo "$REPO" land --dry-run > "$TMP_DIR/land4.out" 2>&1 || assert_at $LINENO
assert_contains "dry run" "$TMP_DIR/land4.out"
assert_contains "M-005" "$TMP_DIR/land4.out"
[[ "$(git -C "$REPO" for-each-ref 'refs/heads/dex/memory-*' | wc -l | tr -d ' ')" == "$BRANCHES_BEFORE" ]] || assert_at $LINENO
[[ "$(jget "$ENTRIES" "'landed' in d['entries']['$FIFTH']")" == "False" ]] || assert_at $LINENO

# ── --in-place writes into the checkout for dx sync to publish ─────────────
bash "$ROOT/bin/memory.sh" --repo "$REPO" land --in-place > "$TMP_DIR/land5.out" 2>&1 || { cat "$TMP_DIR/land5.out" >&2; assert_at $LINENO; }
assert_contains "landed 1" "$TMP_DIR/land5.out"
[[ -n "$(git -C "$REPO" status --porcelain -- .dex/memory)" ]] || assert_at $LINENO
assert_contains "## M-005: " "$OPS"
[[ "$(jget "$ENTRIES" "d['entries']['$FIFTH']['landed']['commit']")" == "working-tree" ]] || assert_at $LINENO
[[ "$(git -C "$REPO" for-each-ref 'refs/heads/dex/memory-*' | wc -l | tr -d ' ')" == "$BRANCHES_BEFORE" ]] || assert_at $LINENO
# If that working-tree change is thrown away, the entry is free to land again.
git -C "$REPO" checkout -q -- .dex/memory
store recheck --repo "$REPO" > /dev/null
[[ "$(jget "$ENTRIES" "'landed' in d['entries']['$FIFTH']")" == "False" ]] || assert_at $LINENO
# A landing that reached a commit is not reopened by a recheck.
[[ "$(jget "$ENTRIES" "d['entries']['$FOURTH']['landed']['id']")" == "M-004" ]] || assert_at $LINENO

# ── a repository without a remote lands on a local branch and says so ──────
LOCAL="$TMP_DIR/local"
mkdir -p "$LOCAL/lib" "$LOCAL/.dex/memory/domains"
git init -q -b main "$LOCAL"
git -C "$LOCAL" config user.email "dex@example.com"
git -C "$LOCAL" config user.name "Dex Test"
git -C "$LOCAL" config commit.gpgsign false
printf 'echo c\n' > "$LOCAL/lib/c.sh"
printf '# Index\n\n## Domains\n\n| Domain | File | Loads For | Status |\n|--------|------|-----------|--------|\n\n## Entries\n\n| ID | Domain | Summary |\n|----|--------|---------|\n' > "$LOCAL/.dex/memory/index.md"
git -C "$LOCAL" add . && git -C "$LOCAL" commit -q -m init
LOCAL_SHA="$(git -C "$LOCAL" rev-parse HEAD)"
export DX_MEMORY_STORE_DIR="$TMP_DIR/store-local"
printf '{"lesson":"lib/c.sh prints c in the local-only repo","evidence":"lib/c.sh@%s","scope":"repo","type":"fact"}\n' "$LOCAL_SHA" > "$TMP_DIR/obs4.jsonl"
store ingest --repo "$LOCAL" --source "mission:s4" "$TMP_DIR/obs4.jsonl" > /dev/null
LOCAL_ID="$(python3 -c 'import json,sys; print(list(json.load(open(sys.argv[1]))["entries"])[0])' "$DX_MEMORY_STORE_DIR/entries.json")"
printf '{"decisions": [{"id": "obs:%s", "action": "promote", "domain": "ops", "reason": "verified in the local-only repository"}]}\n' "$LOCAL_ID" > "$TMP_DIR/d4.json"
store curate-apply --repo "$LOCAL" --actor "curator:test" "$TMP_DIR/d4.json" > /dev/null
rm -f "$GH_LOG"
bash "$ROOT/bin/memory.sh" --repo "$LOCAL" land > "$TMP_DIR/land6.out" 2>&1 || { cat "$TMP_DIR/land6.out" >&2; assert_at $LINENO; }
assert_contains "landed 1" "$TMP_DIR/land6.out"
assert_contains "no remote" "$TMP_DIR/land6.out"
[[ ! -e "$GH_LOG" ]] || assert_at $LINENO
[[ "$(git -C "$LOCAL" for-each-ref 'refs/heads/dex/memory-*' | wc -l | tr -d ' ')" == "1" ]] || assert_at $LINENO
LB="$(git -C "$LOCAL" for-each-ref --format='%(refname:short)' 'refs/heads/dex/memory-*')"
git -C "$LOCAL" merge -q --no-edit "$LB"
[[ -f "$LOCAL/.dex/memory/domains/ops.md" ]] || assert_at $LINENO
assert_contains "## M-001: " "$LOCAL/.dex/memory/domains/ops.md"

# ── the library entry point the lifecycle uses ─────────────────────────────
# The fifth entry's in-place landing was thrown away above, so it lands again.
export DX_MEMORY_STORE_DIR="$TMP_DIR/store"
dx_memory_land "$REPO" --no-pr > "$TMP_DIR/land7.out" 2>&1 || assert_at $LINENO
assert_contains "landed 1" "$TMP_DIR/land7.out"
[[ "$(jget "$ENTRIES" "d['entries']['$FIFTH']['landed']['id']")" == "M-005" ]] || assert_at $LINENO
dx_memory_land "$REPO" --no-pr > "$TMP_DIR/land7b.out" 2>&1 || assert_at $LINENO
assert_contains "nothing to land" "$TMP_DIR/land7b.out"
DEX_MEMORY_LAND=0 dx_memory_land "$REPO" --no-pr > "$TMP_DIR/land8.out" 2>&1 || assert_at $LINENO
[[ ! -s "$TMP_DIR/land8.out" ]] || assert_at $LINENO

printf 'memory land tests passed\n'
