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

mkbashpayload() {
  python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$1"
}

run_guard() {
  set +e
  GUARD_OUT="$(printf '%s' "$1" | env DEX_GUARD_EVENT=file python3 "$HANDLER" 2>/dev/null)"
  set -e
}

run_bash_guard() {
  set +e
  GUARD_OUT="$(printf '%s' "$1" | env DEX_GUARD_EVENT=bash DX_PROVIDER_ENGINE=codex-plugin python3 "$HANDLER" 2>&1)"
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

assert_raw_codex_blocks() {
  run_bash_guard "$(mkbashpayload "$2")"
  if printf '%s' "$GUARD_OUT" | grep -q 'block-raw-codex-delegation'; then
    pass=$((pass + 1))
  else
    printf 'FAIL (expected raw Codex block): %s\n' "$1" >&2
    fail=$((fail + 1))
  fi
}

assert_raw_codex_clean() {
  run_bash_guard "$(mkbashpayload "$2")"
  if printf '%s' "$GUARD_OUT" | grep -q 'block-raw-codex-delegation'; then
    printf 'FAIL (raw Codex false positive): %s\n' "$1" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
}

assert_destructive_blocks() {
  run_bash_guard "$(mkbashpayload "$2")"
  if printf '%s' "$GUARD_OUT" | grep -q 'block-destructive-commands'; then
    pass=$((pass + 1))
  else
    printf 'FAIL (expected destructive-command block): %s\n' "$1" >&2
    fail=$((fail + 1))
  fi
}

assert_destructive_clean() {
  run_bash_guard "$(mkbashpayload "$2")"
  if printf '%s' "$GUARD_OUT" | grep -q 'block-destructive-commands'; then
    printf 'FAIL (destructive-command false positive): %s\n' "$1" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
}

assert_secret_warns() {
  run_guard "$(mkpayload "$2")"
  if printf '%s' "$GUARD_OUT" | grep -q 'warn-hardcoded-secrets'; then
    pass=$((pass + 1))
  else
    printf 'FAIL (expected hardcoded-secret warning): %s\n' "$1" >&2
    fail=$((fail + 1))
  fi
}

assert_secret_clean() {
  run_guard "$(mkpayload "$2")"
  if printf '%s' "$GUARD_OUT" | grep -q 'warn-hardcoded-secrets'; then
    printf 'FAIL (hardcoded-secret false positive): %s\n' "$1" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
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
assert_triggers "Python for loop with await" \
  'async def load(items):
    for item in items:
        await fetch(item)'
assert_triggers "C# foreach loop with await" \
  'foreach (var item in items) { await FetchAsync(item); }'
assert_triggers "Rust-style loop with await expression" \
  'for item in items { fetch(item).await; }'
assert_triggers "brace loop without parenthesized header" \
  'for item in items { await fetch(item) }'

# --- should stay clean ---
assert_clean "batched Promise.all" \
  'const r = await Promise.all(items.map((i) => repo.find(i.id)))'
assert_clean "collect promises, await after loop" \
  'const ps = []; for (const i of items) { ps.push(repo.find(i.id)) } await Promise.all(ps)'
assert_clean "deferred closure await in loop body" \
  'for (const i of items) { tasks.push(async () => { await repo.find(i) }) } await Promise.all(tasks.map((t) => t()))'
assert_clean "expression-bodied async arrow in loop body" \
  'for (const i of items) { tasks.push(async () => await repo.find(i)) } await Promise.all(tasks.map((t) => t()))'
assert_clean "async object method in loop body" \
  'for (const i of items) { tasks.push({ async run() { await repo.find(i) } }) } await Promise.all(tasks.map((t) => t.run()))'
assert_clean "async class method in loop body" \
  'for (const i of items) { tasks.push(class { async run() { await repo.find(i) } }) }'
assert_clean "for await async iteration" \
  'for await (const chunk of stream) { handle(chunk) }'
assert_clean "Python async for iteration" \
  'async for item in stream:
    await handle(item)'
assert_clean "C# await foreach iteration" \
  'await foreach (var item in stream) { await HandleAsync(item); }'
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

# --- raw Codex guard trusted Dex helper regressions ---
# shellcheck disable=SC2016
assert_raw_codex_clean "source Dex common helper" \
  'source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"
SID="${DEX_SESSION_ID:-$(dx_session_id)}"'
# shellcheck disable=SC2016
assert_raw_codex_clean "run Dex UI capture helper" \
  'bash "${DEX_DIR:-$HOME/work/dex}/bin/ui-capture.sh" --install-only 2>&1 | tail -15'
assert_raw_codex_blocks "raw Codex remains blocked" \
  'codex exec "do work"'
# shellcheck disable=SC2016
assert_raw_codex_blocks "trusted source plus direct provider call remains blocked" \
  'source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"; dx_provider_codex exec "do work"'

# --- destructive-command bypass regressions ---
assert_destructive_blocks "dd raw-device output" \
  'dd of=/dev/disk0 bs=1m'
assert_destructive_blocks "diskutil erase" \
  'diskutil eraseDisk APFS Empty /dev/disk2'
assert_destructive_blocks "BusyBox rm" \
  'busybox rm -rf /'
assert_destructive_blocks "Python process wrapper" \
  'python3 -c '\''import os; os.system("rm -rf /")'\'''
assert_destructive_blocks "Node process wrapper" \
  'node -e '\''require("child_process").execSync("rm -rf /")'\'''
assert_destructive_blocks "Perl process wrapper" \
  'perl -e '\''system("rm -rf /")'\'''
assert_destructive_clean "dd to a regular file" \
  'dd if=/dev/zero of=./disk-image.bin bs=1024 count=1'
assert_destructive_clean "dd to null" \
  'dd if=/dev/zero of=/dev/null bs=1024 count=1'

# --- hardcoded-secret remediation regressions ---
assert_secret_warns "literal secret remains warned" \
  'PASSWORD="hardcoded-secret-value"'
assert_secret_clean "Python environment access" \
  'PASSWORD=os.environ["PASSWORD"]'
assert_secret_clean "Node environment access" \
  'API_KEY=process.env.API_KEY'
# shellcheck disable=SC2016
assert_secret_clean "shell environment access" \
  'AUTH_TOKEN=${AUTH_TOKEN_FROM_ENV}'

# Push-blocking guards (review-pass-no-push, lifecycle-phase-push) are covered
# by tests/push-guards-test.sh, kept separate so that file contains no raw
# Codex payload strings.

printf 'guards-test: %d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
