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
