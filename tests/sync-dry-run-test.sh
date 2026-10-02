#!/usr/bin/env bash
set -euo pipefail

# `dx sync --dry-run` and `--trace-retrieval` promise not to write, but the
# provider runs with permissions bypassed, so the promise rested on the model
# reading the prompt. sync.sh now snapshots the repository before and after the
# provider and fails, naming the paths, when anything changed. Nothing is
# reverted. The state directory the prompt reads raw observations from also
# gets a real default instead of a "Dex-managed directory" nothing defined.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-sync-dry-run-test.XXXXXX")"
REAL_BASH=$(command -v bash)
cleanup() { chmod -R u+w "$TMP_DIR" 2>/dev/null || true; rm -rf "$TMP_DIR"; }
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export CODEX_HOME="$HOME/.codex"
export DEX_DIR="$ROOT"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_RTK_ENABLED=0
export DX_RUN_ROOT="$TMP_DIR/runs"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_TOOL_DIR="$TMP_DIR/tools"
export DX_PROVIDER_PROFILE=codex-subscription
export DEXCODE_SYNC=0
export TEST_CODEX_LOG="$TMP_DIR/codex.log"
export TEST_CODEX_WRITE=""
mkdir -p "$HOME" "$TMP_DIR/bin"

# The provider stub logs its argv (the prompt is the last argument). When
# TEST_CODEX_WRITE names a file it appends a line to it, which is what a
# provider that ignored the dry-run contract would do.
cat > "$TMP_DIR/bin/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_CODEX_LOG"
if [[ "${1:-}" == "login" && "${2:-}" == "status" ]]; then
  printf '%s\n' "Logged in with ChatGPT"
  exit 0
fi
if [[ "${1:-}" == "exec" && "${2:-}" == "--help" ]]; then
  printf '%s\n' "--ignore-user-config" "--dangerously-bypass-approvals-and-sandbox"
  exit 0
fi
if [[ "${1:-}" == "exec" && "${2:-}" == "review" && "${3:-}" == "--help" ]]; then
  printf '%s\n' "--ignore-user-config" "--dangerously-bypass-approvals-and-sandbox"
  exit 0
fi
if [[ "${1:-}" == "exec" && -n "${TEST_CODEX_WRITE:-}" ]]; then
  mkdir -p "$(dirname "$TEST_CODEX_WRITE")"
  printf '%s\n' "written by a provider that ignored the dry run" >> "$TEST_CODEX_WRITE"
fi
exit 0
SH
chmod +x "$TMP_DIR/bin/codex"

# Keep the tooling bootstrap away from real installers and registries.
ln -s "$(command -v python3)" "$TMP_DIR/bin/python3"
export PATH="$TMP_DIR/bin:/usr/bin:/bin:/usr/sbin:/sbin"

make_repo() {
  local repo="$1"
  git init -q "$repo"
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name Test
  git -C "$repo" config commit.gpgsign false
  printf '%s\n' '# Repo' > "$repo/README.md"
  mkdir -p "$repo/.dex/rules" "$repo/.dex/memory/domains"
  printf '%s\n' '# Dex' '## Tech Stack' 'Shell' '## Quality Gates' 'Tests' '## Project Structure' 'Repository' > "$repo/.dex/dex.md"
  printf '%s\n' '# Rule' > "$repo/.dex/rules/base.md"
  printf '%s\n' '# Dex Memory Index' > "$repo/.dex/memory/index.md"
  printf '%s\n' '# review-quality' > "$repo/.dex/memory/domains/review-quality.md"
  git -C "$repo" add .
  git -C "$repo" commit -qm init
}

# run_sync <repo> <out> [sync args…]; the exit code lands in SYNC_RC.
SYNC_RC=0
run_sync() {
  local repo="$1" out="$2"
  shift 2
  set +e
  (cd "$repo" && "$REAL_BASH" "$ROOT/bin/sync.sh" "$@") > "$out" 2>&1
  SYNC_RC=$?
  set -e
}

# The same key sync.sh derives, computed the same way from the same cwd.
repo_key() {
  (
    cd "$1"
    # shellcheck source=lib/common.sh
    source "$ROOT/lib/common.sh"
    dx_session_repo_key
  )
}

# error_names <path> <out>: the [error] line or the paths listed under it name <path>.
error_names() {
  grep -A 20 -F '[error]' "$2" | grep -Fq -- "$1"
}

# ── a clean dry run passes and shows where observations live ──────────────
REPO_A="$TMP_DIR/sync-repo"
make_repo "$REPO_A"
KEY_A=$(repo_key "$REPO_A")
[[ "$KEY_A" == repo-sync-repo-* ]] || assert_at $LINENO
DEFAULT_A="$HOME/.claude/.dex-memory/$KEY_A"

