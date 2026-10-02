#!/usr/bin/env bash
set -euo pipefail

# `dx memory curate` is the critical review of the memory store, run by a
# fresh bounded model session and applied by the deterministic layer. It runs
# maintenance first, asks the model only when a review is due (or forced),
# accepts exactly one fenced JSON block of decisions, and leaves the store
# unchanged when the model's answer is unusable. The lifecycle calls the same
# path at completion; it never writes to tracked files.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-memory-curate-test.XXXXXX")"
cleanup() { chmod -R u+w "$TMP_DIR" 2>/dev/null || true; rm -rf "$TMP_DIR"; }
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_RUN_ROOT="$TMP_DIR/runs"
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR" "$DX_RUN_ROOT" "$TMP_DIR/bin"
export DX_MEMORY_STORE_DIR="$TMP_DIR/store"

jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }
# The store's content apart from the maintenance stamp, which every curate run refreshes.
fingerprint() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d.pop("last_maintained_at", None); print(json.dumps(d, sort_keys=True))' "$ENTRIES" | shasum; }

REPO="$TMP_DIR/repo"
mkdir -p "$REPO/lib" "$REPO/.dex"
git init -q -b main "$REPO"
git -C "$REPO" config user.email "dex@example.com"
git -C "$REPO" config user.name "Dex Test"
printf 'echo a\n' > "$REPO/lib/a.sh"
printf '# dex\n' > "$REPO/.dex/dex.md"
git -C "$REPO" add .
git -C "$REPO" -c commit.gpgsign=false commit -q -m "init"
SHA="$(git -C "$REPO" rev-parse HEAD)"

STORE_PY="$ROOT/scripts/memory_store.py"
ENTRIES="$DX_MEMORY_STORE_DIR/entries.json"
cat > "$TMP_DIR/obs.jsonl" <<OBS
{"lesson":"lib/a.sh prints a and is the entry point","evidence":"lib/a.sh@${SHA}","scope":"repo","type":"fact"}
{"lesson":"a second fact about lib/a.sh for the curator","evidence":"lib/a.sh@${SHA} line 1","scope":"repo","type":"fact"}
{"lesson":"the suite might be faster with three workers","evidence":"one run took 40s","scope":"repo","type":"hypothesis"}
OBS
python3 "$STORE_PY" "$DX_MEMORY_STORE_DIR" ingest --repo "$REPO" --source "mission:s1" "$TMP_DIR/obs.jsonl" > /dev/null
id_of() { python3 - "$ENTRIES" "$1" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for identity, entry in data["entries"].items():
    if entry["lesson"].startswith(sys.argv[2]):
        print(identity); break
PY
}
FIRST="$(id_of "lib/a.sh prints a")"
SECOND="$(id_of "a second fact")"
HYPO="$(id_of "the suite might")"
[[ -n "$FIRST" && -n "$SECOND" && -n "$HYPO" ]] || assert_at $LINENO

# A stand-in for the curator model: records what it was asked, answers from a file.
CALLS="$TMP_DIR/curator-calls.log"
cat > "$TMP_DIR/bin/curator" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$CALLS"
cat > "$TMP_DIR/curator-prompt.txt"
cat "$TMP_DIR/curator-answer.txt"
EOF
chmod 700 "$TMP_DIR/bin/curator"
export DX_MEMORY_CURATOR_BIN="$TMP_DIR/bin/curator"

# ── help and bad usage ────────────────────────────────────────────────────
bash "$ROOT/bin/memory.sh" --help > "$TMP_DIR/help.out" 2>&1 || assert_at $LINENO
assert_contains "Usage: dx memory" "$TMP_DIR/help.out"
if bash "$ROOT/bin/memory.sh" --repo "$REPO" frobnicate > "$TMP_DIR/bad.out" 2>&1; then
  assert_at $LINENO
fi

# ── not due: maintenance runs, the model is not called ────────────────────
bash "$ROOT/bin/memory.sh" --repo "$REPO" curate --min-changes 10 > "$TMP_DIR/notdue.out" 2>&1 || assert_at $LINENO
assert_contains "not due" "$TMP_DIR/notdue.out"
[[ ! -f "$CALLS" ]] || assert_at $LINENO
[[ -n "$(jget "$ENTRIES" "d.get('last_maintained_at','')")" ]] || assert_at $LINENO

# ── forced: the model is asked, its decisions are applied ─────────────────
cat > "$TMP_DIR/curator-answer.txt" <<EOF
I read the store and the source.

