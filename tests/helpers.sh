# shellcheck shell=bash
# Shared assertions for the Dex test suite.
#
#   source "$ROOT/tests/helpers.sh"
#
# These were previously copy-pasted per test file and had drifted: some
# assert_contains used `grep -qF`, some `-Fq`, some `-Fq --`. Only the last
# handles a needle that starts with a dash, so a test asserting on `--flag`
# silently checked something else. One definition avoids that.
#
# Every helper exits non-zero on failure rather than only printing, so a test
# cannot pass by ignoring a result.

# assert_eq <expected> <actual> <label>
assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [[ "$expected" != "$actual" ]]; then
    printf 'assertion failed for %s: expected %s, got %s\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi
}

# assert_contains <needle> <file>
assert_contains() {
  local needle="$1" file="$2"
  if ! grep -Fq -- "$needle" "$file" 2>/dev/null; then
    printf 'missing expected text: %s\n' "$needle" >&2
    printf 'output was:\n' >&2
    cat "$file" >&2 2>/dev/null || printf '(no such file: %s)\n' "$file" >&2
    exit 1
  fi
}

# assert_not_contains <needle> <file>
assert_not_contains() {
  local needle="$1" file="$2"
  if grep -Fq -- "$needle" "$file" 2>/dev/null; then
    printf 'unexpected text: %s\n' "$needle" >&2
    printf 'output was:\n' >&2
    cat "$file" >&2
    exit 1
  fi
}

# assert_rejected <label> <command...> — the command must fail
assert_rejected() {
  local label="$1"
  shift
  if "$@"; then
    printf '%s: expected command to fail\n' "$label" >&2
    exit 1
  fi
}

# request_count <file> — lines in a request log, 0 when it does not exist yet.
# A fake HTTP server writes one line per request; "no file" and "no requests"
# have to read the same or the first assertion in a test races the server.
request_count() {
  local file="$1"
  [[ -f "$file" ]] || {
    printf '0\n'
    return 0
  }
  wc -l < "$file" | tr -d '[:space:]'
}

# assert_file <path>
assert_file() {
  if [[ ! -f "$1" ]]; then
    printf 'missing file: %s\n' "$1" >&2
    exit 1
  fi
}

# assert_no_file <path>
assert_no_file() {
  if [[ -e "$1" ]]; then
    printf 'unexpected file: %s\n' "$1" >&2
    exit 1
  fi
}

# assert_dir <path>
assert_dir() {
  if [[ ! -d "$1" ]]; then
    printf 'missing directory: %s\n' "$1" >&2
    exit 1
  fi
}

# fail <message...>
fail() {
  printf '%s\n' "$*" >&2
  exit 1
}
