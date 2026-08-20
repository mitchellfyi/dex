#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-events-test.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
export DX_TOOL_DIR="$TMP_DIR/tools"
export DX_RUN_ROOT="$TMP_DIR/runs"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"


run_a="$(dx_run_id)"
run_b="$(dx_run_id)"
[[ "$run_a" == run_* ]] || { printf 'run id missing prefix: %s\n' "$run_a" >&2; exit 1; }
[[ "$run_a" != "$run_b" ]] || { printf 'run ids are not unique\n' >&2; exit 1; }
dx_run_validate_id "$run_a"
oversized_run_id="run_$(printf 'a%.0s' {1..200})"
if dx_run_validate_id "$oversized_run_id"; then
  printf 'run id validation accepted a filesystem component over 200 bytes\n' >&2
  exit 1
fi

session_id="test-session"
run_id="$(dx_run_prepare "$session_id" "$ROOT" "test" "events-test" "issue-46" "dx test")"
[[ -n "$run_id" ]] || { printf 'run id was empty\n' >&2; exit 1; }
[[ "$(dx_run_read_for_session "$session_id")" == "$run_id" ]] || assert_at $LINENO

run_dir="$(dx_run_dir "$run_id")"
assert_dir "$run_dir"
assert_dir "$(dx_run_artifacts_dir "$run_id")"
assert_file "$(dx_run_spec_file "$run_id")"
assert_file "$(dx_run_logs_file "$run_id")"
assert_file "$(dx_run_artifact_manifest_file "$run_id")"

dx_run_maybe_emit_started "$run_id" "Test run started" '{"command":"test"}'
dx_event_maybe_emit_phase_started "$run_id" "1" "Plan" "test"
dx_event_emit "$run_id" "plan.created" "info" "Plan created" "1" '{"items":2}'
dx_event_emit "$run_id" "phase.completed" "info" "Phase 1 completed with Authorization: Bearer ghp_eventmessage1234567890" "1" '{"duration_s":3,"iterations":1,"token":"event-token-secret","tokens":["list-secret-value"],"credentials":{"value":"nested-secret-value"},"note":"registered with dc_live_notekeynotekeynotekeynotekeynotekeynote","details":{"remote":"https://token-user:event-secret-token@github.com/example/private.git","auth_header":"Authorization: Basic abcdefghijklmnop"}}'
dx_event_emit "$run_id" "run.completed" "info" "Run completed" "1" '{"total_input_tokens":1200,"total_output_tokens":340,"total_cache_read_tokens":5600,"total_cache_write_tokens":78,"estimated_cost_cents":91,"access_token":"secret-token-value"}'
artifact_file="$(dx_run_artifact_file "$run_id" "reports/test-output.txt")"
mkdir -p "$(dirname "$artifact_file")"
printf 'test output\n' > "$artifact_file"
dx_run_register_artifact "$run_id" "test_output" "reports/test-output.txt" "Test output" '{"command":"test"}'
# The trailing two shapes carry no key name the pattern can anchor to: a bare
# Dex credential, and an API error body logged verbatim as a message.
dx_run_log_append "$run_id" "info" "test" 'Saved token=supersecret, Authorization: Basic abcdefghijklmnop, https://token-user:super-secret-token@github.com/example/private.git, and sk-12345678901234567890, worker dc_worker_logtokenlogtokenlogtokenlogtokenlogtokenlog, run dc_run_runtokenruntokenruntokenruntokenruntokenrun, body {"access_token": "jsonbodysecretvalue"}'
printf 'provider github_pat_12345678901234567890 secret=plain\n' | dx_run_log_tee "$run_id" "provider" > "$TMP_DIR/tee-output.txt"
dx_run_write_summary "$run_id" "completed" "events test completed with https://token-user:super-secret-token@github.com/example/private.git and Authorization: Bearer ghp_12345678901234567890"

assert_file "$(dx_run_events_file "$run_id")"
assert_file "$(dx_run_summary_file "$run_id")"
assert_file "$(dx_run_artifact_manifest_file "$run_id")"
assert_file "$(dx_run_artifact_file "$run_id" "run-summary.md")"

credential_repo="$TMP_DIR/credential-repo"
git init -b main "$credential_repo" >/dev/null
git -C "$credential_repo" remote add origin "https://token-user:super-secret-token@github.com/example/private-repo.git?access_token=query-secret&ref=main#password=fragment-secret"
credential_run="$(dx_run_prepare "credential-session" "$credential_repo" "test" "credential-repo" "issue-46" "dx test")"

quoted_run="$(dx_run_prepare "quoted-phase-session" "$ROOT" "test" "quoted-phase" "issue-46" "dx test")"
dx_event_maybe_emit_phase_started "$quoted_run" "1" "Plan \"quoted\"" "source\\path"

python3 - "$run_dir" "$run_id" "$ROOT" <<'PY'
import json
import sys
from pathlib import Path

run_dir = Path(sys.argv[1])
run_id = sys.argv[2]
repo_root = sys.argv[3]

