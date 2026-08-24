#!/usr/bin/env bash
# shellcheck disable=SC2016
# Fixture bodies are single-quoted so their variables expand in the child.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-test-manifest.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

MANIFEST="$ROOT/tests/manifest.tsv"
assert_file "$MANIFEST"

# The checked-in manifest is the complete inventory, not a best-effort list.
find "$ROOT/tests" -maxdepth 1 -type f -name '*-test.sh' -print \
  | sed 's#^.*/##' | sort > "$TMP_DIR/discovered"
awk -F '\t' '!/^#/ && NF { print $1 }' "$MANIFEST" | sort > "$TMP_DIR/declared"
assert_eq "$(cat "$TMP_DIR/discovered")" "$(cat "$TMP_DIR/declared")" \
  "checked-in test manifest inventory"

suite_dir="$TMP_DIR/suite"
mkdir -p "$suite_dir"

apply_fixture() {
  local name="$1" body="$2"
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
    printf '%s\n' "$body"
  } > "$suite_dir/$name"
  chmod +x "$suite_dir/$name"
}

apply_fixture "a-hermetic-test.sh" \
  'printf "%s|%s|%s|%s|%s|%s|%s|%s\n" "$HOME" "$XDG_CONFIG_HOME" "$CODEX_HOME" "$DX_STATE_DIR" "$ZDOTDIR" "$DX_MAINTENANCE_DIR" "$DX_RTK_INSTALL_DIR" "$GIT_CONFIG_GLOBAL" > "$DX_TEST_REPORT_DIR/a.env"; printf "%s|%s|%s|%s|%s\n" "${DX_PARENT_SECRET-unset}" "${GITHUB_TOKEN-unset}" "${OPENAI_API_KEY-unset}" "${DX_PROVIDER_PROFILE-unset}" "${SSH_AUTH_SOCK-unset}" > "$DX_TEST_REPORT_DIR/a.parent-env"'
apply_fixture "b-hermetic-test.sh" \
  'printf "%s|%s|%s|%s|%s|%s|%s|%s\n" "$HOME" "$XDG_CONFIG_HOME" "$CODEX_HOME" "$DX_STATE_DIR" "$ZDOTDIR" "$DX_MAINTENANCE_DIR" "$DX_RTK_INSTALL_DIR" "$GIT_CONFIG_GLOBAL" > "$DX_TEST_REPORT_DIR/b.env"'
apply_fixture "c-shared-test.sh" \
  '[[ "$HOME" == "$DX_EXPECTED_SHARED_HOME" ]] || exit 9'
apply_fixture "d-linux-test.sh" \
  'printf "linux\n" > "$DX_TEST_REPORT_DIR/platform"'
apply_fixture "e-macos-test.sh" \
  'printf "macos\n" >> "$DX_TEST_REPORT_DIR/platform"'
apply_fixture "f-timeout-test.sh" \
  'sleep 2'
apply_fixture "g-zsh-test.sh" \
  'zsh -fc "print -r -- isolated" > "$DX_TEST_REPORT_DIR/zsh-result"'

fixture_manifest="$TMP_DIR/fixture-manifest.tsv"
printf '%s\n' \
  $'a-hermetic-test.sh\tfast\tall\t10\thermetic' \
  $'b-hermetic-test.sh\tfast\tall\t10\thermetic' \
  $'c-shared-test.sh\tslow\tall\t10\tshared' \
  $'d-linux-test.sh\tfast\tlinux\t10\thermetic' \
  $'e-macos-test.sh\tfast\tmacos\t10\thermetic' \
  $'f-timeout-test.sh\tfast\tmacos\t1\thermetic' \
  $'g-zsh-test.sh\tfast\tall\t10\thermetic' > "$fixture_manifest"

shared_home="$TMP_DIR/shared-home"
shared_zdot="$TMP_DIR/shared-zdot"
shared_dex_state="$TMP_DIR/shared-dex-state"
good_report="$TMP_DIR/good-report"
mkdir -p "$shared_home" "$shared_zdot" "$good_report"
printf 'exit 17\n' > "$shared_zdot/.zshenv"
DX_TEST_SUITE_DIR="$suite_dir" \
DX_TEST_MANIFEST="$fixture_manifest" \
DX_TEST_LOG_DIR="$TMP_DIR/good-logs" \
DX_TEST_PLATFORM=linux \
DX_TEST_JOBS=2 \
DX_TEST_REPORT_DIR="$good_report" \
DX_EXPECTED_SHARED_HOME="$shared_home" \
DX_PARENT_SECRET="parent-secret" \
GITHUB_TOKEN="github-secret" \
OPENAI_API_KEY="openai-secret" \
DX_PROVIDER_PROFILE="host-provider" \
SSH_AUTH_SOCK="$TMP_DIR/agent.sock" \
HOME="$shared_home" \
ZDOTDIR="$shared_zdot" \
DX_MAINTENANCE_DIR="$shared_dex_state/maintenance" \
DX_RTK_INSTALL_DIR="$shared_dex_state/rtk" \
GIT_CONFIG_GLOBAL="$shared_dex_state/gitconfig" \
  bash "$ROOT/tests/run-all.sh" > "$TMP_DIR/good.out"

assert_contains "5 selected, 2 skipped for linux" "$TMP_DIR/good.out"
assert_eq "linux" "$(cat "$good_report/platform")" "platform selection"
assert_eq "isolated" "$(cat "$good_report/zsh-result")" "zsh startup isolation"
assert_eq "unset|unset|unset|unset|unset" "$(cat "$good_report/a.parent-env")" \
  "hermetic parent environment"
