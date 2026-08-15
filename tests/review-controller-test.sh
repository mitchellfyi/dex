#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-review-controller-test.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

run_shell_suite() {
  local shell_name="$1"

  # The selected shell expands this script using the environment set below.
  # shellcheck disable=SC2016
  DEX_DIR="$ROOT" TEST_TMP_DIR="$TMP_DIR/$shell_name" TEST_SHELL_NAME="$shell_name" "$shell_name" -c '
    set -eu
    source "$DEX_DIR/lib/lock.sh"
    source "$DEX_DIR/lib/review.sh"
    source "$DEX_DIR/lib/review-controller.sh"
    mkdir -p "$TEST_TMP_DIR"

    assert_transition() {
      local expected label actual
      expected=$(printf "%b" "$1")
      label="$2"
      shift 2
      actual=$(dx_review_transition "$@") || {
        printf "%s: transition was rejected\n" "$label" >&2
        exit 1
      }
      if [ "$actual" != "$expected" ]; then
        printf "%s: expected <%s>, got <%s>\n" "$label" "$expected" "$actual" >&2
        exit 1
      fi
    }

    assert_rejected() {
      local label="$1"
      shift
      if dx_review_transition "$@" >/dev/null 2>&1; then
        printf "%s: expected transition rejection\n" "$label" >&2
        exit 1
      fi
    }

    assert_transition \
      "1\tcount\tsmall\t3\t2\tnone\t-\tappend\tkeep\tkeep\twrite\tkeep" \
      "clean increments the streak" \
      small 3 1 clean 0 none false false - 0 - - none false

    assert_transition \
      "1\tcomplete\tsmall\t3\t3\tnone\t-\tappend\tkeep\tkeep\tinvalidate\tfinalize" \
      "clean at the gate completes" \
      small 3 2 clean 0 none false false - 0 - - none false

    assert_transition \
      "1\tcomplete\tsmall\t1\t1\tnone\t-\tappend\tkeep\tkeep\tinvalidate\tfinalize" \
      "a one-pass gate completes" \
      small 1 0 clean 0 none false false - 0 - - none false

    assert_transition \
      "1\tpause\tsmall\t3\t0\tclean_mutated_scope\t-\treset\tkeep\tinvalidate\tinvalidate\tinvalidate" \
      "clean scope mutation pauses" \
      small 3 2 clean 0 none true true - 0 - - none false

    assert_transition \
      "1\treset_continue\tsmall\t3\t0\tnone\t-\treset\tappend\trefresh\twrite\tinvalidate" \
      "fixed findings reset the streak" \
      small 3 2 findings_fixed 1 none true true - 0 - - none false

    assert_transition \
      "1\tpause\tsmall\t3\t0\tclaimed_fix_without_change\t-\treset\tkeep\tkeep\twrite\tinvalidate" \
      "a false fix pauses" \
      small 3 2 findings_fixed 1 none false false - 0 - - none false

    assert_transition \
      "1\treset_continue\tsmall\t3\t0\tnone\t-\treset\tappend\trefresh\twrite\tinvalidate" \
      "a committed content fix resets the streak" \
      small 3 2 findings_fixed 1 none true false - 0 - - none false

    assert_transition \
      "1\treset_continue\tsmall\t3\t0\tnone\t-\treset\tappend\trefresh\twrite\tinvalidate" \
      "a working-tree fix resets the streak" \
      small 3 2 findings_fixed 1 none false true - 0 - - none false

    assert_transition \
      "1\tpause\tsmall\t3\t0\trepeated_fingerprint\t-\treset\tappend\tinvalidate\tinvalidate\tinvalidate" \
      "repeated findings pause" \
      small 3 0 findings_fixed 1 none true true - 0 - - repeated_fingerprint false

    assert_transition \
      "1\tpause\tsmall\t3\t0\talternating_fingerprints\t-\treset\tappend\tinvalidate\tinvalidate\tinvalidate" \
      "alternating findings pause" \
      small 3 0 findings_fixed 1 none true true - 0 - - alternating_fingerprints false

    assert_transition \
      "1\tescalate_continue\tcomplex\t9\t0\tnone\t-\treset\tappend\trefresh\twrite\tinvalidate" \
      "post-fix floor escalation raises the tier" \
      small 3 1 findings_fixed 2 none true true complex 9 deterministic-floor cross-module none false

    assert_transition \
      "1\treset_continue\tnormal\t6\t0\tnone\t-\treset\tappend\trefresh\twrite\tinvalidate" \
      "a lower post-fix floor does not downgrade the tier" \
      normal 6 1 findings_fixed 2 none true true small 3 deterministic-floor localized-change,focused-verification none false

    assert_transition \
      "1\tpause\tsmall\t3\t0\tunresolved_findings\t2\treset\tkeep\tkeep\twrite\tinvalidate" \
      "unresolved findings pause" \
      small 3 1 findings 2 none false false - 0 - - none false

    assert_transition \
      "1\tpause\tsmall\t3\t0\tblocked\tmissing-tool\treset\tkeep\tkeep\twrite\tinvalidate" \
      "a blocker pauses" \
      small 3 1 blocked 0 missing-tool false false - 0 - - none false

    assert_transition \
      "1\tpause\tsmall\t3\t0\tblocked\tmissing-tool\treset\tkeep\tinvalidate\tinvalidate\tinvalidate" \
      "a blocker after scope mutation invalidates authorization" \
      small 3 1 blocked 0 missing-tool true true - 0 - - none false

    assert_transition \
      "1\tpause\tsmall\t3\t0\twave_reported_churn\trepeated-fingerprint\treset\tkeep\tkeep\twrite\tinvalidate" \
      "reported churn pauses" \
      small 3 1 churn 0 repeated-fingerprint false false - 0 - - none false

    assert_transition \
      "1\tescalate_continue\tnormal\t6\t0\tnone\t-\treset\tkeep\trefresh\twrite\tinvalidate" \
      "an upward escalation continues" \
      small 3 2 escalate 0 cross-module false false normal 6 wave-escalation wave-escalation none false

    assert_transition \
      "1\tescalate_continue\tnormal\t8\t0\tnone\t-\treset\tkeep\trefresh\twrite\tinvalidate" \
      "an escalation preserves a higher operator gate" \
      small 8 2 escalate 0 cross-module false false normal 6 wave-escalation wave-escalation none false

    assert_transition \
      "1\tpause\tnormal\t6\t0\tinvalid_escalation\tsmall\treset\tkeep\tkeep\twrite\tinvalidate" \
      "a downward escalation pauses" \
      normal 6 2 escalate 0 localized-change false false small 3 wave-escalation wave-escalation none false

    assert_transition \
      "1\tpause\tsmall\t3\t0\tescalation_mutated_scope\tnormal\treset\tkeep\tinvalidate\tinvalidate\tinvalidate" \
      "a mutating escalation pauses" \
      small 3 2 escalate 0 cross-module true true normal 6 wave-escalation wave-escalation none false

    assert_transition \
      "1\tpause\tsmall\t3\t0\tprovider_error\t-\treset\tkeep\tkeep\twrite\tinvalidate" \
      "an ordinary failure preserves resumable authorization" \
      small 3 2 failure 0 provider_error false false - 0 - - none false

    assert_transition \
      "1\tpause\tsmall\t3\t0\treview_criteria_changed\t-\treset\tkeep\tinvalidate\tinvalidate\tinvalidate" \
      "an authorization failure invalidates state" \
      small 3 2 failure 0 review_criteria_changed false false - 0 - - none true

    assert_rejected "missing arguments" small 3 0 clean
    assert_rejected "unknown tier" tiny 3 0 clean 0 none false false - 0 - - none false
    assert_rejected "zero requirement" small 0 0 clean 0 none false false - 0 - - none false
    assert_rejected "completed state" small 3 3 clean 0 none false false - 0 - - none false
    assert_rejected "unknown event" small 3 0 retry 0 none false false - 0 - - none false
    assert_rejected "invalid boolean" small 3 0 clean 0 none yes false - 0 - - none false
    assert_rejected "clean with a count" small 3 0 clean 1 none false false - 0 - - none false
    assert_rejected "findings without a count" small 3 0 findings 0 none false false - 0 - - none false
    assert_rejected "blocker without a reason" small 3 0 blocked 0 none false false - 0 - - none false
    assert_rejected "candidate fields without a tier" small 3 0 clean 0 none false false - 6 wave-escalation wave-escalation none false
    assert_rejected "escalation without a candidate" small 3 0 escalate 0 cross-module false false - 0 - - none false
    assert_rejected "candidate reason contradicts its tier" small 3 0 findings_fixed 1 none true true normal 6 deterministic-floor cross-module none false
    assert_rejected "wave escalation requires its reserved reason" small 3 0 escalate 0 cross-module false false normal 6 wave-escalation arbitrary none false
    assert_rejected "churn on the wrong event" small 3 0 clean 0 none false false - 0 - - repeated_fingerprint false
    assert_rejected "authorization invalidation on a clean event" small 3 0 clean 0 none false false - 0 - - none true

    history_file="$TEST_TMP_DIR/nested/findings"
    dx_review_findings_history_append "$history_file" 0000000000000001
    dx_review_findings_history_append "$history_file" 0000000000000002
    dx_review_findings_history_append "$history_file" 0000000000000003
    dx_review_findings_history_append "$history_file" 0000000000000004
    dx_review_findings_history_append "$history_file" 0000000000000005
    expected_history="0000000000000002
0000000000000003
0000000000000004
0000000000000005"
    actual_history=$(cat "$history_file")
    if [ "$actual_history" != "$expected_history" ]; then
      printf "bounded history: expected <%s>, got <%s>\n" "$expected_history" "$actual_history" >&2
      exit 1
    fi

    before=$(cat "$history_file")
    if dx_review_findings_history_append "$history_file" INVALID >/dev/null 2>&1; then
      printf "invalid appended hash was accepted\n" >&2
      exit 1
    fi
    if [ "$(cat "$history_file")" != "$before" ]; then
      printf "invalid appended hash changed history\n" >&2
      exit 1
    fi

    printf "%s\n" malformed > "$history_file"
    if dx_review_findings_history_append "$history_file" 0000000000000006 >/dev/null 2>&1; then
      printf "malformed existing history was accepted\n" >&2
      exit 1
    fi
    if [ "$(cat "$history_file")" != malformed ]; then
      printf "malformed existing history was changed\n" >&2
      exit 1
    fi
    if find "$(dirname "$history_file")" -maxdepth 1 -name "$(basename "$history_file").tmp.*" -print -quit | grep -q .; then
      printf "history helper left a temporary file\n" >&2
      exit 1
    fi

    no_newline_history="$TEST_TMP_DIR/no-newline-findings"
    printf "%s" 0000000000000001 > "$no_newline_history"
    dx_review_findings_history_append "$no_newline_history" 0000000000000002
    expected_history="0000000000000001
0000000000000002"
    if [ "$(cat "$no_newline_history")" != "$expected_history" ]; then
      printf "history helper did not normalize a missing final newline\n" >&2
      exit 1
    fi

    repeated_history="$TEST_TMP_DIR/repeated-findings"
    dx_review_findings_history_append "$repeated_history" aaaaaaaaaaaaaaaa
    dx_review_findings_history_append "$repeated_history" aaaaaaaaaaaaaaaa
    dx_review_findings_history_append "$repeated_history" aaaaaaaaaaaaaaaa
    if [ "$(dx_review_findings_churn_kind "$repeated_history")" != repeated_fingerprint ]; then
      printf "bounded history lost repeated-fingerprint detection\n" >&2
      exit 1
    fi

    alternating_history="$TEST_TMP_DIR/alternating-findings"
    dx_review_findings_history_append "$alternating_history" aaaaaaaaaaaaaaaa
    dx_review_findings_history_append "$alternating_history" bbbbbbbbbbbbbbbb
    dx_review_findings_history_append "$alternating_history" aaaaaaaaaaaaaaaa
    dx_review_findings_history_append "$alternating_history" bbbbbbbbbbbbbbbb
    if [ "$(dx_review_findings_churn_kind "$alternating_history")" != alternating_fingerprints ]; then
      printf "bounded history lost alternating-fingerprint detection\n" >&2
      exit 1
    fi

    directory_target="$TEST_TMP_DIR/history-directory"
    mkdir -p "$directory_target"
    if dx_review_findings_history_append "$directory_target" 0000000000000007 >/dev/null 2>&1; then
      printf "history helper accepted a directory target\n" >&2
      exit 1
    fi

    concurrency_violation=0
    round=1
    while [ "$round" -le 50 ]; do
      concurrent_history="$TEST_TMP_DIR/concurrent-$round"
      concurrent_results="$TEST_TMP_DIR/concurrent-$round-results"
      mkdir -p "$concurrent_results"
      DX_CONCURRENT_HISTORY="$concurrent_history" DX_CONCURRENT_RESULT="$concurrent_results/one" \
        DEX_DIR="$DEX_DIR" "$TEST_SHELL_NAME" -c "
          source \"\$DEX_DIR/lib/review.sh\"
          source \"\$DEX_DIR/lib/review-controller.sh\"
          dx_review_findings_history_append \"\$DX_CONCURRENT_HISTORY\" 0000000000000008 &&
            : > \"\$DX_CONCURRENT_RESULT\"
        " &
      first_pid=$!
      DX_CONCURRENT_HISTORY="$concurrent_history" DX_CONCURRENT_RESULT="$concurrent_results/two" \
        DEX_DIR="$DEX_DIR" "$TEST_SHELL_NAME" -c "
          source \"\$DEX_DIR/lib/review.sh\"
          source \"\$DEX_DIR/lib/review-controller.sh\"
          dx_review_findings_history_append \"\$DX_CONCURRENT_HISTORY\" 0000000000000009 &&
            : > \"\$DX_CONCURRENT_RESULT\"
        " &
      second_pid=$!
      wait "$first_pid" || true
      wait "$second_pid" || true
      successes=$(find "$concurrent_results" -type f | wc -l | tr -d " ")
      recorded=0
      [ ! -f "$concurrent_history" ] || recorded=$(wc -l < "$concurrent_history" | tr -d " ")
      if [ "$successes" -eq 2 ] && [ "$recorded" -ne 2 ]; then
        concurrency_violation=1
        break
      fi
      round=$((round + 1))
    done
    if [ "$concurrency_violation" -ne 0 ]; then
      printf "concurrent history calls reported success while losing an update\n" >&2
      exit 1
    fi
  '
}

run_shell_suite bash
run_shell_suite zsh

printf 'review-controller-test passed\n'
