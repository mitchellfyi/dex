#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-research-orchestrate-test.XXXXXX")"
HARNESS_DIR="$TMP_DIR/research"
STUB_BIN="$TMP_DIR/bin"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT


mkdir -p "$HARNESS_DIR/lib" "$HARNESS_DIR/results" "$STUB_BIN" "$TMP_DIR/repo"
cp "$ROOT/research/orchestrate.sh" "$HARNESS_DIR/orchestrate.sh"
git -C "$TMP_DIR/repo" init -q

cat > "$HARNESS_DIR/lib/common.sh" <<'STUB'
#!/usr/bin/env bash
RESEARCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEX_DIR="$(cd "$RESEARCH_DIR/../repo" && pwd)"
RESULTS_DIR="$RESEARCH_DIR/results"
SCENARIO_TIMEOUT=3600
RESEARCH_RUNNER="${RESEARCH_RUNNER:-claude}"

log_error() { printf '[ERROR] %s\n' "$*" >&2; }
log_info() { printf '[INFO] %s\n' "$*" >&2; }
dx_branch() { printf 'research/parser-test\n'; }
json_field() { printf '95\n'; }
STUB

cat > "$HARNESS_DIR/lib/report.sh" <<'STUB'
#!/usr/bin/env bash
STUB

cat > "$HARNESS_DIR/lib/safety.sh" <<'STUB'
#!/usr/bin/env bash
safety_check_branch() { :; }
safety_check_clean() { :; }
STUB

cat > "$HARNESS_DIR/run.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'timeout=%s args=' "${SCENARIO_TIMEOUT_OVERRIDE:-unset}"
  printf '[%s]' "$@"
  printf '\n'
} >> "$ARGS_LOG"
mkdir -p "$(dirname "$ARGS_LOG")/research/results/run-stub"
printf '{"aggregate_score":95}\n' > "$(dirname "$ARGS_LOG")/research/results/run-stub/summary.json"
printf 'run-stub\n'
STUB

cat > "$HARNESS_DIR/improve.sh" <<'STUB'
#!/usr/bin/env bash
printf 'improve.sh must not run in this test\n' >&2
exit 97
STUB

cat > "$STUB_BIN/sleep" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
count=0
[[ ! -f "$SLEEP_STATE" ]] || read -r count < "$SLEEP_STATE"
count=$((count + 1))
printf '%s\n' "$count" > "$SLEEP_STATE"
((count <= 1))
STUB

chmod +x "$HARNESS_DIR/orchestrate.sh" "$HARNESS_DIR/run.sh" \
  "$HARNESS_DIR/improve.sh" "$STUB_BIN/sleep"

run_success() {
  local name="$1" expected="$2"
  shift 2
  local output="$TMP_DIR/$name.out"
  local args_log="$TMP_DIR/$name.args"
  local sleep_state="$TMP_DIR/$name.sleep"

  : > "$args_log"
  printf '0\n' > "$sleep_state"
  PATH="$STUB_BIN:$PATH" ARGS_LOG="$args_log" SLEEP_STATE="$sleep_state" \
    bash "$HARNESS_DIR/orchestrate.sh" "$@" > "$output" 2>&1 || {
      cat "$output" >&2
      fail "$name should have succeeded"
    }

  [[ "$(wc -l < "$args_log" | tr -d ' ')" == "1" ]] || {
    cat "$args_log" >&2
    fail "$name should have run exactly one research cycle"
  }
  assert_contains "$expected" "$args_log"
  assert_contains "Max cycles:       1" "$output"
}

expect_failure() {
  local name="$1" expected="$2"
  shift 2
  local output="$TMP_DIR/$name.out"

  if PATH="$STUB_BIN:$PATH" ARGS_LOG="$TMP_DIR/$name.args" SLEEP_STATE="$TMP_DIR/$name.sleep" \
    bash "$HARNESS_DIR/orchestrate.sh" "$@" > "$output" 2>&1; then
    cat "$output" >&2
    fail "$name should have failed"
  fi
  assert_contains "$expected" "$output"
  [[ ! -s "$TMP_DIR/$name.args" ]] || fail "$name started a research run"
}

run_success \
  spaced-values \
  'timeout=60 args=[--runner][claude][--skip-llm-judge][--iteration][1]' \
  --max-cycles 0001 --scenario-timeout 0060 --runner claude --allow-main

# No --runner/--scenario at all: RUN_FLAGS stays empty, which used to crash
# macOS bash 3.2 with "RUN_FLAGS[@]: unbound variable" under set -u.
run_success \
  no-run-flags \
  'timeout=60 args=[--skip-llm-judge][--iteration][1]' \
  --max-cycles 1 --scenario-timeout 60 --allow-main

run_success \
  equals-values \
  'timeout=61 args=[--runner][codex][--skip-llm-judge][--iteration][1]' \
  --max-cycles=1 --scenario-timeout=61 --runner=codex --allow-main

expect_failure unknown-option 'Unknown option: --bogus' --bogus
expect_failure unknown-short-option 'Unknown option: -x' -x
expect_failure positional-argument 'Unexpected argument: stray' stray

expect_failure max-missing '--max-cycles requires a value.' --max-cycles
expect_failure max-missing-before-option '--max-cycles requires a value.' --max-cycles --allow-main
expect_failure max-missing-before-help '--max-cycles requires a value.' --max-cycles -h
expect_failure max-empty '--max-cycles requires a value.' --max-cycles=
expect_failure timeout-missing '--scenario-timeout requires a value.' --scenario-timeout
expect_failure timeout-empty '--scenario-timeout requires a value.' --scenario-timeout=
expect_failure runner-missing '--runner requires a value.' --runner
expect_failure runner-empty '--runner requires a value.' --runner=

expect_failure max-zero "Invalid value for --max-cycles: '0'." --max-cycles 0
expect_failure max-negative "Invalid value for --max-cycles: '-1'." --max-cycles=-1
expect_failure max-decimal "Invalid value for --max-cycles: '1.5'." --max-cycles 1.5
expect_failure max-overflow "Invalid value for --max-cycles: '9223372036854775808'." --max-cycles=9223372036854775808
expect_failure timeout-zero "Invalid value for --scenario-timeout: '0'." --scenario-timeout=0
expect_failure timeout-negative "Invalid value for --scenario-timeout: '-1'." --scenario-timeout -1
expect_failure timeout-text "Invalid value for --scenario-timeout: 'fast'." --scenario-timeout=fast
expect_failure runner-invalid 'Unknown runner: other' --runner=other

bash "$HARNESS_DIR/orchestrate.sh" --help > "$TMP_DIR/help.out"
assert_contains 'N must be positive; omit this' "$TMP_DIR/help.out"
assert_contains 'Value options also accept --option=value.' "$TMP_DIR/help.out"

printf 'research-orchestrate-args-test passed\n'