spec = json.loads((run_dir / "spec.json").read_text(encoding="utf-8"))
assert spec["schema_version"] == 1
assert spec["run_id"] == run_id
assert spec["session_id"] == "test-session"
assert spec["command"] == "dx test"
assert spec["repo_path"] == repo_root

events = [
    json.loads(line)
    for line in (run_dir / "events.jsonl").read_text(encoding="utf-8").splitlines()
    if line.strip()
]
assert [event["sequence"] for event in events] == [1, 2, 3, 4, 5, 6, 7]
assert [event["type"] for event in events] == [
    "run.started",
    "phase.started",
    "plan.created",
    "phase.completed",
    "run.completed",
    "artifact.created",
    "artifact.created",
]
for event in events:
    assert event["id"].startswith("evt_")
    assert event["run_id"] == run_id
    assert isinstance(event["data"], dict)
    assert event["created_at"].endswith("Z")
    for field in ("company_slug", "project_slug", "repo", "phase", "severity", "message"):
        assert field in event

assert events[1]["phase"] == "1"
assert events[2]["data"]["items"] == 2
assert events[3]["message"] == "Phase 1 completed with Authorization: Bearer [REDACTED]"
assert events[3]["data"]["token"] == "[REDACTED]"
assert events[3]["data"]["tokens"] == "[REDACTED]"
assert events[3]["data"]["credentials"] == "[REDACTED]"
assert events[3]["data"]["details"]["auth_header"] == "[REDACTED]"
assert events[3]["data"]["details"]["remote"] == "https://[REDACTED]@github.com/example/private.git"
assert events[4]["data"]["total_input_tokens"] == 1200
assert events[4]["data"]["total_output_tokens"] == 340
assert events[4]["data"]["total_cache_read_tokens"] == 5600
assert events[4]["data"]["total_cache_write_tokens"] == 78
assert events[4]["data"]["access_token"] == "[REDACTED]"
assert "event-token-secret" not in json.dumps(events)
assert "list-secret-value" not in json.dumps(events)
assert "nested-secret-value" not in json.dumps(events)
assert "event-secret-token" not in json.dumps(events)
assert "secret-token-value" not in json.dumps(events)
assert "ghp_eventmessage1234567890" not in json.dumps(events)
assert events[3]["data"]["note"] == "registered with [REDACTED]"
assert "dc_live_" not in json.dumps(events)
assert events[5]["data"]["path"] == "reports/test-output.txt"
assert events[6]["data"]["path"] == "run-summary.md"

summary = json.loads((run_dir / "summary.json").read_text(encoding="utf-8"))
assert summary["run_id"] == run_id
assert summary["status"] == "completed"
assert summary["last_sequence"] == 7
assert "super-secret-token" not in json.dumps(summary)
assert "ghp_12345678901234567890" not in json.dumps(summary)
assert "Authorization: Bearer [REDACTED]" in summary["message"]
assert "https://[REDACTED]@github.com/example/private.git" in summary["message"]

manifest = json.loads((run_dir / "artifacts" / "manifest.json").read_text(encoding="utf-8"))
artifacts = manifest["artifacts"]
assert [artifact["path"] for artifact in artifacts] == ["reports/test-output.txt", "run-summary.md"]
assert artifacts[0]["type"] == "test_output"
assert artifacts[0]["size_bytes"] == len("test output\n")
assert artifacts[0]["metadata"]["command"] == "test"
assert artifacts[1]["type"] == "run_summary"

log_text = (run_dir / "logs.txt").read_text(encoding="utf-8")
assert "[test]" in log_text
assert "[provider]" in log_text
assert "token=[REDACTED]" in log_text
assert "secret=[REDACTED]" in log_text
assert "Authorization: Basic [REDACTED]" in log_text
assert "https://[REDACTED]@github.com/example/private.git" in log_text
assert "supersecret" not in log_text
assert "abcdefg" not in log_text
assert "github_pat_12345678901234567890" not in log_text
# Dex's own credentials, with no key name to anchor on.
assert "dc_worker_" not in log_text
assert "dc_run_" not in log_text
assert "logtokenlogtoken" not in log_text
assert "runtokenruntoken" not in log_text
# A JSON body logged as free text: the key's closing quote must not end the match.
assert '"access_token": "[REDACTED]"' in log_text
assert "jsonbodysecretvalue" not in log_text
assert "sk-12345678901234567890" not in log_text

summary_artifact_text = (run_dir / "artifacts" / "run-summary.md").read_text(encoding="utf-8")
assert "super-secret-token" not in summary_artifact_text
assert "ghp_12345678901234567890" not in summary_artifact_text
assert "Authorization: Bearer [REDACTED]" in summary_artifact_text
assert "https://[REDACTED]@github.com/example/private.git" in summary_artifact_text

tee_text = (run_dir.parent.parent / "tee-output.txt").read_text(encoding="utf-8")
assert "github_pat_12345678901234567890" in tee_text
PY

python3 - "$(dx_run_spec_file "$credential_run")" <<'PY'
import json
import sys
from pathlib import Path