assert_not_contains "macos" "$good_report/platform"
assert_not_contains "$shared_home" "$good_report/a.env"
assert_not_contains "$shared_home" "$good_report/b.env"
assert_not_contains "$shared_dex_state" "$good_report/a.env"
assert_not_contains "$shared_dex_state" "$good_report/b.env"
if [[ "$(cat "$good_report/a.env")" == "$(cat "$good_report/b.env")" ]]; then
  fail "hermetic tests shared their state directories"
fi

# Reusing a log directory must not count result files from an earlier run.
mkdir -p "$TMP_DIR/reused-report"
DX_TEST_SUITE_DIR="$suite_dir" \
DX_TEST_MANIFEST="$fixture_manifest" \
DX_TEST_LOG_DIR="$TMP_DIR/good-logs" \
DX_TEST_PLATFORM=linux \
DX_TEST_REPORT_DIR="$TMP_DIR/reused-report" \
  bash "$ROOT/tests/run-all.sh" a-hermetic > "$TMP_DIR/reused.out"
assert_contains "== 1 passed, 0 failed ==" "$TMP_DIR/reused.out"

# Lane and shard selection use the validated manifest order. With four Linux
# fast tests, shard 2/2 contains the second and fourth entries.
shard_report="$TMP_DIR/shard-report"
mkdir -p "$shard_report"
DX_TEST_SUITE_DIR="$suite_dir" \
DX_TEST_MANIFEST="$fixture_manifest" \
DX_TEST_LOG_DIR="$TMP_DIR/shard-logs" \
DX_TEST_PLATFORM=linux \
DX_TEST_LANES=fast \
DX_TEST_SHARD=2/2 \
DX_TEST_REPORT_DIR="$shard_report" \
  bash "$ROOT/tests/run-all.sh" > "$TMP_DIR/shard.out"
assert_contains "2 selected" "$TMP_DIR/shard.out"
assert_no_file "$shard_report/a.env"
assert_file "$shard_report/b.env"
assert_no_file "$shard_report/platform"
assert_file "$shard_report/zsh-result"

# The timeout is part of each row rather than one machine-wide guess.
if DX_TEST_SUITE_DIR="$suite_dir" DX_TEST_MANIFEST="$fixture_manifest" \
  DX_TEST_LOG_DIR="$TMP_DIR/timeout-logs" DX_TEST_PLATFORM=macos \
  bash "$ROOT/tests/run-all.sh" f-timeout > "$TMP_DIR/timeout.out" 2>&1; then
  fail "a test exceeded its manifest timeout without failing"
fi
assert_contains "timeout 1s" "$TMP_DIR/timeout.out"

# Invalid metadata and incomplete inventories fail before any test starts.
printf '%s\n' \
  $'a-hermetic-test.sh\tunknown\tall\t10\thermetic' \
  $'b-hermetic-test.sh\tfast\tall\t10\thermetic' \
  $'c-shared-test.sh\tslow\tall\t10\tshared' \
  $'d-linux-test.sh\tfast\tlinux\t10\thermetic' \
  $'e-macos-test.sh\tfast\tmacos\t10\thermetic' \
  $'f-timeout-test.sh\tfast\tmacos\t1\thermetic' \
  $'g-zsh-test.sh\tfast\tall\t10\thermetic' > "$TMP_DIR/bad-lane.tsv"
if DX_TEST_SUITE_DIR="$suite_dir" DX_TEST_MANIFEST="$TMP_DIR/bad-lane.tsv" \
  DX_TEST_LOG_DIR="$TMP_DIR/bad-lane-logs" \
  bash "$ROOT/tests/run-all.sh" > "$TMP_DIR/bad-lane.out" 2>&1; then
  fail "an unknown manifest lane was accepted"
fi
assert_contains "unknown test lane" "$TMP_DIR/bad-lane.out"

awk '$1 !~ /^f-timeout-test.sh/' "$fixture_manifest" > "$TMP_DIR/incomplete.tsv"
if DX_TEST_SUITE_DIR="$suite_dir" DX_TEST_MANIFEST="$TMP_DIR/incomplete.tsv" \
  DX_TEST_LOG_DIR="$TMP_DIR/incomplete-logs" \
  bash "$ROOT/tests/run-all.sh" > "$TMP_DIR/incomplete.out" 2>&1; then
  fail "an incomplete test manifest was accepted"
fi
assert_contains "tests missing from manifest: f-timeout-test.sh" "$TMP_DIR/incomplete.out"

printf '%s\n' \
  "$(cat "$fixture_manifest")" \
  $'a-hermetic-test.sh\tfast\tall\t10\thermetic' > "$TMP_DIR/duplicate.tsv"
if DX_TEST_SUITE_DIR="$suite_dir" DX_TEST_MANIFEST="$TMP_DIR/duplicate.tsv" \
  DX_TEST_LOG_DIR="$TMP_DIR/duplicate-logs" \
  bash "$ROOT/tests/run-all.sh" > "$TMP_DIR/duplicate.out" 2>&1; then
  fail "a duplicate manifest entry was accepted"
fi
assert_contains "duplicate test manifest entry: a-hermetic-test.sh" "$TMP_DIR/duplicate.out"

printf 'test manifest tests passed\n'
