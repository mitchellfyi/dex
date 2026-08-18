#!/usr/bin/env bash
set -euo pipefail

# Tests for the await-in-loop built-in guard (hooks/guards/await-in-loop.md +
# the `await-in-loop` detector in hooks/guard-handler.py). Drives the guard
# handler with synthetic file-event payloads and asserts whether the guard fires.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HANDLER="$ROOT/hooks/guard-handler.py"
export DEX_DIR="$ROOT"

# Hermeticity: the handler's provider fallback reads ~/.dex/providers.json, so
# guard applicability must not vary with the developer's real config.
GUARD_HOME_TMP="$(mktemp -d "${TMPDIR:-/tmp}/dex-guards-home.XXXXXX")"
export HOME="$GUARD_HOME_TMP/home"
mkdir -p "$HOME"
trap 'rm -rf "$GUARD_HOME_TMP"' EXIT

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

# The commit event carries the committed file names and the subject line in
# CLAUDE_TOOL_USE_INPUT rather than a JSON payload — see hooks/post-commit-guard.sh.
run_commit_guard() {
  set +e
  GUARD_OUT="$(printf '' | env DEX_GUARD_EVENT=commit CLAUDE_TOOL_USE_INPUT="$1" python3 "$HANDLER" 2>&1)"
  set -e
}

assert_sensitive_warns() {
  run_commit_guard "$2"
  if printf '%s' "$GUARD_OUT" | grep -q 'warn-sensitive-files'; then
    pass=$((pass + 1))
  else
    printf 'FAIL (expected sensitive-file warning): %s\n' "$1" >&2
    fail=$((fail + 1))
  fi
}

assert_sensitive_clean() {
  run_commit_guard "$2"
  if printf '%s' "$GUARD_OUT" | grep -q 'warn-sensitive-files'; then
    printf 'FAIL (sensitive-file false positive): %s\n' "$1" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
}

# The attribution guard is scoped by `env_var: DEX_SESSION_ID`, so it only
# applies inside a Dex lifecycle session.
run_attribution_guard() {
  set +e
  GUARD_OUT="$(printf '%s' "$1" | env DEX_GUARD_EVENT=bash DEX_SESSION_ID="${2:-guards-test}" python3 "$HANDLER" 2>&1)"
  set -e
}

assert_attribution_blocks() {
  run_attribution_guard "$(mkbashpayload "$2")"
  if printf '%s' "$GUARD_OUT" | grep -q 'block-claude-attribution'; then
    pass=$((pass + 1))
  else
    printf 'FAIL (expected attribution block): %s\n' "$1" >&2
    fail=$((fail + 1))
  fi
}

assert_attribution_clean() {
  run_attribution_guard "$(mkbashpayload "$2")"
  if printf '%s' "$GUARD_OUT" | grep -q 'block-claude-attribution'; then
    printf 'FAIL (attribution false positive): %s\n' "$1" >&2
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
# This guard shares the xargs replacement parsing with the destructive-command
# detector, so the same input-not-on-the-line and --replace misreads let raw
# delegation through here too.
assert_raw_codex_blocks "xargs -I{} running Codex directly" \
  'xargs -I{} codex exec do-work'
assert_raw_codex_blocks "xargs -I{} running Codex through a shell" \
  'xargs -I{} bash -c '\''codex exec do-work'\'''
assert_raw_codex_blocks "xargs --replace running Codex through a shell" \
  'xargs --replace bash -c '\''codex exec do-work'\'''
# This guard reads xargs input the same way the destructive one does: with a
# replacement the items are lines, stripped of their surrounding blanks.
assert_raw_codex_blocks "a readable value that delegates to Codex" \
  'printf "codex exec build\n" | xargs -I{} bash -c '\''{}'\'''
assert_raw_codex_blocks "the same value indented" \
  'printf "  codex exec build\n" | xargs -I{} bash -c '\''{}'\'''
assert_raw_codex_clean "a readable value that does not" \
  'printf "build\n" | xargs -I{} make {}'

# --- sensitive files in a commit (the only guard on the commit event) ---
assert_sensitive_warns "a dotenv file" \
  '.env
feat: add config'
assert_sensitive_warns "a scoped dotenv file" \
  'src/.env.local
fix: thing'
assert_sensitive_warns "a credentials file" \
  'config/credentials.json
fix: thing'
assert_sensitive_warns "a certificate" \
  'certs/server.pem
fix: thing'
assert_sensitive_warns "a private key" \
  'keys/id_rsa
fix: thing'
assert_sensitive_clean "a source file whose name merely reads like a secret" \
  'app/secrets.ts
fix: thing'
assert_sensitive_clean "documentation" \
  'README.md
docs: update'
assert_sensitive_clean "a source file starting with the same letters as .env" \
  'src/environment.ts
fix: thing'

# --- Claude attribution ---
assert_attribution_blocks "generated-by footer in a PR body" \
  'gh pr create --body "Generated with Claude Code"'
assert_attribution_blocks "generated-by footer on a PR edit" \
  'gh pr edit 1 --body "Generated by Claude"'
assert_attribution_blocks "generated-by footer in a PR comment" \
  'gh pr comment 1 --body "Created by Claude Code"'
assert_attribution_blocks "Claude co-author trailer on a commit" \
  'git commit -m "x" -m "Co-Authored-By: Claude <noreply@anthropic.com>"'
assert_attribution_blocks "authored-with footer on a commit" \
  'git commit -m "x" -m "Authored with Claude Code"'
assert_attribution_clean "Dex attribution in a PR body" \
  'gh pr create --body "Generated by Dex"'
assert_attribution_clean "Dex co-author trailer" \
  'git commit -m "x" -m "Co-Authored-By: Dex <noreply@dexcode.ai>"'
assert_attribution_clean "an ordinary commit" \
  'git commit -m "fix: thing"'
assert_attribution_clean "the phrase outside a commit or PR command" \
  'echo "Generated with Claude Code"'

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
# The shell word-splits the output of a substitution in command position, so
# these run `rm` with `-rf /`. Only the first word used to be examined, which
# left a bare `rm` — not destructive on its own.
assert_destructive_blocks "substitution resolving to a destructive command" \
  '$(printf '\''%s'\'' '\''rm -rf /'\'')'