spec = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert spec["repo"] == "example/private-repo"
assert spec["remote_url"] == "https://github.com/example/private-repo.git?access_token=%5BREDACTED%5D&ref=main#[REDACTED]"
assert "super-secret-token" not in json.dumps(spec)
assert "token-user" not in json.dumps(spec)
assert "query-secret" not in json.dumps(spec)
assert "fragment-secret" not in json.dumps(spec)
PY

python3 - "$(dx_run_events_file "$quoted_run")" <<'PY'
import json
import sys
from pathlib import Path

events = [
    json.loads(line)
    for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
    if line.strip()
]
assert len(events) == 1
assert events[0]["data"] == {"phase_name": 'Plan "quoted"', "source": r"source\path"}
PY

# Concurrent artifact registrations must all survive. manifest.json is a
# read-modify-write, so without a lock the later rename discards the earlier
# entry and the artifact is silently lost.
concurrent_run="$(dx_run_prepare "concurrent-session" "$ROOT" "test" "concurrent" "issue-1" "dx test")"
concurrent_artifacts="$(dx_run_artifacts_dir "$concurrent_run")"
mkdir -p "$concurrent_artifacts"
cat > "$TMP_DIR/register.sh" <<'REGISTER'
#!/usr/bin/env bash
set -uo pipefail
# shellcheck disable=SC1091
source "$DEX_DIR/lib/common.sh"
run_id="$1"
index="$2"
root="$(dx_run_artifacts_dir "$run_id")"
printf 'artifact %s\n' "$index" > "${root}/file-${index}.txt"
dx_run_register_artifact "$run_id" "test_output" "file-${index}.txt" "Artifact ${index}"
REGISTER
chmod +x "$TMP_DIR/register.sh"

register_pids=""
for i in $(seq 1 8); do
  bash "$TMP_DIR/register.sh" "$concurrent_run" "$i" >/dev/null 2>&1 &
  register_pids="$register_pids $!"
done
for pid in $register_pids; do
  wait "$pid" || true
done

python3 - "$(dx_run_artifact_manifest_file "$concurrent_run")" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
paths = sorted(entry["path"] for entry in manifest["artifacts"])
expected = sorted(f"file-{index}.txt" for index in range(1, 9))
assert paths == expected, f"lost concurrent artifact registrations: {paths}"
PY

# The same race with no manifest to start from. dx_run_prepare normally makes
# one, so every registration above took the early return out of
# dx_run_artifact_manifest_prepare and never exercised it under contention.
# Creating it is part of the same read-modify-write, and it used to happen
# before the lock was taken — so one process could answer "is there one
# already?" and then write over a manifest another had just filled.
missing_manifest_run="$(dx_run_prepare "missing-manifest" "$ROOT" "test" "concurrent" "issue-1" "dx test")"
mkdir -p "$(dx_run_artifacts_dir "$missing_manifest_run")"
rm -f "$(dx_run_artifact_manifest_file "$missing_manifest_run")"

register_pids=""
for i in $(seq 1 8); do
  bash "$TMP_DIR/register.sh" "$missing_manifest_run" "$i" >/dev/null 2>&1 &
  register_pids="$register_pids $!"
done
for pid in $register_pids; do
  wait "$pid" || true
done

python3 - "$(dx_run_artifact_manifest_file "$missing_manifest_run")" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
paths = sorted(entry["path"] for entry in manifest["artifacts"])
expected = sorted(f"file-{index}.txt" for index in range(1, 9))
assert paths == expected, f"lost registrations creating the manifest: {paths}"
PY

# The phase.completed / phase.failed payload is a format consumers read, and
# nothing pinned its shape. It was written out twice — once in dx.sh for the
# inline lifecycle, once in hooks/phase-loop.sh for the Stop hook — as
# byte-identical copies, so the two could have answered differently at any
# point without anything noticing.
phase_payload=$(
  DX_PHASE_NAME="Review" \
  DX_PHASE_START_EPOCH="1700000000" \
  DX_PHASE_END_EPOCH="1700000125" \
  DX_PHASE_DURATION="125" \
  DX_PHASE_ITERATIONS="7" \
  DX_PHASE_STATUS="advance" \
  DX_PHASE_EXIT_CODE="0" \
  dx_phase_result_data
)
assert_eq \
  '{"duration_s":125,"end_epoch":1700000125,"exit_code":0,"iterations":7,"phase_name":"Review","start_epoch":1700000000,"status":"advance"}' \
  "$phase_payload" "phase result payload"

# A value that is not a whole number becomes 0 rather than breaking the JSON,
# so an unresolved epoch cannot make the event unparseable.
malformed_payload=$(
  DX_PHASE_NAME="Implement" \
  DX_PHASE_START_EPOCH="" \
  DX_PHASE_END_EPOCH="x" \
  DX_PHASE_DURATION="-3" \
  DX_PHASE_ITERATIONS="abc" \
  DX_PHASE_STATUS="max-iter" \
  DX_PHASE_EXIT_CODE="88" \
  dx_phase_result_data
)
assert_eq \
  '{"duration_s":-3,"end_epoch":0,"exit_code":88,"iterations":0,"phase_name":"Implement","start_epoch":0,"status":"max-iter"}' \
  "$malformed_payload" "phase result payload with unusable numbers"

printf 'events tests passed\n'