: > "$TEST_CODEX_LOG"
run_sync "$REPO_A" "$TMP_DIR/a.out" --dry-run --no-pr --budget-minutes 1
[[ "$SYNC_RC" -eq 0 ]] || { cat "$TMP_DIR/a.out" >&2; assert_at $LINENO; }
assert_contains 'Sync complete for: sync-repo' "$TMP_DIR/a.out"
assert_contains 'Read-only sync complete' "$TMP_DIR/a.out"
# The starting output and the prompt both carry the default state dir.
assert_contains "State dir: $DEFAULT_A" "$TMP_DIR/a.out"
assert_contains "State dir: $DEFAULT_A" "$TEST_CODEX_LOG"
assert_not_contains 'State dir: N/A' "$TEST_CODEX_LOG"
# Read-only computes the default but does not create it.
[[ ! -e "$HOME/.claude/.dex-memory" ]] || assert_at $LINENO
[[ -z "$(git -C "$REPO_A" status --porcelain)" ]] || assert_at $LINENO

# ── a dry run whose provider edits the index fails and names the file ─────
REPO_B="$TMP_DIR/dirty-repo"
make_repo "$REPO_B"
: > "$TEST_CODEX_LOG"
export TEST_CODEX_WRITE="$REPO_B/.dex/memory/index.md"
run_sync "$REPO_B" "$TMP_DIR/b.out" --dry-run --no-pr --budget-minutes 1
export TEST_CODEX_WRITE=""
[[ "$SYNC_RC" -eq 1 ]] || { cat "$TMP_DIR/b.out" >&2; assert_at $LINENO; }
error_names '.dex/memory/index.md' "$TMP_DIR/b.out" || { cat "$TMP_DIR/b.out" >&2; assert_at $LINENO; }
assert_not_contains 'Sync complete for:' "$TMP_DIR/b.out"
# Nothing is reverted; the write stays for the user to inspect.
grep -Fq 'written by a provider' "$REPO_B/.dex/memory/index.md" || assert_at $LINENO

# ── --trace-retrieval is read-only too; a new untracked file also fails ───
REPO_C="$TMP_DIR/trace-repo"
make_repo "$REPO_C"
: > "$TEST_CODEX_LOG"
export TEST_CODEX_WRITE="$REPO_C/.dex/memory/domains/new-domain.md"
run_sync "$REPO_C" "$TMP_DIR/c.out" --trace-retrieval "lib/review-loop.sh" --phase review --budget-minutes 1
export TEST_CODEX_WRITE=""
[[ "$SYNC_RC" -eq 1 ]] || { cat "$TMP_DIR/c.out" >&2; assert_at $LINENO; }
error_names '.dex/memory/domains/new-domain.md' "$TMP_DIR/c.out" || { cat "$TMP_DIR/c.out" >&2; assert_at $LINENO; }
[[ -f "$REPO_C/.dex/memory/domains/new-domain.md" ]] || assert_at $LINENO

# ── an explicit --state-dir wins over the default ─────────────────────────
: > "$TEST_CODEX_LOG"
run_sync "$REPO_A" "$TMP_DIR/d.out" --dry-run --no-pr --budget-minutes 1 --state-dir "$TMP_DIR/explicit-state"
[[ "$SYNC_RC" -eq 0 ]] || { cat "$TMP_DIR/d.out" >&2; assert_at $LINENO; }
assert_contains "State dir: $TMP_DIR/explicit-state" "$TEST_CODEX_LOG"
assert_contains "State dir: $TMP_DIR/explicit-state" "$TMP_DIR/d.out"
assert_not_contains "$DEFAULT_A" "$TEST_CODEX_LOG"

# ── DX_MEMORY_STORE_DIR replaces the default path ─────────────────────────
: > "$TEST_CODEX_LOG"
export DX_MEMORY_STORE_DIR="$TMP_DIR/store-override"
run_sync "$REPO_A" "$TMP_DIR/e.out" --dry-run --no-pr --budget-minutes 1
unset DX_MEMORY_STORE_DIR
[[ "$SYNC_RC" -eq 0 ]] || { cat "$TMP_DIR/e.out" >&2; assert_at $LINENO; }
assert_contains "State dir: $TMP_DIR/store-override" "$TEST_CODEX_LOG"
assert_not_contains "$DEFAULT_A" "$TEST_CODEX_LOG"

# ── a write run creates the default directory, private to the user ────────
: > "$TEST_CODEX_LOG"
run_sync "$REPO_A" "$TMP_DIR/f.out" --no-pr --budget-minutes 1
[[ "$SYNC_RC" -eq 0 ]] || { cat "$TMP_DIR/f.out" >&2; assert_at $LINENO; }
assert_contains "State dir: $DEFAULT_A" "$TEST_CODEX_LOG"
[[ -d "$DEFAULT_A" ]] || assert_at $LINENO
[[ "$(ls -ld "$DEFAULT_A" | cut -c1-10)" == "drwx------" ]] || assert_at $LINENO

