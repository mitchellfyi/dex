#!/usr/bin/env bash
set -euo pipefail

# Retrieval is wired where context is built: the SessionStart hook prints the
# scoped memory for the files changed on the branch (after a recheck, so a
# stale entry is named, not trusted), and the SubagentStart hook gives a
# helper the entries for the paths it was given. Both leave a trace. A
# session-only launch and a repository with no memory get nothing new.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-memory-hooks-test.XXXXXX")"
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

# A repository whose branch changed lib/a.sh relative to origin/main.
ORIGIN="$TMP_DIR/origin.git"
git init -q --bare -b main "$ORIGIN"
REPO="$TMP_DIR/repo"
mkdir -p "$REPO/lib" "$REPO/docs" "$REPO/.dex/memory/domains"
git init -q -b main "$REPO"
git -C "$REPO" config user.email "dex@example.com"
git -C "$REPO" config user.name "Dex Test"
printf 'echo a\n' > "$REPO/lib/a.sh"
printf 'docs\n' > "$REPO/docs/x.md"
printf '# Memory\n' > "$REPO/.dex/memory/index.md"
cat > "$REPO/.dex/memory/domains/ops.md" <<'DOMAIN'
# Ops

## M-001: Library scripts are sourced by zsh too

Domain: ops
Status: active
Scope: lib/
Applies to phases: implement
Applies to paths: lib/
Last verified: 2026-09-01
Recheck when: lib/common.sh changes

Lesson:
Do not use zsh-reserved names in lib/.

Evidence:
- tests/zsh-reserved-names.py

Future agent behavior:
- Run the reserved-names check.
DOMAIN
git -C "$REPO" add .
git -C "$REPO" -c commit.gpgsign=false commit -q -m "init"
git -C "$REPO" remote add origin "$ORIGIN"
git -C "$REPO" push -q origin main
git -C "$REPO" checkout -q -b worktree-task-widget
printf 'echo a2\n' > "$REPO/lib/a.sh"
git -C "$REPO" -c commit.gpgsign=false commit -q -am "change lib"

# A verified observation about lib/a.sh, and one about docs/x.md.
cat > "$TMP_DIR/obs.jsonl" <<OBS
{"lesson":"lib/a.sh is the CLI entry point","evidence":"lib/a.sh","scope":"repo","type":"fact"}
{"lesson":"docs/x.md is the docs index","evidence":"docs/x.md","scope":"repo","type":"fact"}
OBS
python3 "$ROOT/scripts/memory_store.py" "$DX_MEMORY_STORE_DIR" ingest --repo "$REPO" --source test "$TMP_DIR/obs.jsonl" > /dev/null

SID="memory-hooks-session"

# ── SessionStart: memory for the branch's changed files, with a trace ──────
(cd "$REPO" && printf '{}' | DEX_SESSION_ID="$SID" bash "$ROOT/hooks/load-ticket-context.sh") > "$TMP_DIR/start.out"
assert_contains "M-001" "$TMP_DIR/start.out"
assert_contains "lib/a.sh is the CLI entry point" "$TMP_DIR/start.out"
assert_not_contains "docs index" "$TMP_DIR/start.out"
[[ -s "$DX_MEMORY_STORE_DIR/retrieval.log" ]] || assert_at $LINENO
TRACE="$(tail -1 "$DX_MEMORY_STORE_DIR/retrieval.log")"
[[ "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["session"], d["role"])' "$TRACE")" == "$SID lead" ]] || assert_at $LINENO

# The old one-line notice is gone in favour of the scoped view.
assert_not_contains "Load only active memory entries whose scope matches" "$TMP_DIR/start.out"

