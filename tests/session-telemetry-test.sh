#!/usr/bin/env bash
set -euo pipefail

# Session telemetry: what a session cost, written down while it ran.
#
# Three claims, and they only mean anything together. A heavy gate records its
# own numbers where the journal and the session can both see them. The runtime
# supervisor samples the memory the session is holding and keeps the peak. At
# session end one event and one printed line say what the whole phase came to,
# after the reap, so the counts in it are final.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-session-telemetry-test.XXXXXX")"

cleanup() {
  local stray
  if [[ -d "$TMP_DIR" ]]; then
    while IFS= read -r stray; do
      [[ "$stray" =~ ^[0-9]+$ ]] || continue
      kill -KILL "$stray" 2>/dev/null || true
    done < <(find "$TMP_DIR" -type f -name '*.pid' -exec cat {} \; 2>/dev/null \
      || true)
    chmod -R u+w "$TMP_DIR" 2>/dev/null || true
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_REVIEW_CAPACITY_DIR="$TMP_DIR/capacity"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
export DX_TOOL_DIR="$TMP_DIR/tools"
export DX_RUN_ROOT="$TMP_DIR/runs"
# One heavy slot, so the gate under test is the whole pool.
export DEX_MAX_ACTIVE_HEAVY=1
export DEX_GATE_HEARTBEAT_SECONDS=1
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR" "$DX_RUN_ROOT"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

wait_for_file() {
  local file="$1" label="$2" attempt=0
  while [[ ! -s "$file" && $attempt -lt 400 ]]; do
    /bin/sleep 0.05
    attempt=$((attempt + 1))
  done
  [[ -s "$file" ]] || fail "$label: $file was never written"
}

REPO="$TMP_DIR/repo"
mkdir -p "$REPO/.dex"
git init -q "$REPO"
git -C "$REPO" config user.email "dex@example.com"
git -C "$REPO" config user.name "Dex Test"
printf 'project\n' > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" -c commit.gpgsign=false commit -q -m "init"
cat > "$REPO/.dex/dex.md" <<'CONTRACT'
# Fake project

## Resources

```yaml
heavy_commands:
  - sh
```

## Project Structure
Flat.
CONTRACT

# ── A gate records itself, in the journal and in the session ───────────────
# The real bin/run-gate.sh, one short command, the session owning it the way
# a lifecycle phase does.
GATE_SESSION="telemetry-gate-session"
GATE_RUN_ID="$(dx_run_prepare "$GATE_SESSION" "$REPO" "test" \
  "session-telemetry-gate" "issue-1" "dx test")"
[[ -n "$GATE_RUN_ID" ]] || assert_at $LINENO

(
  dx_session_process_token_attach "$GATE_SESSION"
  export DEX_SESSION_ID="$GATE_SESSION"
  cd "$REPO"
  exec bash "$ROOT/bin/run-gate.sh" --name suite -- \
    sh -c 'printf "gate ran\n"; exit 4'
) > "$TMP_DIR/gate.out" 2>&1 && GATE_STATUS=0 || GATE_STATUS=$?
assert_eq "4" "$GATE_STATUS" "run-gate returns the command's own exit status"

GATE_EVENTS="$(dx_run_events_file "$GATE_RUN_ID")"
assert_file "$GATE_EVENTS"
assert_contains '"type":"gate.finished"' "$GATE_EVENTS"

# Every field the summary and a later reader need, on the event that says the
# work is done: what ran, what it cost, what admitted it, and where the
# durable copy of the result is.
python3 - "$GATE_EVENTS" "$(dx_gate_receipt_dir "$GATE_SESSION")/suite.json" \
  "$(dx_host_priority_wrapper)" <<'PY'
import json
import sys

events_path, receipt_path, wrapper = sys.argv[1], sys.argv[2], sys.argv[3]
started = []
finished = []
with open(events_path, encoding="utf-8") as handle:
    for line in handle:
        line = line.strip()
        if not line:
            continue
        event = json.loads(line)
        if event.get("type") == "gate.started":
            started.append(event["data"])
        elif event.get("type") == "gate.finished":
            finished.append(event["data"])

assert len(started) == 1, f"expected one gate.started, got {len(started)}"
assert len(finished) == 1, f"expected one gate.finished, got {len(finished)}"

start = started[0]
for field in ("command", "queue_seconds", "priority_wrapper", "timeout_seconds"):
    assert field in start, f"gate.started is missing {field}"
assert "sh -c" in start["command"], start["command"]

done = finished[0]
required = {
    "command", "duration_seconds", "queue_seconds", "exit_code",
    "priority_wrapper", "receipt", "over_budget", "timeout_seconds",
}
missing = required - set(done)
assert not missing, f"gate.finished is missing {sorted(missing)}"
assert done["exit_code"] == 4, done
assert "sh -c" in done["command"], done["command"]
assert done["priority_wrapper"] == wrapper, done
assert isinstance(done["duration_seconds"], int), done
assert isinstance(done["queue_seconds"], int), done
assert done["over_budget"] is False, done
assert done["timeout_seconds"] == 0, done
assert done["receipt"] == receipt_path, done
print("gate.finished carries command, duration, queue wait, exit, wrapper, receipt and the over-budget flag")
PY

# The same numbers reach the session's own ledger, which is what the summary
# reads. One row per gate that finished.
GATE_LEDGER="$(dx_session_gate_ledger_file "$GATE_SESSION")"
assert_file "$GATE_LEDGER"
assert_contains "suite	4" "$GATE_LEDGER"
dx_session_telemetry_read "$GATE_SESSION"
assert_eq "1" "$DX_SESSION_TELEMETRY_GATES" "one gate finished in this session"
assert_eq "0" "$DX_SESSION_TELEMETRY_OVER_BUDGET" \
  "a gate with no deadline is never over budget"
[[ "$DX_SESSION_TELEMETRY_GATE_SECONDS" -ge 0 ]] || assert_at $LINENO

# A gate that reaches its deadline is recorded with what it actually did and
# flagged, rather than thrown away as "no result".
(
  export DEX_SESSION_ID="$GATE_SESSION"
  cd "$REPO"
  exec bash "$ROOT/bin/run-gate.sh" --name slow --timeout 1 -- \
    sh -c '/bin/sleep 30'
) > "$TMP_DIR/slow.out" 2>&1 && SLOW_STATUS=0 || SLOW_STATUS=$?
[[ "$SLOW_STATUS" -ne 0 ]] || fail "a gate stopped at its deadline reported success"
python3 - "$GATE_EVENTS" <<'PY'
import json
import sys

flagged = []
with open(sys.argv[1], encoding="utf-8") as handle:
    for line in handle:
        line = line.strip()
        if not line:
            continue
        event = json.loads(line)
        if event.get("type") != "gate.finished":
            continue
        if event["data"].get("gate") == "slow":
            flagged.append(event["data"])
assert len(flagged) == 1, f"expected one slow gate.finished, got {len(flagged)}"
assert flagged[0]["over_budget"] is True, flagged[0]
assert flagged[0]["timeout_seconds"] == 1, flagged[0]
print("a gate that reached its deadline is recorded and flagged over-budget")
PY
dx_session_telemetry_read "$GATE_SESSION"
assert_eq "2" "$DX_SESSION_TELEMETRY_GATES" "both gates are in the ledger"
assert_eq "1" "$DX_SESSION_TELEMETRY_OVER_BUDGET" \
  "the over-budget gate is counted once"

# A command line with a quote in it must not make the journal unreadable.
(
  export DEX_SESSION_ID="$GATE_SESSION"
  cd "$REPO"
  exec bash "$ROOT/bin/run-gate.sh" --name quoted -- \
    sh -c 'printf "%s\n" "a \"quoted\" argument"'
) > "$TMP_DIR/quoted.out" 2>&1 || fail "the quoted gate did not run"
python3 - "$GATE_EVENTS" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    for number, line in enumerate(handle, start=1):
        line = line.strip()
        if line:
            json.loads(line)
print("a quoted command line leaves every journal line parseable")
PY

# ── The peak-RSS sample writes, and keeps the larger of the two ────────────
# A session that owns a live process, sampled directly the way the runtime
# supervisor's heartbeat samples it.
RSS_SESSION="telemetry-rss-session"
(
  dx_session_process_token_attach "$RSS_SESSION"
  /bin/sleep 120 &
  printf '%s\n' "$!" > "$TMP_DIR/rss-child.pid"
  /bin/sleep 120 &
  printf '%s\n' "$!" > "$TMP_DIR/rss-holder.pid"
) > /dev/null 2>&1
wait_for_file "$TMP_DIR/rss-child.pid" "owned child"
wait_for_file "$TMP_DIR/rss-holder.pid" "second owned child"

RSS_FILE="$(dx_session_peak_rss_file "$RSS_SESSION")"
SAMPLE_RC=0
FIRST_SAMPLE="$(dx_session_peak_rss_sample "$RSS_SESSION")" || SAMPLE_RC=$?
if [[ "$SAMPLE_RC" -ne 0 ]]; then
  # A host with no ownership scan cannot name the tree to measure. Say so
  # rather than reporting a pass that measured nothing.
  printf 'skip: this host would not report the owned tree'"'"'s resident size\n'
else
  [[ "$FIRST_SAMPLE" =~ ^[0-9]+$ ]] || assert_at $LINENO
  [[ "$FIRST_SAMPLE" -gt 0 ]] || assert_at $LINENO
  assert_file "$RSS_FILE"
  assert_eq "600" "$(dx_path_mode "$RSS_FILE")" "the peak record is private"
  IFS=$'\t' read -r PEAK_ONE SAMPLES_ONE < "$RSS_FILE"
  assert_eq "$FIRST_SAMPLE" "$PEAK_ONE" "the first sample is the peak"
  assert_eq "1" "$SAMPLES_ONE" "the first sample is counted"

  # A later, smaller reading must not lower the peak: the peak is the worst
  # moment, not the last one.
  printf '%s\t%s\n' "$((FIRST_SAMPLE + 500000))" "1" > "$RSS_FILE"
  dx_session_peak_rss_sample "$RSS_SESSION" > /dev/null
  IFS=$'\t' read -r PEAK_TWO SAMPLES_TWO < "$RSS_FILE"
  assert_eq "$((FIRST_SAMPLE + 500000))" "$PEAK_TWO" \
    "a smaller later sample leaves the peak alone"
  assert_eq "2" "$SAMPLES_TWO" "every sample is counted"

  # A larger one raises it.
  printf '%s\t%s\n' "1" "2" > "$RSS_FILE"
  THIRD_SAMPLE="$(dx_session_peak_rss_sample "$RSS_SESSION")"
  IFS=$'\t' read -r PEAK_THREE SAMPLES_THREE < "$RSS_FILE"
  assert_eq "$THIRD_SAMPLE" "$PEAK_THREE" "a larger sample raises the peak"
  assert_eq "3" "$SAMPLES_THREE" "every sample is counted"

  dx_session_telemetry_read "$RSS_SESSION"
  assert_eq "$((THIRD_SAMPLE / 1024))" "$DX_SESSION_TELEMETRY_PEAK_RSS_MB" \
    "the summary reads the peak in whole megabytes"
  assert_eq "3" "$DX_SESSION_TELEMETRY_PEAK_RSS_SAMPLES" "sample count"
fi

# A session that owns nothing has no peak to report, and records none: an
# unmeasured peak must not read as a peak of zero.
EMPTY_SESSION="telemetry-empty-session"
mkdir -p "$(dx_session_process_dir "$EMPTY_SESSION")"
EMPTY_RC=0
dx_session_peak_rss_sample "$EMPTY_SESSION" > /dev/null 2>&1 || EMPTY_RC=$?
assert_eq "1" "$EMPTY_RC" "nothing to sample is not a sample of zero"
[[ ! -e "$(dx_session_peak_rss_file "$EMPTY_SESSION")" ]] || assert_at $LINENO
dx_session_telemetry_read "$EMPTY_SESSION"
assert_eq "" "$DX_SESSION_TELEMETRY_PEAK_RSS_MB" \
  "an unmeasured peak stays empty rather than becoming zero"

assert_rejected "empty session id" dx_session_peak_rss_sample ""
assert_rejected "bad over-budget flag" dx_session_gate_record \
  "$EMPTY_SESSION" gate 0 1 1 maybe
assert_rejected "gate name that is not a filename" dx_session_gate_record \
  "$EMPTY_SESSION" "../escape" 0 1 1 0

# ── The runtime supervisor samples on its own heartbeat ────────────────────
# End to end through the real supervisor, with the heartbeat and the sample
# interval shortened. This is the wiring, not the arithmetic above.
OWNER_SESSION="telemetry-owner-session"
(
  dx_session_process_token_attach "$OWNER_SESSION"
  /bin/sleep 120 &
  printf '%s\n' "$!" > "$TMP_DIR/owner-child.pid"
) > /dev/null 2>&1
wait_for_file "$TMP_DIR/owner-child.pid" "supervised session child"
OWNER_PEAK_FILE="$(dx_session_peak_rss_file "$OWNER_SESSION")"
# Started from this shell, never a subshell: the supervisor refuses to run
# unless its own parent is the launcher it was told to watch.
export DX_SESSION_RUNTIME_HEARTBEAT_MILLISECONDS=100
export DX_SESSION_RUNTIME_OWNER_START_TIMEOUT_MILLISECONDS=10000
export DX_SESSION_RUNTIME_OWNER_FINISH_TIMEOUT_MILLISECONDS=10000
export DEX_SESSION_RSS_SAMPLE_SECONDS=1
OWNER_START_RC=0
dx_session_runtime_owner_start "$OWNER_SESSION" claude "$REPO" \
  > "$TMP_DIR/owner.out" 2>&1 || OWNER_START_RC=$?
if [[ "$OWNER_START_RC" -ne 0 ]]; then
  cat "$TMP_DIR/owner.out" >&2 2>/dev/null || true
  fail "the runtime supervisor did not start (exit $OWNER_START_RC)"
fi
OWNER_HANDLE="$DX_SESSION_RUNTIME_OWNER_HANDLE"
unset DX_SESSION_RUNTIME_OWNER_HANDLE DX_SESSION_RUNTIME_OWNER_PID
OWNER_WAIT=0
while [[ ! -s "$OWNER_PEAK_FILE" && $OWNER_WAIT -lt 300 ]]; do
  /bin/sleep 0.05
  OWNER_WAIT=$((OWNER_WAIT + 1))
done
dx_session_runtime_owner_finish "$OWNER_HANDLE" completed > /dev/null 2>&1 \
  || true
unset DEX_SESSION_RSS_SAMPLE_SECONDS DX_SESSION_RUNTIME_HEARTBEAT_MILLISECONDS
unset DX_SESSION_RUNTIME_OWNER_START_TIMEOUT_MILLISECONDS
unset DX_SESSION_RUNTIME_OWNER_FINISH_TIMEOUT_MILLISECONDS
if [[ "$SAMPLE_RC" -eq 0 ]]; then
  assert_file "$OWNER_PEAK_FILE"
  IFS=$'\t' read -r OWNER_PEAK OWNER_SAMPLES < "$OWNER_PEAK_FILE"
  [[ "$OWNER_PEAK" =~ ^[0-9]+$ && "$OWNER_PEAK" -gt 0 ]] || assert_at $LINENO
  [[ "$OWNER_SAMPLES" -ge 1 ]] || assert_at $LINENO
  printf 'the runtime supervisor records a peak on its heartbeat\n'
fi
kill -KILL "$(cat "$TMP_DIR/owner-child.pid")" 2>/dev/null || true

# ── The summary, after the reap, once ──────────────────────────────────────
# A fake provider that owns a process, a gate ledger and a peak already
# recorded, then the real SessionEnd hook.
SUMMARY_SESSION="telemetry-summary-session"
SUMMARY_RUN_ID="$(dx_run_prepare "$SUMMARY_SESSION" "$REPO" "test" \
  "session-telemetry-summary" "issue-2" "dx test")"
[[ -n "$SUMMARY_RUN_ID" ]] || assert_at $LINENO
printf '0:100\n' > "$(dx_times_file "$SUMMARY_SESSION")"
dx_session_private_atomic_write "$(dx_state_file "$SUMMARY_SESSION")" "4"

FAKE_PROVIDER="$TMP_DIR/fake-provider.sh"
cat > "$FAKE_PROVIDER" <<'PROVIDER'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$DEX_DIR/lib/common.sh"
provider_session="$1"
report_dir="$2"
(
  dx_session_process_token_attach "$provider_session"
  nohup /bin/sleep 300 > /dev/null 2>&1 &
  printf '%s\n' "$!" > "$report_dir/summary-child.pid"
  disown 2>/dev/null || true
  /bin/sleep 300
) &
printf '%s\n' "$!" > "$report_dir/summary-holder.pid"
PROVIDER
chmod +x "$FAKE_PROVIDER"
bash "$FAKE_PROVIDER" "$SUMMARY_SESSION" "$TMP_DIR" > /dev/null 2>&1
wait_for_file "$TMP_DIR/summary-holder.pid" "summary fake provider"
wait_for_file "$TMP_DIR/summary-child.pid" "summary owned child"
SUMMARY_CHILD="$(cat "$TMP_DIR/summary-child.pid")"

dx_session_gate_record "$SUMMARY_SESSION" verify 0 120 30 0
dx_session_gate_record "$SUMMARY_SESSION" suite 1 60 12 1
printf '2097152\t7\n' > "$(dx_session_peak_rss_file "$SUMMARY_SESSION")"

printf '%s\n' '{"session_id":"telemetry-summary-provider"}' \
  | env DEX_SESSION_ID="$SUMMARY_SESSION" bash "$ROOT/hooks/session-end.sh" \
    > "$TMP_DIR/session-end.out" 2>&1

# The line a human reads, printed through the output helpers, with the phase
# named because the token and the temp root belong to one phase.
assert_contains "session summary: phase 4" "$TMP_DIR/session-end.out"
assert_contains "2 heavy command(s) (180s running, 42s queued)" \
  "$TMP_DIR/session-end.out"
assert_contains "peak RSS 2048 MB" "$TMP_DIR/session-end.out"
assert_contains "[info]" "$TMP_DIR/session-end.out"

SUMMARY_EVENTS="$(dx_run_events_file "$SUMMARY_RUN_ID")"
assert_file "$SUMMARY_EVENTS"
python3 - "$SUMMARY_EVENTS" <<'PY'
import json
import sys

summaries = []
reap_totals = []
with open(sys.argv[1], encoding="utf-8") as handle:
    for line in handle:
        line = line.strip()
        if not line:
            continue
        event = json.loads(line)
        if event.get("type") == "session.summary":
            summaries.append(event)
        elif event.get("type") == "session.reap.completed":
            reap_totals.append(event["data"])

assert len(summaries) == 1, f"expected one session.summary, got {len(summaries)}"
data = summaries[0]["data"]
required = {
    "reason", "phase", "heavy_commands", "heavy_seconds", "queue_seconds",
    "over_budget_commands", "peak_rss_mb", "peak_rss_samples", "reaped",
    "survived",
}
missing = required - set(data)
assert not missing, f"session.summary is missing {sorted(missing)}"
assert data["reason"] == "session-end", data
assert data["phase"] == "4", data
assert data["heavy_commands"] == 2, data
assert data["heavy_seconds"] == 180, data
assert data["queue_seconds"] == 42, data
assert data["over_budget_commands"] == 1, data
assert data["peak_rss_mb"] == 2048, data
assert data["peak_rss_samples"] == 7, data
assert data["survived"] == 0, data
# The counts are the reap's own, so the summary has to come after it.
assert reap_totals, "no reap summary was emitted"
assert data["reaped"] == reap_totals[-1]["reaped"], (data, reap_totals[-1])
assert data["reaped"] >= 2, data
print("session.summary carries the phase, the gate totals, the peak and the reap counts")
PY

# The reap ran first and really did stop what the session owned.
[[ ! -d "$(dx_session_process_dir "$SUMMARY_SESSION")" ]] || assert_at $LINENO
if kill -0 "$SUMMARY_CHILD" 2>/dev/null; then
  kill -KILL "$SUMMARY_CHILD" 2>/dev/null || true
  fail "the owned child survived the session"
fi

# A second reap pass for the same session emits nothing: the summary is once
# per provider session, not once per path that reaps.
dx_session_finish_processes "$SUMMARY_SESSION" phase-exit \
  > "$TMP_DIR/phase-exit.out" 2>&1 || true
SUMMARY_COUNT="$(grep -c '"type":"session.summary"' "$SUMMARY_EVENTS" \
  | tr -d '[:space:]')"
assert_eq "1" "$SUMMARY_COUNT" "one summary per provider session"

# A reap that does not end the session — `dx control stop`, `dx ps
# --reap-orphans` — is not a session end and says nothing.
DETACHED_SESSION="telemetry-detached-session"
DETACHED_RUN_ID="$(dx_run_prepare "$DETACHED_SESSION" "$REPO" "test" \
  "session-telemetry-detached" "issue-3" "dx test")"
(
  dx_session_process_token_attach "$DETACHED_SESSION"
  /bin/sleep 120 &
  printf '%s\n' "$!" > "$TMP_DIR/detached-child.pid"
) > /dev/null 2>&1
wait_for_file "$TMP_DIR/detached-child.pid" "detached session child"
dx_session_finish_processes "$DETACHED_SESSION" ps-reap-orphans \
  > "$TMP_DIR/orphan-reap.out" 2>&1 || true
assert_not_contains "session summary" "$TMP_DIR/orphan-reap.out"
DETACHED_EVENTS="$(dx_run_events_file "$DETACHED_RUN_ID")"
if [[ -f "$DETACHED_EVENTS" ]]; then
  assert_not_contains '"type":"session.summary"' "$DETACHED_EVENTS"
fi

# A session with no telemetry at all still summarises honestly: no gates, and
# a peak nobody measured reported as unavailable rather than as zero.
BARE_SESSION="telemetry-bare-session"
(
  dx_session_process_token_attach "$BARE_SESSION"
  /bin/sleep 120 &
  printf '%s\n' "$!" > "$TMP_DIR/bare-child.pid"
) > /dev/null 2>&1
wait_for_file "$TMP_DIR/bare-child.pid" "bare session child"
dx_session_finish_processes "$BARE_SESSION" phase-exit \
  > "$TMP_DIR/bare.out" 2>&1 || true
assert_contains "session summary: phase -" "$TMP_DIR/bare.out"
assert_contains "0 heavy command(s)" "$TMP_DIR/bare.out"
assert_contains "peak RSS unavailable" "$TMP_DIR/bare.out"

# ── A phase that could not clean up still lets the next one be seen ────────
# A reap that leaves a survivor keeps the `.process` directory, because the
# token is the only handle left on that process. The next phase re-attaches to
# that same directory, and the summary marker, gate ledger and peak from the
# phase before it must not come with it — a stale marker would silence
# telemetry for the rest of the lifecycle, on exactly the sessions it exists
# to explain.
TWO_PHASE_SESSION="telemetry-two-phase-session"
TWO_PHASE_RUN_ID="$(dx_run_prepare "$TWO_PHASE_SESSION" "$REPO" "test" \
  "session-telemetry-two-phase" "issue-4" "dx test")"
[[ -n "$TWO_PHASE_RUN_ID" ]] || assert_at $LINENO
dx_session_private_atomic_write "$(dx_state_file "$TWO_PHASE_SESSION")" "2"
(
  dx_session_process_token_attach "$TWO_PHASE_SESSION"
  nohup /bin/sleep 300 > /dev/null 2>&1 &
  printf '%s\n' "$!" > "$TMP_DIR/two-phase-one.pid"
  disown 2>/dev/null || true
  /bin/sleep 0.3
) > /dev/null 2>&1
wait_for_file "$TMP_DIR/two-phase-one.pid" "first phase child"
TWO_PHASE_ONE_PID="$(cat "$TMP_DIR/two-phase-one.pid")"
dx_session_gate_record "$TWO_PHASE_SESSION" plan 0 30 5 0
printf '1048576\t2\n' > "$(dx_session_peak_rss_file "$TWO_PHASE_SESSION")"
# KILL cannot be ignored, so the terminator is stubbed out to leave a survivor
# deterministically — the fixture tests/session-process-ownership-test.sh uses
# for the same reason.
(
  __dx_timeout_terminate_processes() { return 0; }
  dx_session_finish_processes "$TWO_PHASE_SESSION" phase-exit \
    > "$TMP_DIR/two-phase-one.out" 2>&1 || true
)
assert_contains "session summary: phase 2" "$TMP_DIR/two-phase-one.out"
assert_contains "1 heavy command(s) (30s running, 5s queued)" \
  "$TMP_DIR/two-phase-one.out"
assert_contains "peak RSS 1024 MB" "$TMP_DIR/two-phase-one.out"
assert_contains "keeping its process token" "$TMP_DIR/two-phase-one.out"
# The directory stayed, because the survivor is still out there.
assert_dir "$(dx_session_process_dir "$TWO_PHASE_SESSION")"

# The next phase re-attaches to that directory and must still be summarised,
# with its own numbers rather than the previous phase's.
dx_session_private_atomic_write "$(dx_state_file "$TWO_PHASE_SESSION")" "3"
(
  dx_session_process_token_attach "$TWO_PHASE_SESSION"
  /bin/sleep 120 &
  printf '%s\n' "$!" > "$TMP_DIR/two-phase-two.pid"
) > /dev/null 2>&1
wait_for_file "$TMP_DIR/two-phase-two.pid" "second phase child"
[[ ! -e "$(dx_session_gate_ledger_file "$TWO_PHASE_SESSION")" ]] \
  || assert_at $LINENO
[[ ! -e "$(dx_session_peak_rss_file "$TWO_PHASE_SESSION")" ]] \
  || assert_at $LINENO
dx_session_gate_record "$TWO_PHASE_SESSION" verify 0 200 9 0
dx_session_finish_processes "$TWO_PHASE_SESSION" phase-exit \
  > "$TMP_DIR/two-phase-two.out" 2>&1 || true
assert_contains "session summary: phase 3" "$TMP_DIR/two-phase-two.out"
assert_contains "1 heavy command(s) (200s running, 9s queued)" \
  "$TMP_DIR/two-phase-two.out"
assert_contains "peak RSS unavailable" "$TMP_DIR/two-phase-two.out"
kill -KILL "$TWO_PHASE_ONE_PID" 2>/dev/null || true

python3 - "$(dx_run_events_file "$TWO_PHASE_RUN_ID")" <<'PY'
import json
import sys

summaries = []
with open(sys.argv[1], encoding="utf-8") as handle:
    for line in handle:
        line = line.strip()
        if not line:
            continue
        event = json.loads(line)
        if event.get("type") == "session.summary":
            summaries.append(event)

assert len(summaries) == 2, f"expected two summaries, got {len(summaries)}"
first, second = (event["data"] for event in summaries)
assert first["phase"] == "2", first
assert second["phase"] == "3", second
assert (first["heavy_commands"], first["heavy_seconds"]) == (1, 30), first
assert (second["heavy_commands"], second["heavy_seconds"]) == (1, 200), second
assert first["peak_rss_mb"] == 1024, first
assert second["peak_rss_mb"] is None, second
assert first["survived"] >= 1, first
# The journal's own ordering, not just the counts.
assert summaries[0]["sequence"] < summaries[1]["sequence"], summaries
print("a phase that kept its token does not silence the next phase's summary")
PY

printf 'session telemetry tests passed\n'
