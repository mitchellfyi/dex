#!/usr/bin/env bash
set -euo pipefail

# Tests for the await-in-loop built-in guard (hooks/guards/await-in-loop.md +
# the `await-in-loop` detector in hooks/guard-handler.py). Drives the guard
# handler with synthetic file-event payloads and asserts whether the guard fires.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HANDLER="$ROOT/hooks/guard-handler.py"
export DEX_DIR="$ROOT"

pass=0
fail=0

# Build a file-event payload with the given file content.
mkpayload() {
  python3 -c 'import json,sys; print(json.dumps({"tool_input":{"file_path":"sample.ts","content":sys.argv[1]}}))' "$1"
}

run_guard() {
  set +e
  GUARD_OUT="$(printf '%s' "$1" | DEX_GUARD_EVENT=file python3 "$HANDLER" 2>/dev/null)"
  set -e
}

assert_triggers() {
  run_guard "$(mkpayload "$2")"
  if printf '%s' "$GUARD_OUT" | grep -q 'warn-await-in-loop'; then
    pass=$((pass + 1))
  else
    printf 'FAIL (expected trigger): %s\n' "$1" >&2
    fail=$((fail + 1))
  fi
}

assert_clean() {
  run_guard "$(mkpayload "$2")"
  if printf '%s' "$GUARD_OUT" | grep -q 'warn-await-in-loop'; then
    printf 'FAIL (false positive): %s\n' "$1" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
}

# --- should trigger ---
assert_triggers "for-of with direct await" \
  'for (const i of items) { await repo.find(i.id) }'
assert_triggers "await nested in if inside loop" \
  'for (const i of items) { if (i.ok) { await repo.find(i.id) } }'
assert_triggers "classic indexed for" \
  'for (let i = 0; i < items.length; i++) { await save(items[i]) }'
assert_triggers "while loop with await" \
  'while (queue.length) { await process(queue.pop()) }'

# --- should stay clean ---
assert_clean "batched Promise.all" \
  'const r = await Promise.all(items.map((i) => repo.find(i.id)))'
assert_clean "collect promises, await after loop" \
  'const ps = []; for (const i of items) { ps.push(repo.find(i.id)) } await Promise.all(ps)'
assert_clean "deferred closure await in loop body" \
  'for (const i of items) { tasks.push(async () => { await repo.find(i) }) } await Promise.all(tasks.map((t) => t()))'
assert_clean "for await async iteration" \
  'for await (const chunk of stream) { handle(chunk) }'
assert_clean "loop pattern only inside a string" \
  'const sql = "for (x of y) { await z }"; doThing()'
assert_clean "loop with no await" \
  'for (const i of items) { total += i.value }'
assert_clean "loop+await only inside a comment" \
  '// for (const i of items) { await x(i) }
doThing()'

# --- realistic multi-line ---
assert_triggers "multi-line service method" \
  'async function load(items) {
  const out = []
  for (const i of items) {
    const row = await repo.findById(i.id)
    out.push(row)
  }
  return out
}'

printf 'guards-test: %d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