# ── SessionStart rechecks first: a changed dependency is named as stale ────
# The observation's blob was recorded against the branch tip; change the file
# in the working tree and the entry must come back as stale, not current.
printf 'echo a3\n' > "$REPO/lib/a.sh"
(cd "$REPO" && printf '{}' | DEX_SESSION_ID="$SID" bash "$ROOT/hooks/load-ticket-context.sh") > "$TMP_DIR/start2.out"
assert_not_contains "lib/a.sh is the CLI entry point (" "$TMP_DIR/start2.out"
assert_contains "needs recheck" "$TMP_DIR/start2.out"
git -C "$REPO" checkout -q -- lib/a.sh

# ── uncommitted work counts as changed too ─────────────────────────────────
# Editing docs/x.md puts it in scope and, because the fact about it depends on
# that file's blob, the recheck marks that fact stale: named, not shown as current.
printf 'more docs\n' >> "$REPO/docs/x.md"
(cd "$REPO" && printf '{}' | DEX_SESSION_ID="$SID" bash "$ROOT/hooks/load-ticket-context.sh") > "$TMP_DIR/start3.out"
assert_not_contains "docs/x.md is the docs index (" "$TMP_DIR/start3.out"
assert_contains "needs recheck" "$TMP_DIR/start3.out"
TRACE="$(tail -1 "$DX_MEMORY_STORE_DIR/retrieval.log")"
[[ "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print("docs/x.md" in d["paths"])' "$TRACE")" == "True" ]] || assert_at $LINENO
git -C "$REPO" checkout -q -- docs/x.md

# ── session-only launches get no memory block ──────────────────────────────
(cd "$REPO" && printf '{}' | DEX_SESSION_ONLY=1 DEX_SESSION_ID="$SID" bash "$ROOT/hooks/load-ticket-context.sh") > "$TMP_DIR/start-only.out"
assert_not_contains "M-001" "$TMP_DIR/start-only.out"

# ── SubagentStart: the helper gets the entries for its scope ───────────────
printf 'Build.\n' > "$TMP_DIR/brief.md"
bash "$ROOT/bin/mission.sh" "$SID" init --mission-id m-h --brief-file "$TMP_DIR/brief.md" \
  --workspace "$REPO" --branch worktree-task-widget --base-revision "$(git -C "$REPO" rev-parse HEAD)" > /dev/null
(cd "$REPO" && printf '{"session_id":"c1","agent_id":"inv-1","agent_type":"dx-investigator","cwd":"%s"}' "$REPO" \
  | DX_MISSION_ACTIVE=1 DEX_SESSION_ID="$SID" DX_MISSION_HELPER_SCOPE="docs/" bash "$ROOT/hooks/subagent-start.sh") > "$TMP_DIR/helper.out"
assert_contains "docs/x.md is the docs index" "$TMP_DIR/helper.out"
assert_not_contains "M-001" "$TMP_DIR/helper.out"
TRACE="$(tail -1 "$DX_MEMORY_STORE_DIR/retrieval.log")"
[[ "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["role"])' "$TRACE")" == "dx-investigator" ]] || assert_at $LINENO

# Without a scope the helper falls back to the branch's changed files.
(cd "$REPO" && printf '{"session_id":"c1","agent_id":"impl-1","agent_type":"dx-implementer","cwd":"%s"}' "$REPO" \
  | DX_MISSION_ACTIVE=1 DEX_SESSION_ID="$SID" bash "$ROOT/hooks/subagent-start.sh") > "$TMP_DIR/helper2.out"
assert_contains "M-001" "$TMP_DIR/helper2.out"

# ── DEX_MEMORY_RETRIEVAL=0 turns injection off (the memory on/off comparison) ──
(cd "$REPO" && printf '{}' | DEX_SESSION_ID="$SID" DEX_MEMORY_RETRIEVAL=0 bash "$ROOT/hooks/load-ticket-context.sh") > "$TMP_DIR/start-off.out"
! grep -q 'obs:' "$TMP_DIR/start-off.out" || assert_at $LINENO
! grep -qi 'memory for these paths' "$TMP_DIR/start-off.out" || assert_at $LINENO

echo "memory-hooks-test: ok"
