#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-test-infrastructure.XXXXXX")"
ACTIVE_CHILD_PID=""

cleanup() {
  [[ -n "$ACTIVE_CHILD_PID" ]] && kill "$ACTIVE_CHILD_PID" 2>/dev/null || true
  [[ -n "$ACTIVE_CHILD_PID" ]] && wait "$ACTIVE_CHILD_PID" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# A live fixture that publishes every requested readiness file succeeds.
ready_file="$TMP_DIR/ready"
(
  sleep 0.2
  printf 'ready\n' > "$ready_file"
  sleep 2
) &
ready_pid=$!
ACTIVE_CHILD_PID="$ready_pid"
DX_TEST_SERVER_START_TIMEOUT=3 wait_for_process_files "$ready_pid" "$ready_file"
kill "$ready_pid" 2>/dev/null || true
wait "$ready_pid" 2>/dev/null || true
ACTIVE_CHILD_PID=""

# A process failure is reported immediately instead of looking like a timeout.
(
  exit 7
) &
dead_pid=$!
ACTIVE_CHILD_PID="$dead_pid"
if DX_TEST_SERVER_START_TIMEOUT=3 wait_for_process_files "$dead_pid" \
  "$TMP_DIR/dead-ready" > "$TMP_DIR/dead.out" 2>&1; then
  fail "a dead fixture process was reported as ready"
fi
ACTIVE_CHILD_PID=""
assert_contains "exited before publishing readiness files" "$TMP_DIR/dead.out"

# A live process that never publishes readiness stays bounded.
(
  sleep 10
) &
slow_pid=$!
ACTIVE_CHILD_PID="$slow_pid"
if DX_TEST_SERVER_START_TIMEOUT=1 wait_for_process_files "$slow_pid" \
  "$TMP_DIR/slow-ready" > "$TMP_DIR/slow.out" 2>&1; then
  fail "a fixture with no readiness file was reported as ready"
fi
kill "$slow_pid" 2>/dev/null || true
wait "$slow_pid" 2>/dev/null || true
ACTIVE_CHILD_PID=""
assert_contains "did not publish readiness files within 1s" "$TMP_DIR/slow.out"

# The service lane is exclusive: it does not overlap parallel or serial work.
suite_dir="$TMP_DIR/suite"
report_dir="$TMP_DIR/report"
fixture_manifest="$TMP_DIR/manifest.tsv"
event_log="$report_dir/events"
mkdir -p "$suite_dir" "$report_dir"

cat > "$suite_dir/a-service-test.sh" <<'SH'
#!/usr/bin/env bash
# dex-test-lane: service
set -euo pipefail
mkdir "$DX_TEST_REPORT_DIR/service.lock"
trap 'rmdir "$DX_TEST_REPORT_DIR/service.lock"' EXIT
printf 'service-a-start\n' >> "$DX_TEST_REPORT_DIR/events"
sleep 0.1
printf 'service-a-end\n' >> "$DX_TEST_REPORT_DIR/events"
SH

cat > "$suite_dir/b-service-test.sh" <<'SH'
#!/usr/bin/env bash
# dex-test-lane: service
set -euo pipefail
mkdir "$DX_TEST_REPORT_DIR/service.lock"
trap 'rmdir "$DX_TEST_REPORT_DIR/service.lock"' EXIT
printf 'service-b-start\n' >> "$DX_TEST_REPORT_DIR/events"
sleep 0.1
printf 'service-b-end\n' >> "$DX_TEST_REPORT_DIR/events"
SH

cat > "$suite_dir/c-parallel-test.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ -e "$DX_TEST_REPORT_DIR/service.lock" ]]; then
  printf 'parallel test overlapped the service lane\n' >&2
  exit 1
fi
printf 'parallel-start\n' >> "$DX_TEST_REPORT_DIR/events"
sleep 0.1
printf 'parallel-end\n' >> "$DX_TEST_REPORT_DIR/events"
SH

cat > "$suite_dir/d-serial-test.sh" <<'SH'
#!/usr/bin/env bash
# dex-test-lane: serial
set -euo pipefail
if [[ -e "$DX_TEST_REPORT_DIR/service.lock" ]]; then
  printf 'serial test overlapped the service lane\n' >&2
  exit 1
fi
printf 'serial-start\n' >> "$DX_TEST_REPORT_DIR/events"
sleep 0.1
printf 'serial-end\n' >> "$DX_TEST_REPORT_DIR/events"
SH

printf '%s\n' \
  $'a-service-test.sh\tservice\tall\t10\thermetic' \
  $'b-service-test.sh\tservice\tall\t10\thermetic' \
  $'c-parallel-test.sh\tfast\tall\t10\thermetic' \
  $'d-serial-test.sh\tserial\tall\t10\thermetic' > "$fixture_manifest"

DX_TEST_SUITE_DIR="$suite_dir" \
DX_TEST_MANIFEST="$fixture_manifest" \
DX_TEST_LOG_DIR="$TMP_DIR/runner-logs" \
DX_TEST_REPORT_DIR="$report_dir" \
DX_TEST_JOBS=8 \
DX_TEST_TIMEOUT=10 \
  bash "$ROOT/tests/run-all.sh" > "$TMP_DIR/runner.out"

assert_contains "1 fast, 0 slow, 2 service, 1 serial" "$TMP_DIR/runner.out"
assert_eq "$(cat <<'EOF'
service-a-start
service-a-end
service-b-start
service-b-end
parallel-start
parallel-end
serial-start
serial-end
EOF
)" "$(cat "$event_log")" "test lane order"

printf 'test infrastructure tests passed\n'