assert_destructive_blocks "echo substitution resolving to a destructive command" \
  '$(echo '\''rm -rf /'\'')'
assert_destructive_blocks "backtick substitution resolving to a destructive command" \
  '`echo '\''rm -rf /'\''`'
assert_destructive_blocks "substitution supplying only the command and flags" \
  '$(printf '\''%s'\'' '\''rm -rf'\'') /'
assert_destructive_clean "dd to a regular file" \
  'dd if=/dev/zero of=./disk-image.bin bs=1024 count=1'
assert_destructive_clean "dd to null" \
  'dd if=/dev/zero of=/dev/null bs=1024 count=1'
# A substitution in command position is ordinary tooling; resolving its output
# must not make these look destructive.
# `xargs` without a pipe reads the terminal, so "no values on the line" is not
# "no values". The replacement branch used to return early and never look at
# the command it would run for each of them.
assert_destructive_blocks "xargs -I{} running a destructive shell payload" \
  'xargs -I{} bash -c '\''rm -rf /'\'''
assert_destructive_blocks "xargs -I{} running a destructive command directly" \
  'xargs -I{} rm -rf /'
assert_destructive_blocks "xargs -0 -I{} running a destructive shell payload" \
  'xargs -0 -I{} bash -c '\''rm -rf /'\'''
# --replace takes an optional argument; consuming the next token as the
# replacement hid the command being run.
assert_destructive_blocks "xargs --replace running a destructive shell payload" \
  'xargs --replace bash -c '\''rm -rf /'\'''
assert_destructive_clean "xargs -I{} passing values as arguments" \
  'xargs -I{} du -k {}'
assert_destructive_clean "xargs -I{} removing without recursion" \
  'xargs -I{} rm -f {}'
assert_destructive_clean "xargs --replace with an explicit token" \
  'xargs --replace=% echo %'
# `--replace` takes an optional argument, so it must not be treated as one that
# consumes the next token — doing so hid this command's own NUL delimiter and
# left the substituted value carrying a stray NUL, which matched no rm target.
assert_destructive_blocks "xargs --replace does not hide the NUL delimiter" \
  "printf '/\\0' | xargs --replace -0 rm -rf {}"
assert_destructive_blocks "xargs --replace does not hide --null" \
  "printf '/\\0' | xargs --replace --null rm -rf {}"
# Values reach the command only where the placeholder is, and there they are
# filenames unless they land inside a script argument.
assert_destructive_clean "xargs -I{} removing a bounded path" \
  'xargs -I{} rm -rf ./build'
assert_destructive_clean "xargs --replace removing a bounded path" \
  'xargs --replace rm -rf ./build'
# `-i` is GNU's deprecated spelling of --replace. Unrecognised, it read as a
# command with no replacement at all and was judged by the wrong branch.
assert_destructive_clean "xargs -i removing a bounded path" \
  'xargs -i rm -rf ./build'
assert_destructive_clean "xargs -i{} removing a bounded path" \
  'xargs -i{} rm -rf ./build'
assert_destructive_blocks "xargs -i removing what its values name" \
  'xargs -i rm -rf {}'
# A source that is on the line and empty appends nothing, which is not the same
# as no source at all — the second reads the terminal.
assert_destructive_clean "xargs with a visibly empty redirect" \
  'xargs rm -rf ./build < /dev/null'
assert_destructive_clean "xargs with a visibly empty pipe" \
  'printf "" | xargs rm -rf ./build'
# Empty input means no value is substituted, not that nothing runs: GNU xargs
# runs the command once anyway without `-r`, with the replacement as written.
assert_destructive_blocks "empty input still running a destructive command" \
  'printf "" | xargs -i rm -rf /'
assert_destructive_blocks "empty input still running a destructive command with -I" \
  'printf "" | xargs -I{} rm -rf ~'
assert_destructive_clean "empty input running a bounded command" \
  'printf "" | xargs -I{} rm -rf ./build'
# xargs strips an item's surrounding blanks before substituting it, so an
# indented list still names its targets — ` /` is `/`.
assert_destructive_blocks "an indented input item" \
  'printf " /\n" | xargs -I{} rm -rf {}'
assert_destructive_blocks "an indented list among ordinary items" \
  'printf "  a\n  /\n" | xargs -I{} rm -rf {}'
assert_destructive_blocks "an item with a trailing blank" \
  'printf "/ \n" | xargs -I{} rm -rf {}'
assert_destructive_clean "an indented ordinary item" \
  'printf " build\n" | xargs -I{} rm -rf ./{}'
# Deciding a source is visible while the reader cannot see it turns a readable,
# destructive source into "provably empty". The two must stop at the same
# tokens, so a bare placeholder hides the redirect from both or from neither.
assert_destructive_blocks "a here-string behind a bare placeholder" \
  'xargs -I{} sh -c '\''{}'\'' <<< '\''rm -rf /'\'''
assert_destructive_blocks "an interpreter reading behind a bare placeholder" \
  'xargs -I{} python3 -c '\''{}'\'' <<< '\''rm -rf /'\'''
assert_destructive_blocks "an unreadable source behind a bare placeholder" \
  'xargs -I{} sh -c '\''{}'\'' < /nonexistent-xyz'
# An unreadable value handed to a shell, interpreter or package runner is a
# possible command, and the answer is fail-closed. Telling code positions from
# data ones was tried and kept getting it wrong — a script can `eval` its own
# positionals, and an option's separate value hides which argument is the
# program — so this stays coarse. A value that can be read is judged for what
# it actually is, below.
assert_destructive_blocks "xargs -I{} passing an unreadable value to an interpreter" \
  'xargs -I{} python3 process.py {}'
assert_destructive_blocks "xargs -I{} passing an unreadable value to a package runner" \
  'xargs -I{} npx eslint {}'
assert_destructive_blocks "xargs -I{} substituting into a script argument" \
  'xargs -I{} bash -c '\''echo {}'\'''
# The tokenizer splits a bare `{}` in two, which made the default spelling read
# differently from every other one: `-I% %` was judged and `-I{} {}` was not.
assert_destructive_blocks "xargs -I{} making the value the command" \
  'xargs -I{} {}'
assert_destructive_blocks "xargs -I% making the value the command" \
  'xargs -I% %'
assert_destructive_blocks "xargs -I{} making the value the command behind a wrapper" \
  'xargs -I{} sudo {} arg'
assert_destructive_blocks "xargs -I{} passing the value as a shell script" \
  'xargs -I{} sh -c {}'
# Any value handed to a shell counts as code. A script can run its own
# positionals — `sh -c 'eval "$1"' sh {}` executes the input line — and that is
# indistinguishable from `sh -c 'gzip "$1"' _ {}`, which only reads it. The
# safe half of that pair is the one that gets blocked with it.
assert_destructive_blocks "xargs -I{} substituting into the shell's \$0" \
  'xargs -I{} sh -c '\''$0'\'' {}'
assert_destructive_blocks "xargs -I{} substituting into a shell positional" \
  'xargs -I{} sh -c '\''eval "$1"'\'' sh {}'
assert_destructive_blocks "xargs -I{} handing a shell a script to read" \
  'xargs -I{} sh -c '\''gzip "$1"'\'' _ {}'
# An interpreter's program is fixed by its first non-option argument, so a
# value after that is an argument to it — but a value that names the program,
# or a module or file the interpreter loads, chooses what runs.
assert_destructive_blocks "xargs -I{} making the value an interpreter's program" \
  'xargs -I{} python3 {}'
assert_destructive_blocks "xargs -I{} making the value a loaded module" \
  'xargs -I{} python3 -m {}'
assert_destructive_blocks "xargs -I{} preloading the value" \
  'xargs -I{} node -r {} app.js'
assert_destructive_blocks "xargs -I{} passing an unreadable value after the program" \
  'xargs -I{} python3 tool.py -e {}'
# With a replacement, xargs reads one item per line, not per blank-separated
# word. Splitting on whitespace turned a readable line carrying a whole command
# into a handful of harmless words, so the one case where the values are known
# and it matters saw nothing.
assert_destructive_blocks "a readable value the script evaluates" \
  'printf "rm -rf /\n" | xargs -I{} bash -c '\''eval "$1"'\'' bash {}'
assert_destructive_blocks "a readable value used as the program" \
  'printf "rm -rf /\n" | xargs -I{} sh {}'
assert_destructive_clean "a readable value used as a filename" \
  'printf "a.txt\n" | xargs -I{} python3 process.py {}'
assert_destructive_clean "a readable value completing a bounded path" \
  'echo build | xargs -I{} rm -rf ./{}'
# xargs substitutes an item as one argument and does not re-parse it. Splitting
# it turned an interpreter's `-c` source into loose tokens, so the checks that
# read such a payload saw nothing.
assert_destructive_blocks "a readable value that is interpreter source" \
  'printf "import os; os.system(\"rm -rf /\")\n" | xargs -I{} python3 -c {}'
assert_destructive_blocks "a readable value that is node source" \
  'printf "require(\"child_process\").execSync(\"rm -rf /\")\n" | xargs -I{} node -e {}'
# A whitespace-only line is still an input item: xargs runs the command once
# with the replacement expanded to nothing. Only genuinely empty input is inert.
assert_destructive_blocks "a whitespace-only input line" \
  'printf "   \n" | xargs -I{} rm -rf ./{}'
assert_destructive_blocks "a whitespace-only here-string" \
  'xargs -I{} rm -rf ./{} <<< " "'
assert_destructive_clean "xargs -I{} passing a value to a text tool" \
  'xargs -I{} awk '\''{print}'\'' {}'
# Without a replacement the values are appended, so they are the targets.
assert_destructive_blocks "xargs appending values to a recursive removal" \
  'xargs rm -rf'
assert_destructive_blocks "xargs appending values through a wrapper" \
  'xargs sudo rm -rf'
assert_destructive_blocks "xargs reading targets from a file it was given" \
  'xargs -a targets.txt rm -rf'
assert_destructive_clean "xargs appending values to an ordinary command" \
  'xargs grep -l TODO'
assert_destructive_clean "xargs removing without recursion" \
  'xargs rm -f'
# A wrapper the scanner does not know hides everything after it.
assert_destructive_blocks "stdbuf prefixing a destructive command" \
  'stdbuf -oL rm -rf /'
assert_destructive_blocks "stdbuf with a separated option value" \
  'stdbuf -o L rm -rf /'
assert_destructive_blocks "setsid prefixing a destructive command" \
  'setsid rm -rf /'
assert_destructive_blocks "unbuffer prefixing a destructive command" \
  'unbuffer rm -rf /'
assert_destructive_blocks "stdbuf prefixing a destructive xargs" \
  'stdbuf -oL xargs -I{} rm -rf /'
assert_destructive_clean "stdbuf prefixing ordinary work" \
  'stdbuf -oL make build'
assert_destructive_clean "setsid prefixing ordinary work" \
  'setsid npm run dev'
assert_destructive_clean "stdbuf prefixing a bounded removal" \
  'stdbuf -oL rm -rf ./build'
assert_destructive_clean "substitution naming an interpreter" \
  '$(command -v python3) -c '\''print(1)'\'''
assert_destructive_clean "substitution resolving to a bounded removal" \
  '$(echo rm) -rf ./build'
assert_destructive_clean "substitution used as a path prefix" \
  '$(git rev-parse --show-toplevel)/tests/check.sh'

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
set +e
GUARD_OUT="$(mkpayload 'changed content' | env DEX_REVIEW_ASSESSMENT_ACTIVE=1 DEX_GUARD_EVENT=file python3 "$HANDLER" 2>&1)"
GUARD_RC=$?
set -e
if [[ "$GUARD_RC" -eq 2 ]] && printf '%s' "$GUARD_OUT" | grep -q 'block-review-assessment-file-edits'; then
  pass=$((pass + 1))
else
  printf 'FAIL (expected review assessment file-edit block)\n%s\n' "$GUARD_OUT" >&2
  fail=$((fail + 1))
fi

set +e
GUARD_OUT="$(mkbashpayload 'git status --short' | env DEX_REVIEW_ASSESSMENT_ACTIVE=1 DEX_GUARD_EVENT=bash python3 "$HANDLER" 2>&1)"
GUARD_RC=$?
set -e
if [[ "$GUARD_RC" -eq 2 ]] && printf '%s' "$GUARD_OUT" | grep -q 'block-review-assessment-bash'; then
  pass=$((pass + 1))
else
  printf 'FAIL (expected review assessment Bash block)\n%s\n' "$GUARD_OUT" >&2
  fail=$((fail + 1))
fi

set +e
GUARD_OUT="$(mkbashpayload 'git status --short' | env DEX_GUARD_EVENT=bash python3 "$HANDLER" 2>&1)"
GUARD_RC=$?
set -e
if [[ "$GUARD_RC" -eq 0 ]] && ! printf '%s' "$GUARD_OUT" | grep -q 'block-review-assessment-bash'; then
  pass=$((pass + 1))
else
  printf 'FAIL (review assessment Bash guard leaked outside assessor mode)\n%s\n' "$GUARD_OUT" >&2
  fail=$((fail + 1))
fi
# Lifecycle commit/push/PR permissions are covered by push-guards-test.sh,
# including a regression that the remaining destructive-command guard stays
# active.

# Piping into `xargs -I{}` hides the values from the guard. Denying every such
# command is too blunt: values can only become a command when the template
# puts them in command position or hands them to a shell/interpreter.
assert_bash_allowed_codex() {
  run_bash_guard "$(mkbashpayload "$2")"
  if printf '%s' "$GUARD_OUT" | grep -q 'BLOCKED'; then
    printf 'FAIL (expected allowed): %s\n%s\n' "$1" "$GUARD_OUT" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
}

assert_bash_allowed_codex "xargs into a fixed non-launching command" \
  "git ls-files | xargs -I{} du -k {}"
assert_bash_allowed_codex "xargs into git with a placeholder argument" \
  "cat list.txt | xargs -I{} git add {}"

assert_bash_blocks() {
  run_bash_guard "$(mkbashpayload "$2")"
  if printf '%s' "$GUARD_OUT" | grep -q 'BLOCKED'; then
    pass=$((pass + 1))
  else
    printf 'FAIL (expected blocked): %s\n%s\n' "$1" "$GUARD_OUT" >&2
    fail=$((fail + 1))
  fi
}

assert_bash_blocks "xargs substituting into command position" \
  "cat list.txt | xargs -I{} {}"
assert_bash_blocks "xargs handing values to a shell" \
  "cat list.txt | xargs -I{} bash -c {}"
assert_raw_codex_blocks "xargs into a package runner" \
  "cat list.txt | xargs -I{} npx {}"
assert_raw_codex_blocks "xargs template naming codex outright" \
  "cat list.txt | xargs -I{} codex exec {}"
assert_bash_blocks "xargs into rm -rf with hidden targets" \
  "cat list.txt | xargs -I{} rm -rf {}"

# A guard scoped with `match: path` checks the file path only. Without it, a
# location rule fires on any file whose contents merely mention that location.
SCOPE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/dex-guards-scope.XXXXXX")"
mkdir -p "$SCOPE_TMP/repo/.dex/guards"
git -C "$SCOPE_TMP/repo" init -q
cat > "$SCOPE_TMP/repo/.dex/guards/path-scoped.md" <<'GUARD'
---
name: test-path-scoped
enabled: true
event: file
match: path
pattern: (?:lib/)[^/]*\.sh$
action: warn
---

Test guard: fires only for edits to lib shell scripts.
GUARD

run_scoped_guard() {
  set +e
  GUARD_OUT="$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"file_path":sys.argv[1],"content":sys.argv[2]}}))' "$1" "$2" \
    | (cd "$SCOPE_TMP/repo" && env DEX_GUARD_EVENT=file python3 "$HANDLER") 2>&1)"
  set -e
}

run_scoped_guard "/tmp/notes.md" "this doc talks about lib/common.sh at length"
if printf '%s' "$GUARD_OUT" | grep -q 'test-path-scoped'; then
  printf 'FAIL (path-scoped guard fired on a content mention)\n%s\n' "$GUARD_OUT" >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

run_scoped_guard "lib/common.sh" "printf 'hello\n'"
if printf '%s' "$GUARD_OUT" | grep -q 'test-path-scoped'; then
  pass=$((pass + 1))
else
  printf 'FAIL (path-scoped guard missed a real lib edit)\n%s\n' "$GUARD_OUT" >&2
  fail=$((fail + 1))
fi

# An unscoped guard keeps the previous behavior of matching path plus content.
sed 's/^match: path$//; s/test-path-scoped/test-unscoped/' \
  "$SCOPE_TMP/repo/.dex/guards/path-scoped.md" > "$SCOPE_TMP/repo/.dex/guards/unscoped.md"
rm -f "$SCOPE_TMP/repo/.dex/guards/path-scoped.md"
run_scoped_guard "/tmp/notes.md" "this doc talks about lib/common.sh"
if printf '%s' "$GUARD_OUT" | grep -q 'test-unscoped'; then
  pass=$((pass + 1))
else
  printf 'FAIL (unscoped guard should still match content)\n%s\n' "$GUARD_OUT" >&2
  fail=$((fail + 1))
fi
rm -rf "$SCOPE_TMP"

# Shell syntax checks (noexec) must be allowed: `bash -n` / `zsh -n` parse
# their input and exit without running any of it, and they are this project's
# documented quality gate. Executing forms of the same script stay blocked.
NOEXEC_TMP="$(mktemp -d "${TMPDIR:-/tmp}/dex-guards-noexec.XXXXXX")"
cat > "$NOEXEC_TMP/payload.sh" <<'PAYLOAD'
#!/usr/bin/env bash
codex exec "do the work"
PAYLOAD
chmod +x "$NOEXEC_TMP/payload.sh"

assert_bash_allowed() {
  run_bash_guard "$(mkbashpayload "$2")"
  if printf '%s' "$GUARD_OUT" | grep -q 'BLOCKED'; then
    printf 'FAIL (expected allowed): %s\n%s\n' "$1" "$GUARD_OUT" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
}

assert_bash_allowed "bash -n on a codex-calling script" "bash -n $NOEXEC_TMP/payload.sh"
assert_bash_allowed "zsh -n on a codex-calling script" "zsh -n $NOEXEC_TMP/payload.sh"
assert_bash_allowed "noexec with clustered flags" "bash -en $NOEXEC_TMP/payload.sh"
assert_bash_allowed "noexec via -o noexec" "bash -o noexec $NOEXEC_TMP/payload.sh"
assert_bash_allowed "noexec with an inline payload" "bash -n -c 'codex exec build'"

assert_raw_codex_blocks "executing the same script" "bash $NOEXEC_TMP/payload.sh"
assert_raw_codex_blocks "noexec cancelled by a later +n" "bash -n +n $NOEXEC_TMP/payload.sh"
assert_raw_codex_blocks "noexec after -- is not an option" "bash -- -n $NOEXEC_TMP/payload.sh"
assert_raw_codex_blocks "unrelated long option is not noexec" "bash --norc $NOEXEC_TMP/payload.sh"
rm -rf "$NOEXEC_TMP"

# Running an interpreter on a script FILE must judge the file by what it
# actually launches, not by every string it happens to contain. Otherwise any
# script storing command-like strings — a guard's pattern table, a fixture —
# blocks, which made `python3 hooks/guard-handler.py` block on its own source.
FILE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/dex-guards-file.XXXXXX")"
cat > "$FILE_TMP/inert.py" <<'INERT'
import subprocess

DOCUMENTED_PATTERNS = ["rm -rf /", "rm -rf ~", "codex exec build"]


def describe():
    return "blocks: " + ", ".join(DOCUMENTED_PATTERNS)


def run_safe():
    subprocess.run(["git", "status", "--short"], check=False)
INERT
cat > "$FILE_TMP/hostile.py" <<'HOSTILE'
import subprocess

subprocess.run(["rm", "-rf", "/"], check=False)
HOSTILE
cat > "$FILE_TMP/hostile-codex.py" <<'HOSTILECODEX'
import subprocess

subprocess.run("codex exec 'do the work'", shell=True, check=False)
HOSTILECODEX

set +e
GUARD_OUT="$(mkbashpayload "python3 $FILE_TMP/inert.py" | env DEX_GUARD_EVENT=bash DX_PROVIDER_ENGINE=codex-plugin python3 "$HANDLER" 2>&1)"
GUARD_RC=$?
set -e
if [[ "$GUARD_RC" -eq 0 ]]; then
  pass=$((pass + 1))
else
  printf 'FAIL (script with inert command-like literals should be allowed; rc=%s)\n%s\n' \
    "$GUARD_RC" "$GUARD_OUT" >&2
  fail=$((fail + 1))
fi

set +e
GUARD_OUT="$(mkbashpayload "python3 $FILE_TMP/hostile.py" | env DEX_GUARD_EVENT=bash python3 "$HANDLER" 2>&1)"
GUARD_RC=$?
set -e
if [[ "$GUARD_RC" -eq 2 ]] && printf '%s' "$GUARD_OUT" | grep -q 'block-destructive-commands'; then
  pass=$((pass + 1))
else
  printf 'FAIL (script launching rm -rf / should block; rc=%s)\n%s\n' "$GUARD_RC" "$GUARD_OUT" >&2
  fail=$((fail + 1))
fi

assert_raw_codex_blocks "script launching codex via subprocess" "python3 $FILE_TMP/hostile-codex.py"

# The file scan must stay within the evaluation budget on a large, ordinary
# script. Fragment joins used to grow quadratically with the number of
# process-launch calls, so a benign ~20KB tooling script tripped the 2s
# timeout and — because block guards fail closed — was denied.
python3 - "$FILE_TMP/many-calls.py" <<'MANY'
import sys

lines = ["import subprocess", ""]
for i in range(160):
    lines.append(
        'subprocess.run(["tool%d", "run --check %d", "build --target %d", '
        '"lint --fix src/%d", "test -k case%d"], check=False)' % (i, i, i, i, i)
    )
with open(sys.argv[1], "w") as fh:
    fh.write("\n".join(lines) + "\n")
MANY
set +e
GUARD_OUT="$(mkbashpayload "python3 $FILE_TMP/many-calls.py" | env DEX_GUARD_EVENT=bash python3 "$HANDLER" 2>&1)"
GUARD_RC=$?
set -e
if [[ "$GUARD_RC" -eq 0 ]]; then
  pass=$((pass + 1))
else
  printf 'FAIL (large benign script must be allowed within the evaluation budget; rc=%s)\n%s\n' \
    "$GUARD_RC" "$GUARD_OUT" >&2
  fail=$((fail + 1))
fi

# Markdown table rows inside string literals open with a pipe, which no shell
# could execute; they used to reach the command-position scanner anyway and
# fail closed on their inline backtick spans.
python3 - "$FILE_TMP/doc-tables.py" <<'DOCTABLES'
import sys

tick = chr(96)
lines = [
    "import subprocess",
    "",
    'ROWS = ["| ' + tick + "action" + tick + ' | yes | warn, block |",',
    '        "| ' + tick + "pattern" + tick + ' | regex | matched input |"]',
    "",
    "def emit():",
    '    subprocess.run(["column", "-t", "-s", "|"], input="\\n".join(ROWS), text=True)',
]
with open(sys.argv[1], "w") as fh:
    fh.write("\n".join(lines) + "\n")
DOCTABLES
set +e
GUARD_OUT="$(mkbashpayload "python3 $FILE_TMP/doc-tables.py" | env DEX_GUARD_EVENT=bash python3 "$HANDLER" 2>&1)"
GUARD_RC=$?
set -e
if [[ "$GUARD_RC" -eq 0 ]]; then
  pass=$((pass + 1))
else
  printf 'FAIL (markdown table strings should be allowed; rc=%s)\n%s\n' "$GUARD_RC" "$GUARD_OUT" >&2
  fail=$((fail + 1))
fi

# A destructive payload that starts mid-argument-vector is still joined and
# caught after the suffix-join cap was introduced.
python3 - "$FILE_TMP/midvec.py" <<'MIDVEC'
import sys

with open(sys.argv[1], "w") as fh:
    fh.write('import subprocess\nsubprocess.run(["helper", "rm", "-rf", "~' + '/"])\n')
MIDVEC
set +e
GUARD_OUT="$(mkbashpayload "python3 $FILE_TMP/midvec.py" | env DEX_GUARD_EVENT=bash python3 "$HANDLER" 2>&1)"
GUARD_RC=$?
set -e
if [[ "$GUARD_RC" -eq 2 ]] && printf '%s' "$GUARD_OUT" | grep -q 'block-destructive-commands'; then
  pass=$((pass + 1))
else
  printf 'FAIL (mid-argument-vector rm payload should block; rc=%s)\n%s\n' "$GUARD_RC" "$GUARD_OUT" >&2
  fail=$((fail + 1))
fi
rm -rf "$FILE_TMP"

# Guard evaluation must fail closed. A blocking guard that cannot finish
# checking a command has to deny it; letting the call through would silently
# disable the guard exactly when the input is hostile.
GUARD_TMP="$(mktemp -d "${TMPDIR:-/tmp}/dex-guards-failclosed.XXXXXX")"
trap 'rm -rf "$GUARD_TMP" "$GUARD_HOME_TMP"' EXIT
mkdir -p "$GUARD_TMP/repo/.dex/guards"
git -C "$GUARD_TMP/repo" init -q

# A catastrophically backtracking pattern cannot resolve within the budget.
cat > "$GUARD_TMP/repo/.dex/guards/slow-block.md" <<'GUARD'
---
name: test-slow-block
enabled: true
event: bash
pattern: ^(a+)+$
action: block
---

Test guard: intentionally pathological pattern.
GUARD

redos_input="$(python3 -c 'print("a" * 4000 + "!")')"
set +e
GUARD_OUT="$(mkbashpayload "$redos_input" | (cd "$GUARD_TMP/repo" && env DEX_GUARD_EVENT=bash python3 "$HANDLER") 2>&1)"
GUARD_RC=$?
set -e
if [[ "$GUARD_RC" -eq 2 ]] && printf '%s' "$GUARD_OUT" | grep -q 'test-slow-block'; then
  pass=$((pass + 1))
else
  printf 'FAIL (blocking guard that timed out did not deny the command; rc=%s)\n%s\n' \
    "$GUARD_RC" "$GUARD_OUT" >&2
  fail=$((fail + 1))
fi

# The same timeout on a warn-only guard must not block.
sed 's/action: block/action: warn/; s/test-slow-block/test-slow-warn/' \
  "$GUARD_TMP/repo/.dex/guards/slow-block.md" > "$GUARD_TMP/repo/.dex/guards/slow-warn.md"
rm -f "$GUARD_TMP/repo/.dex/guards/slow-block.md"
set +e
GUARD_OUT="$(mkbashpayload "$redos_input" | (cd "$GUARD_TMP/repo" && env DEX_GUARD_EVENT=bash python3 "$HANDLER") 2>&1)"
GUARD_RC=$?
set -e
if [[ "$GUARD_RC" -eq 0 ]]; then
  pass=$((pass + 1))
else
  printf 'FAIL (warn guard timeout should not block; rc=%s)\n%s\n' "$GUARD_RC" "$GUARD_OUT" >&2
  fail=$((fail + 1))
fi

# A --- inside a frontmatter value must not end the frontmatter early. The
# old substring split dropped every key after such a value, so this block
# guard would have silently loaded as a warn guard.
cat > "$GUARD_TMP/repo/.dex/guards/dashes-block.md" <<'GUARD'
---
name: test-dashes-block
enabled: true
event: bash
pattern: forbidden---token
action: block
---

Test guard: pattern value contains the frontmatter fence characters.
GUARD
set +e
GUARD_OUT="$(mkbashpayload 'echo forbidden---token' | (cd "$GUARD_TMP/repo" && env DEX_GUARD_EVENT=bash python3 "$HANDLER") 2>&1)"
GUARD_RC=$?
set -e
if [[ "$GUARD_RC" -eq 2 ]] && printf '%s' "$GUARD_OUT" | grep -q 'test-dashes-block'; then
  pass=$((pass + 1))
else
  printf 'FAIL (guard with --- inside a value should keep its action: block; rc=%s)\n%s\n' \
    "$GUARD_RC" "$GUARD_OUT" >&2
  fail=$((fail + 1))
fi
rm -f "$GUARD_TMP/repo/.dex/guards/dashes-block.md"

# A benign command in a repo with project guards must still be allowed, so the
# fail-closed paths above cannot be passing for the wrong reason.
set +e
GUARD_OUT="$(mkbashpayload 'git status --short' | (cd "$GUARD_TMP/repo" && env DEX_GUARD_EVENT=bash python3 "$HANDLER") 2>&1)"
GUARD_RC=$?
set -e
if [[ "$GUARD_RC" -eq 0 ]]; then
  pass=$((pass + 1))
else
  printf 'FAIL (benign command should be allowed; rc=%s)\n%s\n' "$GUARD_RC" "$GUARD_OUT" >&2
  fail=$((fail + 1))
fi

# If the built-in guard set cannot be read at all, the safety baseline is
# absent — deny instead of running every tool call unguarded.
set +e
GUARD_OUT="$(mkbashpayload 'echo hello' | env DEX_GUARD_EVENT=bash DEX_DIR="$GUARD_TMP/empty-dex" \
  python3 "$HANDLER" 2>&1)"
GUARD_RC=$?
set -e
if [[ "$GUARD_RC" -eq 2 ]] && printf '%s' "$GUARD_OUT" | grep -q 'no built-in guards'; then
  pass=$((pass + 1))
else
  printf 'FAIL (missing built-in guards should block, got rc=%s)\n%s\n' "$GUARD_RC" "$GUARD_OUT" >&2
  fail=$((fail + 1))
fi

# An unexpected crash anywhere in the handler must deny rather than allow:
# exit 1 would let the call through with no guard evaluation at all.
mkdir -p "$GUARD_TMP/shim"
cat > "$GUARD_TMP/shim/sitecustomize.py" <<'SHIM'
import sys


class _FailingStdin:
    def isatty(self):
        return False

    def read(self, *args):
        raise RuntimeError("simulated stdin failure")


sys.stdin = _FailingStdin()
SHIM
set +e
GUARD_OUT="$(env DEX_GUARD_EVENT=bash PYTHONPATH="$GUARD_TMP/shim" python3 "$HANDLER" 2>&1)"
GUARD_RC=$?
set -e
if [[ "$GUARD_RC" -eq 2 ]] && printf '%s' "$GUARD_OUT" | grep -q 'guard evaluation failed'; then
  pass=$((pass + 1))
else
  printf 'FAIL (handler crash should block, got rc=%s)\n%s\n' "$GUARD_RC" "$GUARD_OUT" >&2
  fail=$((fail + 1))
fi

printf 'guards-test: %d passed, %d failed\n' "$pass" "$fail"
if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
exit 0
