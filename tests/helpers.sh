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
#
# Sourcing this also reports where a test died. Many assertions here are a bare
# `[[ … ]]` under `set -e`, which exits without a word — the runner then shows
# "FAIL(1)" over an empty log, and finding the line means re-running the whole
# file under `bash -x`. The ERR trap fires exactly where `set -e` would exit,
# so it adds a line to failures and nothing to passes.

# shellcheck disable=SC2034  # read by the trap below, which shellcheck cannot follow
__DX_TEST_FILE="${BASH_SOURCE[1]:-$0}"
__dx_test_died() {
  local exit_code=$?
  # An ERR trap fires whether or not errexit is on, so a test that deliberately
  # runs a failing command inside `set +e` would be reported as dying. Only say
  # something when the failure is actually about to stop the script.
  case "$-" in
    *e*) ;;
    *) return "$exit_code" ;;
  esac
  printf '%s:%s: failed (exit %s): %s\n' \
    "${BASH_SOURCE[1]##*/}" "${BASH_LINENO[0]}" "$exit_code" "$BASH_COMMAND" >&2
  return "$exit_code"
}
# errtrace propagates the trap into functions and subshells; without it an
# assertion inside a helper reports nothing, which is the case that matters.
set -E
trap '__dx_test_died' ERR

# assert_at <line> — a bare `[[ … ]]` assertion did not hold.
#
# bash 3.2 is /bin/bash on macOS, and what the macOS CI leg runs. It does not
# apply `set -e` to a failing `[[ … ]]` used as a statement, so 365 assertions
# across this suite passed there no matter what they claimed — a test could
# assert `"master" == "THIS-IS-WRONG"` and still report success. `false` and
# every ordinary command do trip errexit; only the `[[ … ]]` keyword does not.
#
# Writing `[[ … ]] || assert_at $LINENO` is explicit control flow, so it holds
# on every bash, and it names the line the way the silent form never could.
assert_at() {
  printf 'assertion failed at line %s\n' "$1" >&2
  exit 1
}

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

# wait_for_process_files <pid> <file> [file...]
# Wait for a fixture process to publish non-empty readiness files. A crashed
# child and a live child that times out are different failures and need
# different diagnostics.
wait_for_process_files() {
  local child_pid="${1:-}" timeout_seconds="${DX_TEST_SERVER_START_TIMEOUT:-15}"
  local deadline now_epoch all_ready target_file missing_files child_exit
  shift || true

  if [[ ! "$child_pid" =~ ^[0-9]+$ || $# -eq 0 ]]; then
    printf 'wait_for_process_files requires a pid and at least one file\n' >&2
    return 2
  fi
  if [[ ! "$timeout_seconds" =~ ^[1-9][0-9]*$ ]]; then
    printf 'DX_TEST_SERVER_START_TIMEOUT must be a positive integer\n' >&2
    return 2
  fi

  deadline=$(( $(date +%s) + timeout_seconds ))
  while :; do
    all_ready=1
    missing_files=""
    for target_file in "$@"; do
      if [[ ! -s "$target_file" ]]; then
        all_ready=0
        missing_files="${missing_files}${missing_files:+, }${target_file}"
      fi
    done

    if [[ "$all_ready" -eq 1 ]]; then
      if kill -0 "$child_pid" 2>/dev/null; then
        return 0
      fi
      child_exit=0
      wait "$child_pid" 2>/dev/null || child_exit=$?
      printf 'fixture process %s exited with status %s after publishing readiness files\n' \
        "$child_pid" "$child_exit" >&2
      return 1
    fi

    if ! kill -0 "$child_pid" 2>/dev/null; then
      child_exit=0
      wait "$child_pid" 2>/dev/null || child_exit=$?
      printf 'fixture process %s exited before publishing readiness files (status %s): %s\n' \
        "$child_pid" "$child_exit" "$missing_files" >&2
      return 1
    fi

    now_epoch=$(date +%s)
    if [[ "$now_epoch" -ge "$deadline" ]]; then
      printf 'fixture process %s did not publish readiness files within %ss: %s\n' \
        "$child_pid" "$timeout_seconds" "$missing_files" >&2
      return 1
    fi
    sleep 0.1
  done
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