\`\`\`json
{"decisions": [
  {"id": "obs:$FIRST", "action": "promote", "reason": "verified against lib/a.sh; the entry point question comes up in every task"},
  {"id": "obs:$SECOND", "action": "merge", "into": "obs:$FIRST", "reason": "same file, same fact, two phrasings"},
  {"id": "obs:$HYPO", "action": "retire", "reason": "one timing is not evidence; nothing acted on it"}
]}
\`\`\`
EOF
bash "$ROOT/bin/memory.sh" --repo "$REPO" curate --force --max-turns 3 > "$TMP_DIR/forced.out" 2>&1 || assert_at $LINENO
[[ -f "$CALLS" && "$(wc -l < "$CALLS" | tr -d ' ')" == "1" ]] || assert_at $LINENO
assert_contains "--max-turns 3" "$CALLS"
assert_contains "-p " "$CALLS"
# The curator may read but not change anything.
assert_contains "--allowedTools Read,Grep,Glob" "$CALLS"
assert_contains "--disallowedTools Edit,Write,NotebookEdit,Bash,Agent" "$CALLS"
assert_contains "obs:$FIRST" "$TMP_DIR/curator-prompt.txt"
assert_contains "earn its keep" "$TMP_DIR/curator-prompt.txt"
assert_contains "applied 3" "$TMP_DIR/forced.out"
[[ "$(jget "$ENTRIES" "d['entries']['$FIRST'].get('curated')")" == "True" ]] || assert_at $LINENO
[[ "$(jget "$ENTRIES" "d['entries']['$SECOND']['status']")" == "retired" ]] || assert_at $LINENO
[[ "$(jget "$ENTRIES" "d['entries']['$HYPO']['status']")" == "retired" ]] || assert_at $LINENO
[[ -n "$(jget "$ENTRIES" "d.get('last_curated_at','')")" ]] || assert_at $LINENO
[[ -z "$(git -C "$REPO" status --porcelain)" ]] || assert_at $LINENO

# ── dry run: the model is asked, nothing is applied ───────────────────────
BEFORE="$(fingerprint)"
cat > "$TMP_DIR/curator-answer.txt" <<EOF
\`\`\`json
{"decisions": [{"id": "obs:$FIRST", "action": "retire", "reason": "a dry run must not apply this"}]}
\`\`\`
EOF
bash "$ROOT/bin/memory.sh" --repo "$REPO" curate --force --dry-run > "$TMP_DIR/dry.out" 2>&1 || assert_at $LINENO
assert_contains "dry run" "$TMP_DIR/dry.out"
[[ "$(fingerprint)" == "$BEFORE" ]] || assert_at $LINENO
[[ "$(jget "$ENTRIES" "d['entries']['$FIRST']['status']")" == "active" ]] || assert_at $LINENO

# ── unusable answer: no fenced block, store unchanged, non-zero exit ──────
printf 'I could not decide.\n' > "$TMP_DIR/curator-answer.txt"
if bash "$ROOT/bin/memory.sh" --repo "$REPO" curate --force > "$TMP_DIR/unusable.out" 2>&1; then
  assert_at $LINENO
fi
assert_contains "no decisions" "$TMP_DIR/unusable.out"
[[ "$(fingerprint)" == "$BEFORE" ]] || assert_at $LINENO

# ── the curator binary failing leaves the store unchanged ─────────────────
cat > "$TMP_DIR/bin/curator" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
chmod 700 "$TMP_DIR/bin/curator"
if bash "$ROOT/bin/memory.sh" --repo "$REPO" curate --force > "$TMP_DIR/fail.out" 2>&1; then
  assert_at $LINENO
fi
[[ "$(fingerprint)" == "$BEFORE" ]] || assert_at $LINENO

# ── show and maintain subcommands ─────────────────────────────────────────
bash "$ROOT/bin/memory.sh" --repo "$REPO" show > "$TMP_DIR/show.out" 2>&1 || assert_at $LINENO
assert_contains "$FIRST" "$TMP_DIR/show.out"
bash "$ROOT/bin/memory.sh" --repo "$REPO" maintain > "$TMP_DIR/maintain.out" 2>&1 || assert_at $LINENO
assert_contains "retired" "$TMP_DIR/maintain.out"

# ── the library entry point the lifecycle uses: quiet when not due ────────
# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"
# shellcheck disable=SC1091
source "$ROOT/lib/memory.sh"
rm -f "$CALLS"
dx_memory_curate_if_due "$REPO" > "$TMP_DIR/ifdue.out" 2>&1 || assert_at $LINENO
[[ ! -f "$CALLS" ]] || assert_at $LINENO
DEX_MEMORY_CURATE=0 dx_memory_curate_if_due "$REPO" --force > "$TMP_DIR/off.out" 2>&1 || assert_at $LINENO
[[ ! -f "$CALLS" ]] || assert_at $LINENO

printf 'memory curate tests passed\n'