# ── a write run trims the store and, when due, curates it before the agent ─
# A curator stub that records its call and changes nothing.
export CURATOR_LOG="$TMP_DIR/curator.log"
cat > "$TMP_DIR/bin/curator" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURATOR_LOG"
cat > /dev/null
printf '%s\n' '```json' '{"decisions": []}' '```'
SH
chmod +x "$TMP_DIR/bin/curator"
export DX_MEMORY_CURATOR_BIN="$TMP_DIR/bin/curator"
# Enough changed entries for a review to be due.
for i in 1 2 3 4 5; do
  printf '{"lesson":"fact number %s about README.md in this repo","evidence":"README.md","scope":"repo","type":"fact"}\n' "$i"
done > "$TMP_DIR/obs.jsonl"
python3 "$ROOT/scripts/memory_store.py" "$DEFAULT_A" ingest --repo "$REPO_A" --source test "$TMP_DIR/obs.jsonl" > /dev/null
STAMP_BEFORE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("last_maintained_at",""))' "$DEFAULT_A/entries.json")"
: > "$TEST_CODEX_LOG"
run_sync "$REPO_A" "$TMP_DIR/g.out" --dry-run --no-pr --budget-minutes 1
[[ "$SYNC_RC" -eq 0 ]] || { cat "$TMP_DIR/g.out" >&2; assert_at $LINENO; }
# Read-only runs leave the store alone: no curator call, no new maintenance stamp.
[[ ! -e "$TMP_DIR/curator.log" ]] || assert_at $LINENO
[[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("last_maintained_at",""))' "$DEFAULT_A/entries.json")" == "$STAMP_BEFORE" ]] || assert_at $LINENO
: > "$TEST_CODEX_LOG"
run_sync "$REPO_A" "$TMP_DIR/h.out" --no-pr --budget-minutes 1
[[ "$SYNC_RC" -eq 0 ]] || { cat "$TMP_DIR/h.out" >&2; assert_at $LINENO; }
[[ -f "$TMP_DIR/curator.log" ]] || { cat "$TMP_DIR/h.out" >&2; assert_at $LINENO; }
assert_contains 'Memory curation applied 0' "$TMP_DIR/h.out"
[[ -n "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("last_curated_at",""))' "$DEFAULT_A/entries.json")" ]] || assert_at $LINENO
# The agent still ran, after the curation.
assert_contains "State dir: $DEFAULT_A" "$TEST_CODEX_LOG"
# DEX_MEMORY_CURATE=0 skips the review; maintenance is the store's own business.
rm -f "$TMP_DIR/curator.log"
export DEX_MEMORY_CURATE=0
run_sync "$REPO_A" "$TMP_DIR/i.out" --no-pr --budget-minutes 1
unset DEX_MEMORY_CURATE
[[ "$SYNC_RC" -eq 0 ]] || { cat "$TMP_DIR/i.out" >&2; assert_at $LINENO; }
[[ ! -e "$TMP_DIR/curator.log" ]] || assert_at $LINENO

# ── nothing new since the last write run: no provider is launched ──────────
# The write run above synced everything the store held; the next write run
# with no new observations and no changed .dex files must not spend a model.
: > "$TEST_CODEX_LOG"
run_sync "$REPO_A" "$TMP_DIR/j.out" --no-pr --budget-minutes 1
[[ "$SYNC_RC" -eq 0 ]] || { cat "$TMP_DIR/j.out" >&2; assert_at $LINENO; }
assert_contains "Nothing new since the last sync" "$TMP_DIR/j.out"
! grep -q 'State dir:' "$TEST_CODEX_LOG" || assert_at $LINENO
# --force runs it anyway.
: > "$TEST_CODEX_LOG"
run_sync "$REPO_A" "$TMP_DIR/k.out" --no-pr --budget-minutes 1 --force
[[ "$SYNC_RC" -eq 0 ]] || { cat "$TMP_DIR/k.out" >&2; assert_at $LINENO; }
assert_contains "State dir: $DEFAULT_A" "$TEST_CODEX_LOG"
# A new observation makes the next run due again.
printf '{"lesson":"a sixth fact about README.md after the last sync","evidence":"README.md","scope":"repo","type":"fact"}\n' > "$TMP_DIR/obs6.jsonl"
python3 "$ROOT/scripts/memory_store.py" "$DEFAULT_A" ingest --repo "$REPO_A" --source test "$TMP_DIR/obs6.jsonl" > /dev/null
: > "$TEST_CODEX_LOG"
run_sync "$REPO_A" "$TMP_DIR/l.out" --no-pr --budget-minutes 1
[[ "$SYNC_RC" -eq 0 ]] || { cat "$TMP_DIR/l.out" >&2; assert_at $LINENO; }
assert_contains "State dir: $DEFAULT_A" "$TEST_CODEX_LOG"

echo "sync-dry-run-test: ok"
