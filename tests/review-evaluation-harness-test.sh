#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-review-evaluation-test.XXXXXX")"
DETACHED_TEST_PID_FILE=""

cleanup() {
  if [[ -n "$DETACHED_TEST_PID_FILE" && -f "$DETACHED_TEST_PID_FILE" ]]; then
    detached_test_pid=$(tr -d '\n' < "$DETACHED_TEST_PID_FILE" 2>/dev/null || true)
    case "$detached_test_pid" in
      ""|*[!0-9]*) ;;
      *) kill -KILL "$detached_test_pid" 2>/dev/null || true ;;
    esac
  fi
  if [[ -d "$TMP_DIR" && ! -L "$TMP_DIR" ]]; then
    REVIEW_EVAL_TEST_CLEANUP_ROOT="$TMP_DIR" python3 - <<'PY'
import os
import shutil
import stat
from pathlib import Path

root = Path(os.environ["REVIEW_EVAL_TEST_CLEANUP_ROOT"])
metadata = root.lstat()
if (
    not root.name.startswith("dex-review-evaluation-test.")
    or not stat.S_ISDIR(metadata.st_mode)
    or not shutil.rmtree.avoids_symlink_attacks
):
    raise SystemExit(1)
for _, _, _, directory_fd in os.fwalk(root, topdown=False, follow_symlinks=False):
    if not stat.S_ISDIR(os.fstat(directory_fd).st_mode):
        raise SystemExit(1)
    os.fchmod(directory_fd, 0o700)
shutil.rmtree(root)
PY
  fi
}
trap cleanup EXIT


assert_eq() {
  local expected="$1" actual="$2" label="$3"
  [[ "$expected" == "$actual" ]] || fail "$label: expected '$expected', got '$actual'"
}

# shellcheck source=research/review-loop/lib.sh
source "$ROOT/research/review-loop/lib.sh"

external_python_state="$TMP_DIR/external-python-state.json"
external_python_path=$(python3 - "$external_python_state" <<'PY'
import hashlib
import json
import os
import stat
import sys
from pathlib import Path

source = Path(os.path.realpath(sys.executable))
metadata = source.stat()
if not stat.S_ISREG(metadata.st_mode):
    raise SystemExit("test Python is not a regular file")
payload = {
    "device": metadata.st_dev,
    "inode": metadata.st_ino,
    "links": metadata.st_nlink,
    "mode": stat.S_IMODE(metadata.st_mode),
    "sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
}
Path(sys.argv[1]).write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")
print(source)
PY
)

review_eval_validate_catalog
scenarios=()
while IFS= read -r scenario; do
  scenarios+=("$scenario")
done < <(review_eval_list_scenarios)
assert_eq "9" "${#scenarios[@]}" "scenario count"

matrix_file="$TMP_DIR/matrix.tsv"
review_eval_matrix_rows 3 claude codex > "$matrix_file"
assert_eq "54" "$(wc -l < "$matrix_file" | tr -d ' ')" "matrix row count"
assert_eq "54" "$(LC_ALL=C sort -u "$matrix_file" | wc -l | tr -d ' ')" "unique matrix rows"

if review_eval_matrix_rows 0 claude >/dev/null 2>&1; then
  fail "zero replicas should be rejected"
fi
if review_eval_matrix_rows 3 unknown >/dev/null 2>&1; then
  fail "unknown providers should be rejected"
fi

for scenario in "${scenarios[@]}"; do
  trial_dir="$TMP_DIR/trials/$scenario"
  workspace=$(review_eval_prepare_workspace "$scenario" "$trial_dir")

  [[ -d "$workspace/.git" ]] || fail "$scenario workspace is not a clone"
  assert_eq "review-eval/candidate" \
    "$(git -C "$workspace" branch --show-current)" "$scenario opaque branch"
  [[ -n "$(git -C "$workspace" rev-parse --verify refs/remotes/origin/main)" ]] || \
    fail "$scenario is missing origin/main"
  [[ -n "$(git -C "$workspace" diff --name-only origin/main...HEAD)" ]] || \
    fail "$scenario has no candidate change"
  if find "$workspace" -type f \( -name 'oracle.py' -o -name '*oracle*' \) -print -quit | grep -q .; then
    fail "$scenario copied hidden oracle material into the checkout"
  fi

  review_eval_run_visible_check "$scenario" "$workspace"
  oracle_status=$(review_eval_oracle_status "$scenario" "$workspace")
  control=$(review_eval_scenario_field "$scenario" control)
  if [[ "$control" == "true" ]]; then
    assert_eq "pass" "$oracle_status" "$scenario control oracle"
  else
    assert_eq "fail" "$oracle_status" "$scenario planted defect oracle"
    review_eval_apply_canonical_fix "$scenario" "$workspace"
    assert_eq "pass" "$(review_eval_oracle_status "$scenario" "$workspace")" \
      "$scenario canonical fix oracle"
  fi

  expected_floor=$(review_eval_scenario_field "$scenario" expected_floor)
  actual_floor=$(DEX_DIR="$ROOT" bash -c '
    source "$DEX_DIR/lib/common.sh"
    dx_review_scope_minimum_tier "$1" | cut -f1
  ' _ "$workspace")
  assert_eq "$expected_floor" "$actual_floor" "$scenario deterministic floor"
done

observer_trial="$TMP_DIR/observer-trial"
observer_workspace=$(review_eval_prepare_workspace small-zero-missing "$observer_trial")
observer_result="$TMP_DIR/observer-result"
mkdir -p "$observer_result"
# shellcheck source=research/review-loop/agent-observer.sh
source "$ROOT/research/review-loop/agent-observer.sh"
review_eval_agent_capture_wave "$observer_workspace" "$observer_result" \
  pass_id=pass-a iteration_int=1 result_kind=clean clean_after_int=1

python3 - "$observer_result/waves.jsonl" <<'PY'
import json
import sys

rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert len(rows) == 1, rows
assert rows[0]["iteration"] == 1, rows
assert rows[0]["pass_id"] == "pass-a", rows
assert "oracle_status" not in rows[0], rows
PY

review_eval_score_snapshots small-zero-missing "$observer_result"
python3 - "$observer_result" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
rows = [json.loads(line) for line in (root / "oracle-waves.jsonl").read_text().splitlines()]
assert len(rows) == 1, rows
assert rows[0]["oracle_status"] == "fail", rows
snapshot = root / rows[0]["snapshot"]
assert snapshot.is_dir(), snapshot
assert not any(snapshot.rglob("*oracle*")), snapshot
PY

review_eval_record_assessment "$observer_result" $'normal\tcross-module'
python3 - "$observer_result/assessment.jsonl" <<'PY'
import json
import sys

rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert rows == [{"reason_codes": "cross-module", "tier": "normal"}], rows
PY

runtime_source="$TMP_DIR/runtime-source"
git clone -q "$ROOT" "$runtime_source"
mkdir -p "$runtime_source/research/review-loop"
cp "$ROOT/research/review-loop/launch.zsh" "$runtime_source/research/review-loop/launch.zsh"
cp "$ROOT/research/review-loop/agent-observer.sh" "$runtime_source/research/review-loop/agent-observer.sh"
runtime_contract_files=(
  dx.sh
  lib/common.sh
  lib/review.sh
  lib/review-controller.sh
  lib/review-policy.sh
)
for runtime_contract_file in "${runtime_contract_files[@]}"; do
  cp "$ROOT/$runtime_contract_file" "$runtime_source/$runtime_contract_file"
done
git -C "$runtime_source" add \
  research/review-loop/launch.zsh research/review-loop/agent-observer.sh \
  "${runtime_contract_files[@]}"
git -C "$runtime_source" \
  -c user.name='Dex Review Evaluation' -c user.email='review-eval@dex.local' \
  commit --allow-empty -qm 'test: pin evaluation launcher'
runtime_source_sha=$(git -C "$runtime_source" rev-parse HEAD)
runtime_dir="$TMP_DIR/runtime"
runtime_sha=$(review_eval_prepare_runtime "$runtime_source" HEAD "$runtime_dir")
assert_eq "$runtime_source_sha" "$runtime_sha" "runtime commit"
[[ ! -e "$runtime_dir/.git" ]] || fail "runtime must not expose git history"
[[ -x "$runtime_dir/research/review-loop/launch.zsh" ]] || fail "sanitized launcher is missing"
[[ -f "$runtime_dir/research/review-loop/agent-observer.sh" ]] || fail "sanitized observer is missing"
[[ ! -e "$runtime_dir/research/review-loop/scenarios" ]] || fail "runtime contains scenario truth"
actual_runtime_roots=$(find "$runtime_dir" -mindepth 1 -maxdepth 1 -exec basename {} \; | LC_ALL=C sort | tr '\n' ' ')
# scripts/ is in the runtime because lib/ imports helpers from it. Widening
# this list is deliberate: it is what the pinned agent runtime may contain.
assert_eq "bin dx.sh hooks lib prompts research scripts settings.json skills " \
  "$actual_runtime_roots" "runtime allowlist"
if find "$runtime_dir" \( -path '*/hidden/*' -o -path '*/canonical_fix/*' -o -iname '*oracle*' \) \
    -print -quit | grep -q .; then
  fail "runtime contains hidden evaluation material"
fi
for scenario in "${scenarios[@]}"; do
  if rg -l -F "$scenario" "$runtime_dir" >/dev/null 2>&1; then
    fail "runtime content exposes scenario id: $scenario"
  fi
done

cleanup_probe_root="$TMP_DIR/dex-review-trial.cleanup-hardlink"
cleanup_probe_external="$TMP_DIR/cleanup-external-python"
mkdir -p "$cleanup_probe_root/runtime/subdir"
printf '%s\n' 'external executable sentinel' > "$cleanup_probe_external"
chmod 775 "$cleanup_probe_external"
ln "$cleanup_probe_external" \
  "$cleanup_probe_root/runtime/subdir/external-hardlink"
printf '%s\n' 'ordinary runtime file' > "$cleanup_probe_root/runtime/ordinary"
if review_eval_runtime_make_read_only "$cleanup_probe_root/runtime" 2>/dev/null; then
  fail "runtime hardening accepted a hard-linked file"
fi
chmod 555 "$cleanup_probe_root/runtime" "$cleanup_probe_root/runtime/subdir"
__review_eval_remove_execution_root "$cleanup_probe_root" "$TMP_DIR"
python3 - "$cleanup_probe_external" <<'PY'
import stat
import sys
from pathlib import Path

source = Path(sys.argv[1])
metadata = source.stat()
assert stat.S_IMODE(metadata.st_mode) == 0o775, oct(metadata.st_mode)
assert metadata.st_nlink == 1, metadata.st_nlink
assert source.read_text(encoding="utf-8") == "external executable sentinel\n"
PY

runtime_symlink_root="$TMP_DIR/runtime-symlink-probe"
runtime_symlink_external="$TMP_DIR/runtime-symlink-external"
mkdir -p "$runtime_symlink_root"
printf '%s\n' 'external symlink sentinel' > "$runtime_symlink_external"
chmod 775 "$runtime_symlink_external"
ln -s "$runtime_symlink_external" "$runtime_symlink_root/external-link"
if review_eval_runtime_make_read_only "$runtime_symlink_root" 2>/dev/null; then
  fail "runtime hardening accepted a symlink"
fi
if review_eval_runtime_tree_hash "$runtime_symlink_root" >/dev/null 2>&1; then
  fail "runtime hashing accepted a symlink"
fi
python3 - "$runtime_symlink_external" <<'PY'
import stat
import sys
from pathlib import Path

source = Path(sys.argv[1])
metadata = source.stat()
assert stat.S_IMODE(metadata.st_mode) == 0o775, oct(metadata.st_mode)
assert metadata.st_nlink == 1, metadata.st_nlink
assert source.read_text(encoding="utf-8") == "external symlink sentinel\n"
PY

smoke_trial="$TMP_DIR/smoke-trial"
smoke_workspace=$(review_eval_prepare_workspace small-control "$smoke_trial")
smoke_result="$TMP_DIR/smoke-result"
smoke_home="$TMP_DIR/smoke-home"
smoke_observer_token="0123456789abcdef0123456789abcdef"

fake_claude_home="$TMP_DIR/fake-claude-home"
darwin_execution_root="$TMP_DIR/dex-review-trial.auth-darwin"
darwin_auth_state="$TMP_DIR/darwin-auth-state.json"
mkdir -p "$fake_claude_home/Library/Keychains"
printf '%s\n' 'fake-keychain-data' > "$fake_claude_home/Library/Keychains/login.keychain-db"
chmod 750 "$fake_claude_home/Library/Keychains"
chmod 640 "$fake_claude_home/Library/Keychains/login.keychain-db"
python3 - "$fake_claude_home/Library/Keychains" "$darwin_auth_state" <<'PY'
import hashlib
import json
import stat
import sys
from pathlib import Path

source = Path(sys.argv[1])
keychain = source / "login.keychain-db"
Path(sys.argv[2]).write_text(json.dumps({
    "directory_mode": stat.S_IMODE(source.stat().st_mode),
    "file_mode": stat.S_IMODE(keychain.stat().st_mode),
    "sha256": hashlib.sha256(keychain.read_bytes()).hexdigest(),
}), encoding="utf-8")
PY
review_eval_prepare_trial_home "$runtime_dir" "$darwin_execution_root/home" \
  claude "$TMP_DIR/no-codex-home" "$fake_claude_home" Darwin
python3 - "$fake_claude_home/Library/Keychains" \
  "$darwin_execution_root/home/Library/Keychains" <<'PY'
import os
import stat
import sys
from pathlib import Path

source = Path(sys.argv[1])
bridge = Path(sys.argv[2])
metadata = bridge.lstat()
assert stat.S_ISLNK(metadata.st_mode), oct(metadata.st_mode)
assert Path(os.readlink(bridge)) == source, os.readlink(bridge)
PY
__review_eval_remove_execution_root "$darwin_execution_root" "$TMP_DIR"
darwin_controller_token="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
darwin_controller_root="$TMP_DIR/dex-review-trial.${darwin_controller_token}.auth"
review_eval_prepare_trial_home "$runtime_dir" "$darwin_controller_root/home" \
  claude "$TMP_DIR/no-codex-home" "$fake_claude_home" Darwin
__review_eval_cleanup_controller_token "$TMP_DIR" "$darwin_controller_token"
[[ ! -e "$darwin_controller_root" && ! -L "$darwin_controller_root" ]] || \
  fail "controller cleanup left the Claude keychain bridge behind"
python3 - "$fake_claude_home/Library/Keychains" "$darwin_auth_state" <<'PY'
import hashlib
import json
import stat
import sys
from pathlib import Path

source = Path(sys.argv[1])
keychain = source / "login.keychain-db"
before = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
assert stat.S_IMODE(source.stat().st_mode) == before["directory_mode"], before
assert stat.S_IMODE(keychain.stat().st_mode) == before["file_mode"], before
assert hashlib.sha256(keychain.read_bytes()).hexdigest() == before["sha256"], before
PY

linux_claude_home="$TMP_DIR/linux-claude-home"
linux_execution_root="$TMP_DIR/dex-review-trial.auth-linux"
linux_auth_state="$TMP_DIR/linux-auth-state.json"
mkdir -p "$linux_claude_home/.claude"
printf '%s\n' '{"fake":"claude-credential"}' > "$linux_claude_home/.claude/.credentials.json"
chmod 640 "$linux_claude_home/.claude/.credentials.json"
python3 - "$linux_claude_home/.claude/.credentials.json" "$linux_auth_state" <<'PY'
import hashlib
import json
import stat
import sys
from pathlib import Path

source = Path(sys.argv[1])
metadata = source.stat()
Path(sys.argv[2]).write_text(json.dumps({
    "mode": stat.S_IMODE(metadata.st_mode),
    "links": metadata.st_nlink,
    "sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
}), encoding="utf-8")
PY
review_eval_prepare_trial_home "$runtime_dir" "$linux_execution_root/home" \
  claude "$TMP_DIR/no-codex-home" "$linux_claude_home" Linux
python3 - "$linux_claude_home/.claude/.credentials.json" \
  "$linux_execution_root/home/.claude/.credentials.json" <<'PY'
import os
import stat
import sys

source = os.stat(sys.argv[1])
bridge = os.stat(sys.argv[2])
assert stat.S_ISREG(bridge.st_mode), oct(bridge.st_mode)
assert stat.S_IMODE(bridge.st_mode) == 0o600, oct(bridge.st_mode)
assert (source.st_dev, source.st_ino) != (bridge.st_dev, bridge.st_ino)
PY
printf '%s\n' '{"trial":"mutation"}' > \
  "$linux_execution_root/home/.claude/.credentials.json"
__review_eval_remove_execution_root "$linux_execution_root" "$TMP_DIR"
python3 - "$linux_claude_home/.claude/.credentials.json" "$linux_auth_state" <<'PY'
import hashlib
import json
import stat
import sys
from pathlib import Path

source = Path(sys.argv[1])
before = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
after = source.stat()
assert stat.S_IMODE(after.st_mode) == before["mode"], before
assert after.st_nlink == before["links"], before
assert hashlib.sha256(source.read_bytes()).hexdigest() == before["sha256"], before
PY

symlink_claude_home="$TMP_DIR/symlink-claude-home"
symlink_trial_home="$TMP_DIR/symlink-trial-home"
mkdir -p "$symlink_claude_home/.claude"
ln -s "$linux_claude_home/.claude/.credentials.json" \
  "$symlink_claude_home/.claude/.credentials.json"
review_eval_prepare_trial_home "$runtime_dir" "$symlink_trial_home" \
  claude "$TMP_DIR/no-codex-home" "$symlink_claude_home" Linux
[[ ! -e "$symlink_trial_home/.claude/.credentials.json" ]] || \
  fail "Claude auth bridge followed a credentials symlink"

review_eval_prepare_trial_home "$runtime_dir" "$smoke_home" claude \
  "$TMP_DIR/no-codex-home" "$TMP_DIR/no-claude-home" Linux
mkdir -p "$smoke_result"
if find "$smoke_home/.codex" -mindepth 1 -maxdepth 1 ! -name auth.json \
    -print -quit | grep -q .; then
  fail "isolated Codex home contains more than the auth bridge"
fi

fake_codex_home="$TMP_DIR/fake-codex-home"
auth_bridge_home="$TMP_DIR/auth-bridge-home"
mkdir -p "$fake_codex_home"
printf '%s\n' '{"fake":"credential"}' > "$fake_codex_home/auth.json"
chmod 600 "$fake_codex_home/auth.json"
review_eval_prepare_trial_home "$runtime_dir" "$auth_bridge_home" codex "$fake_codex_home"
python3 - "$fake_codex_home/auth.json" "$auth_bridge_home/.codex/auth.json" <<'PY'
import os
import stat
import sys

source = os.stat(sys.argv[1])
bridge = os.stat(sys.argv[2])
assert stat.S_ISREG(bridge.st_mode), oct(bridge.st_mode)
assert stat.S_IMODE(bridge.st_mode) == 0o600, oct(bridge.st_mode)
assert (source.st_dev, source.st_ino) != (bridge.st_dev, bridge.st_ino)
PY
printf '%s\n' '{"trial":"mutation"}' > "$auth_bridge_home/.codex/auth.json"
assert_eq '{"fake":"credential"}' "$(tr -d '\n' < "$fake_codex_home/auth.json")" \
  "isolated Codex auth copy cannot mutate the source"
printf '%s\n' '{"fake":"credential"}' > "$auth_bridge_home/.codex/auth.json"
python3 - "$fake_codex_home/auth.json" "$TMP_DIR/fake-auth-state.json" <<'PY'
import hashlib
import json
import stat
import sys
from pathlib import Path

source = Path(sys.argv[1])
metadata = source.stat()
Path(sys.argv[2]).write_text(json.dumps({
    "mode": stat.S_IMODE(metadata.st_mode),
    "links": metadata.st_nlink,
    "sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
}), encoding="utf-8")
PY

(
  cd "$smoke_workspace"
  env -i \
    HOME="$smoke_home" \
    CODEX_HOME="$smoke_home/.codex" \
    PATH="$PATH" \
    TMPDIR="${TMPDIR:-/tmp}" \
    USER="${USER:-}" \
    SHELL="${SHELL:-/bin/zsh}" \
    OPENAI_API_KEY="review-eval-secret-sentinel" \
    REVIEW_EVAL_TEST_STUB=1 \
    zsh "$runtime_dir/research/review-loop/launch.zsh" \
      "$runtime_dir" "$smoke_workspace" "$smoke_result" claude "" "" "" \
      "$smoke_observer_token"
) > "$smoke_result/stdout.log" 2> "$smoke_result/stderr.log"
smoke_tmp_parent=$(cd "${TMPDIR:-/tmp}" && pwd -P)
review_eval_collect_observer_artifacts "$smoke_result" "$smoke_result" \
  "$smoke_tmp_parent" "$smoke_observer_token" true

python3 - "$smoke_result/waves.jsonl" "$smoke_result/provider-observations.jsonl" <<'PY'
import json
import sys

waves = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert len(waves) == 3, waves
assert all("oracle_status" not in row for row in waves), waves
observations = [json.loads(line) for line in open(sys.argv[2], encoding="utf-8")]
assert len(observations) == 4, observations
assert observations[0] == {
    "assessment_active": True,
    "evidence_version": 0,
    "generic_branch": True,
    "generic_layout": False,
    "pass_binding_valid": False,
    "policy_binding_valid": False,
    "prior_capture_visible": False,
}, observations
assert all(row == {
    "assessment_active": False,
    "evidence_version": 3,
    "generic_branch": True,
    "generic_layout": False,
    "pass_binding_valid": True,
    "policy_binding_valid": True,
    "prior_capture_visible": False,
} for row in observations[1:]), observations
PY
if rg -l 'review-eval-secret-sentinel' "$smoke_result" >/dev/null 2>&1; then
  fail "provider credentials were persisted in smoke artifacts"
fi

python3 - "$smoke_result/assessment.jsonl" <<'PY'
import json
import sys

rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert rows == [{"tier": "small", "reason_codes": "localized-change,focused-verification"}], rows
PY

review_eval_score_snapshots small-control "$smoke_result"
python3 - "$smoke_result" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
waves = [json.loads(line) for line in (root / "oracle-waves.jsonl").read_text().splitlines()]
assert len(waves) == 3, waves
assert all(row["oracle_status"] == "pass" for row in waves), waves
events = "\n".join(path.read_text() for path in (root / "dex-runs").glob("run_*/events.jsonl"))
assert "review.completed" in events, events
assert "oracle_status" not in events, events
assert "hidden_oracle" not in events, events
PY

managed_run="$TMP_DIR/managed-run"
managed_trial="$managed_run/trials/small-control/replica-1/claude"
managed_defect_trial="$managed_run/trials/small-zero-missing/replica-1/claude"
mkdir -p "$managed_run/trials"
printf '%s\n' \
  $'small-control\t1\tclaude' \
  $'small-zero-missing\t1\tclaude' > "$managed_run/matrix.tsv"
controller_inputs=$(review_eval_archive_controller_inputs "$managed_run")
[[ -f "$controller_inputs/controller/lib.sh" ]] || fail "controller archive is missing lib.sh"
[[ -f "$controller_inputs/controller/run.sh" ]] || fail "controller archive is missing run.sh"
[[ -f "$controller_inputs/source.json" ]] || fail "controller archive is missing source metadata"
[[ -f "$controller_inputs/scenarios/small-control/scenario.json" ]] || \
  fail "controller archive is missing the fixture catalog"

archive_race_root="$TMP_DIR/archive-race"
archive_race_controller="$archive_race_root/controller"
archive_race_scenarios="$archive_race_root/scenarios"
archive_race_hooks="$archive_race_root/python-hooks"
archive_race_sentinel="$archive_race_root/external-sentinel"
mkdir -p "$archive_race_controller" "$archive_race_hooks" "$archive_race_root/run"
cp "$ROOT/research/review-loop/README.md" \
  "$ROOT/research/review-loop/agent-observer.sh" \
  "$ROOT/research/review-loop/lib.sh" \
  "$ROOT/research/review-loop/run.sh" \
  "$archive_race_controller/"
cp -R "$ROOT/research/review-loop/scenarios" "$archive_race_scenarios"
printf '%s\n' 'archive race sentinel' > "$archive_race_sentinel"
chmod 775 "$archive_race_sentinel"
python3 - "$archive_race_hooks/sitecustomize.py" <<'PY'
import sys
from pathlib import Path

Path(sys.argv[1]).write_text(
    """import os
from pathlib import Path

_real_open = os.open
_target = os.path.realpath(os.environ["REVIEW_EVAL_RACE_SOURCE"])
_backup = Path(os.environ["REVIEW_EVAL_RACE_BACKUP"])
_sentinel = Path(os.environ["REVIEW_EVAL_RACE_SENTINEL"])
_triggered = False

def _raced_open(path, flags, *args, **kwargs):
    global _triggered
    if not _triggered and os.path.realpath(os.fspath(path)) == _target:
        _triggered = True
        Path(path).rename(_backup)
        Path(path).symlink_to(_sentinel)
    return _real_open(path, flags, *args, **kwargs)

os.open = _raced_open
""",
    encoding="utf-8",
)
PY
if (
  export PYTHONPATH="$archive_race_hooks"
  export REVIEW_EVAL_RACE_SOURCE="$archive_race_controller/README.md"
  export REVIEW_EVAL_RACE_BACKUP="$archive_race_controller/README.original"
  export REVIEW_EVAL_RACE_SENTINEL="$archive_race_sentinel"
  # Read by review_eval_archive_controller_inputs below as shell variables,
  # which shellcheck cannot see across the function boundary.
  # shellcheck disable=SC2034
  REVIEW_EVAL_DIR="$archive_race_controller"
  # shellcheck disable=SC2034
  REVIEW_EVAL_SCENARIOS_DIR="$archive_race_scenarios"
  # shellcheck disable=SC2034
  REVIEW_EVAL_REPO_ROOT="$ROOT"
  review_eval_archive_controller_inputs "$archive_race_root/run" >/dev/null 2>&1
); then
  fail "controller archive accepted a source swapped to a symlink"
fi
python3 - "$archive_race_sentinel" <<'PY'
import stat
import sys
from pathlib import Path

source = Path(sys.argv[1])
metadata = source.stat()
assert stat.S_IMODE(metadata.st_mode) == 0o775, oct(metadata.st_mode)
assert metadata.st_nlink == 1, metadata.st_nlink
assert source.read_text(encoding="utf-8") == "archive race sentinel\n"
PY
REVIEW_EVAL_METADATA_SOURCE_REPO="$runtime_source" \
REVIEW_EVAL_METADATA_CONTROLLER="$controller_inputs/controller" \
REVIEW_EVAL_METADATA_SCENARIOS="$controller_inputs/scenarios" \
REVIEW_EVAL_METADATA_CONTROLLER_INPUTS="$controller_inputs" \
  review_eval_write_run_metadata "$managed_run" baseline "$runtime_source_sha" 1 1 \
    120 "test-claude" "high" "" "default" "claude"
REVIEW_EVAL_TEST_STUB=1 \
  review_eval_run_trial "$runtime_source" "$runtime_source_sha" baseline \
    small-control 1 claude "test-claude" "high" 120 "$managed_trial"
REVIEW_EVAL_TEST_STUB=1 \
  review_eval_run_trial "$runtime_source" "$runtime_source_sha" baseline \
    small-zero-missing 1 claude "test-claude" "high" 120 "$managed_defect_trial"
review_eval_summarize_run "$managed_run"

python3 - "$managed_run" "$runtime_source_sha" <<'PY'
import json
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1])
expected_sha = sys.argv[2]
manifest = json.loads(
    (root / "trials/small-control/replica-1/claude/manifest.json").read_text()
)
assert manifest["schema_version"] == 1, manifest
assert manifest["dex_sha"] == expected_sha, manifest
assert manifest["expected_tier"] == "small", manifest
assert manifest["expected_floor"] == "small", manifest
assert manifest["control"] is True, manifest
assert manifest["status"] == "completed", manifest
assert manifest["product_exit_code"] == 0, manifest
assert manifest["visible_before"] == "pass", manifest
assert manifest["visible_after"] == "pass", manifest
assert manifest["oracle_before"] == "pass", manifest
assert manifest["oracle_after"] == "pass", manifest
assert manifest["wave_count"] == 3, manifest
assert manifest["first_oracle_pass_iteration"] == 1, manifest
assert manifest["control_edited"] is False, manifest
trial_root = root / "trials/small-control/replica-1/claude"
assert stat.S_IMODE(trial_root.stat().st_mode) == 0o700, oct(trial_root.stat().st_mode)
assert not (trial_root / "stdout.log").exists(), trial_root
assert not (trial_root / "stderr.log").exists(), trial_root
assert (trial_root / "provider-output.json").is_file(), trial_root
observations = [
    json.loads(line)
    for line in (root / "trials/small-control/replica-1/claude/provider-observations.jsonl")
    .read_text()
    .splitlines()
]
assert observations, observations
assert all(row["generic_layout"] is True for row in observations), observations

metadata = json.loads((root / "run.json").read_text())
assert metadata["schema_version"] == 1, metadata
assert metadata["dex_sha"] == expected_sha, metadata
assert metadata["runners"] == ["claude"], metadata
assert metadata["models"]["claude"] == "test-claude", metadata
assert set(metadata["artifact_hashes"]) == {
    "catalog_sha256",
    "controller_inputs_sha256",
    "controller_lib_sha256",
    "controller_observer_sha256",
    "controller_readme_sha256",
    "controller_run_sha256",
    "launcher_sha256",
    "matrix_sha256",
    "observer_sha256",
}, metadata
assert all(
    len(value) == 64 and set(value) <= set("0123456789abcdef")
    for value in metadata["artifact_hashes"].values()
), metadata
assert metadata["controller_inputs"]["archive"] == "controller-inputs", metadata
assert metadata["controller_inputs"]["source_commit"], metadata
assert isinstance(metadata["controller_inputs"]["source_dirty"], bool), metadata

defect_manifest = json.loads(
    (root / "trials/small-zero-missing/replica-1/claude/manifest.json").read_text()
)
assert defect_manifest["status"] == "completed", defect_manifest
assert defect_manifest["oracle_after"] == "fail", defect_manifest
assert defect_manifest["wave_count"] == 3, defect_manifest

summary = json.loads((root / "summary.json").read_text())
assert summary["schema_version"] == 1, summary
assert summary["scheduled"] == 2, summary
assert summary["collected"] == 2, summary
assert summary["statuses"] == {
    "censored": 0,
    "completed": 2,
    "harness_error": 0,
    "paused": 0,
    "product_error": 0,
}, summary
assert summary["final_oracle_pass"] == 1, summary
assert summary["controls_edited"] == 0, summary
assert summary["waves"] == {"fail": 3, "invalid": 0, "pass": 3}, summary
assert summary["false_clean_waves"] == 3, summary
assert summary["eligible_trials"] == 2, summary
assert summary["tier_accuracy"] == {
    "proposed_matches": 2,
    "resolved_matches": 2,
}, summary
assert summary["defects"] == {"eligible": 1, "fixed": 0}, summary
assert (root / "trials.tsv").is_file(), summary
PY

premature_trial="$TMP_DIR/premature-completion-trial"
cp -R "$managed_trial" "$premature_trial"
python3 - "$premature_trial" <<'PY'
import json
import os
import sys
from pathlib import Path

root = Path(sys.argv[1])
for event_file in root.glob("dex-runs/run_*/events.jsonl"):
    events = [json.loads(line) for line in event_file.read_text().splitlines()]
    retained = []
    finished_seen = 0
    for event in events:
        if event.get("type") == "review.pass.finished":
            finished_seen += 1
            if finished_seen > 1:
                continue
        retained.append(event)
    temporary = event_file.with_name(event_file.name + ".tmp")
    temporary.write_text(
        "".join(json.dumps(event, separators=(",", ":")) + "\n" for event in retained),
        encoding="utf-8",
    )
    os.replace(temporary, event_file)
PY
if review_eval_trial_product_record_valid "$premature_trial" completed 0; then
  fail "premature product completion passed the clean-gate validator"
fi

duplicate_pass_trial="$TMP_DIR/duplicate-pass-trial"
cp -R "$managed_trial" "$duplicate_pass_trial"
python3 - "$duplicate_pass_trial" <<'PY'
import json
import os
import sys
from pathlib import Path

root = Path(sys.argv[1])
for event_file in root.glob("dex-runs/run_*/events.jsonl"):
    events = [json.loads(line) for line in event_file.read_text().splitlines()]
    first_pass = next(
        event["data"]["pass_id"]
        for event in events
        if event.get("type") == "review.pass.started"
    )
    for event in events:
        if event.get("type") in {"review.pass.started", "review.pass.finished"} and event.get("data", {}).get("iteration") == 2:
            event["data"]["pass_id"] = first_pass
    temporary = event_file.with_name(event_file.name + ".tmp")
    temporary.write_text(
        "".join(json.dumps(event, separators=(",", ":")) + "\n" for event in events),
        encoding="utf-8",
    )
    os.replace(temporary, event_file)
PY
if review_eval_trial_product_record_valid "$duplicate_pass_trial" completed 0; then
  fail "duplicate review pass identity passed the product validator"
fi

contradictory_terminal_trial="$TMP_DIR/contradictory-terminal-trial"
cp -R "$managed_trial" "$contradictory_terminal_trial"
python3 - "$contradictory_terminal_trial" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
event_file = next(root.glob("dex-runs/run_*/events.jsonl"))
with event_file.open("a", encoding="utf-8") as handle:
    for event in (
        {"type": "review.paused", "data": {"reason": "provider_error"}},
        {"type": "run.blocked", "data": {"reason": "provider_error"}},
    ):
        handle.write(json.dumps(event, separators=(",", ":")) + "\n")
PY
if review_eval_trial_product_record_valid "$contradictory_terminal_trial" completed 0; then
  fail "completed product record accepted paused and blocked terminals"
fi
if review_eval_trial_product_record_valid "$contradictory_terminal_trial" paused 2; then
  fail "paused product record accepted completed terminals"
fi

normal_trial="$TMP_DIR/normal-tier-trial"
complex_trial="$TMP_DIR/complex-tier-trial"
REVIEW_EVAL_TEST_STUB=1 \
REVIEW_EVAL_TEST_STUB_MODE=tier-normal \
  review_eval_run_trial "$runtime_source" "$runtime_source_sha" baseline \
    normal-control 1 claude "test-claude" "high" 120 "$normal_trial"
REVIEW_EVAL_TEST_STUB=1 \
REVIEW_EVAL_TEST_STUB_MODE=tier-complex \
  review_eval_run_trial "$runtime_source" "$runtime_source_sha" baseline \
    complex-control 1 claude "test-claude" "high" 120 "$complex_trial"
python3 - "$normal_trial" "$complex_trial" <<'PY'
import json
import sys
from pathlib import Path

for root_text, expected_tier, expected_waves in (
    (sys.argv[1], "normal", 6),
    (sys.argv[2], "complex", 9),
):
    root = Path(root_text)
    manifest = json.loads((root / "manifest.json").read_text())
    assessment = json.loads((root / "assessment.jsonl").read_text().splitlines()[0])
    assert manifest["status"] == "completed", manifest
    assert manifest["wave_count"] == expected_waves, manifest
    assert assessment["tier"] == expected_tier, assessment
    waves = [json.loads(line) for line in (root / "oracle-waves.jsonl").read_text().splitlines()]
    assert len(waves) == expected_waves, waves
    assert all(wave["oracle_status"] == "pass" for wave in waves), waves
PY

failed_assessment_trial="$TMP_DIR/failed-assessment-trial"
failed_assessment_status=0
REVIEW_EVAL_TEST_STUB=1 \
REVIEW_EVAL_TEST_STUB_MODE=fail-assessment \
  review_eval_run_trial "$runtime_source" "$runtime_source_sha" baseline \
    small-control 1 claude "test-claude" "high" 120 "$failed_assessment_trial" || \
      failed_assessment_status=$?
assert_eq "0" "$failed_assessment_status" "failed assessment product pause"
python3 - "$failed_assessment_trial/manifest.json" <<'PY'
import json
import sys

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
assert manifest["status"] == "paused", manifest
assert manifest["harness_reason"] is None, manifest
assert manifest["wave_count"] == 0, manifest
PY

timed_out_assessment_trial="$TMP_DIR/timed-out-assessment-trial"
REVIEW_EVAL_TEST_STUB=1 \
REVIEW_EVAL_TEST_STUB_MODE=timeout-assessment \
  review_eval_run_trial "$runtime_source" "$runtime_source_sha" baseline \
    small-control 1 claude "test-claude" "high" 120 "$timed_out_assessment_trial"
python3 - "$timed_out_assessment_trial/manifest.json" <<'PY'
import json
import sys

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
assert manifest["status"] == "paused", manifest
assert manifest["product_exit_code"] != 0, manifest
assert manifest["harness_reason"] is None, manifest
PY

mutated_runtime_trial="$TMP_DIR/mutated-runtime-trial"
mutated_runtime_status=0
REVIEW_EVAL_TEST_STUB=1 \
REVIEW_EVAL_TEST_STUB_MODE=mutate-runtime \
  review_eval_run_trial "$runtime_source" "$runtime_source_sha" baseline \
    small-control 1 claude "test-claude" "high" 120 "$mutated_runtime_trial" || \
      mutated_runtime_status=$?
[[ $mutated_runtime_status -ne 0 ]] || fail "runtime mutation trial reported success"
python3 - "$mutated_runtime_trial/manifest.json" <<'PY'
import json
import sys

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
assert manifest["status"] == "harness_error", manifest
assert manifest["harness_reason"] == "runtime_mutated", manifest
PY

censored_trial="$TMP_DIR/censored-trial"
censored_tmp="$TMP_DIR/censored-tmp"
mkdir -p "$censored_tmp"
censored_status=0
TMPDIR="$censored_tmp" \
REVIEW_EVAL_TEST_STUB=1 \
REVIEW_EVAL_TEST_STUB_MODE=hang \
  review_eval_run_trial "$runtime_source" "$runtime_source_sha" baseline \
    small-control 1 claude "test-claude" "high" 30 "$censored_trial" || \
      censored_status=$?
assert_eq "124" "$censored_status" "censored trial exit"
python3 - "$censored_trial/manifest.json" <<'PY'
import json
import os
import subprocess
import sys
import time

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
assert manifest["status"] == "censored", manifest
assert manifest["product_exit_code"] == 124, manifest
pid_path = os.path.join(os.path.dirname(sys.argv[1]), "stub-grandchild.pid")
if not os.path.exists(pid_path):
    raise AssertionError(
        "stub provider never recorded a grandchild pid; the trial timeout "
        "fired before the stub started, so reaping was never exercised"
    )
pid = int(open(pid_path, encoding="utf-8").read())
for _ in range(30):
    state = subprocess.run(
        ["ps", "-p", str(pid), "-o", "state="],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    ).stdout.strip()
    if not state:
        break
    time.sleep(0.1)
else:
    raise AssertionError(f"timed-out provider grandchild is still alive: {pid} ({state})")
PY
if find "$censored_tmp" -mindepth 1 -maxdepth 1 \
    \( -name 'dex-review-trial.*' -o -name 'dex-review-observer-*' \) \
    -print -quit 2>/dev/null | grep -q .; then
  fail "censored trial left private execution state behind"
fi

cancel_tmp="$TMP_DIR/cancel-tmp"
cancel_trial="$TMP_DIR/cancel-trial"
mkdir -p "$cancel_tmp"
TMPDIR="$cancel_tmp" \
CODEX_HOME="$fake_codex_home" \
REVIEW_EVAL_TEST_STUB=1 \
REVIEW_EVAL_TEST_STUB_MODE=hang \
  review_eval_run_trial "$runtime_source" "$runtime_source_sha" baseline \
    small-control 1 codex "test-codex" "default" 60 "$cancel_trial" &
cancel_pid=$!
cancel_ready=0
for _ in $(seq 1 200); do
  if find "$cancel_tmp" -name stub-grandchild.pid -print -quit | grep -q .; then
    cancel_ready=1
    break
  fi
  sleep 0.1
done
if [[ $cancel_ready -ne 1 ]]; then
  kill -TERM "$cancel_pid" 2>/dev/null || true
  wait "$cancel_pid" 2>/dev/null || true
  fail "cancelled trial did not reach the provider stub"
fi
kill -TERM "$cancel_pid"
cancel_status=0
wait "$cancel_pid" || cancel_status=$?
[[ $cancel_status -ne 0 ]] || fail "cancelled trial reported success"
if find "$cancel_tmp" -mindepth 1 -maxdepth 1 \
    \( -name 'dex-review-trial.*' -o -name 'dex-review-observer-*' \) \
    -print -quit 2>/dev/null | grep -q .; then
  fail "cancelled trial left its execution root behind"
fi
assert_eq '{"fake":"credential"}' "$(tr -d '\n' < "$fake_codex_home/auth.json")" \
  "external Codex auth survived cancellation"
python3 - "$fake_codex_home/auth.json" "$TMP_DIR/fake-auth-state.json" <<'PY'
import hashlib
import json
import stat
import sys
from pathlib import Path

source = Path(sys.argv[1])
before = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
after = source.stat()
assert stat.S_IMODE(after.st_mode) == before["mode"], (oct(after.st_mode), before)
assert after.st_nlink == before["links"], (after.st_nlink, before)
assert hashlib.sha256(source.read_bytes()).hexdigest() == before["sha256"]
PY

deadline_fake_bin="$TMP_DIR/deadline-fake-bin"
deadline_delay_helper="$TMP_DIR/deadline-delay.py"
deadline_delay_marker="$TMP_DIR/deadline-delay.marker"
DETACHED_TEST_PID_FILE="$TMP_DIR/deadline-detached.pid"
detached_test_parent_file="$TMP_DIR/deadline-detached-parent.pid"
deadline_real_git=$(command -v git)
deadline_real_python="$external_python_path"
mkdir -p "$deadline_fake_bin"
# shellcheck disable=SC2016  # these variables belong to the generated wrapper
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'if [[ "${1:-}" == "clone" && ! -e "$REVIEW_EVAL_DELAY_MARKER" ]]; then' \
  '  : > "$REVIEW_EVAL_DELAY_MARKER"' \
  '  exec "$REVIEW_EVAL_REAL_PYTHON" "$REVIEW_EVAL_DELAY_HELPER" "$REVIEW_EVAL_DETACHED_PID_FILE" "$REVIEW_EVAL_DETACHED_PARENT_FILE"' \
  'fi' \
  'exec "$REVIEW_EVAL_REAL_GIT" "$@"' > "$deadline_fake_bin/git"
chmod +x "$deadline_fake_bin/git"
printf '%s\n' \
  'import os' \
  'import signal' \
  'import sys' \
  'import time' \
  'from pathlib import Path' \
  '' \
  'child = os.fork()' \
  'if child == 0:' \
  '    Path(sys.argv[2]).write_text(f"{os.getpid()}\n", encoding="utf-8")' \
  '    orphan = os.fork()' \
  '    if orphan != 0:' \
  '        time.sleep(1)' \
  '        os._exit(0)' \
  '    os.setsid()' \
  '    for selected_signal in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):' \
  '        signal.signal(selected_signal, signal.SIG_IGN)' \
  '    Path(sys.argv[1]).write_text(f"{os.getpid()}\n", encoding="utf-8")' \
  '    while True:' \
  '        time.sleep(30)' \
  'os.waitpid(child, 0)' \
  'while True:' \
  '    time.sleep(30)' > "$deadline_delay_helper"

whole_deadline_trial="$TMP_DIR/whole-deadline-trial"
whole_deadline_tmp="$TMP_DIR/whole-deadline-tmp"
mkdir -p "$whole_deadline_tmp"
whole_deadline_started=$(date +%s)
whole_deadline_status=0
TMPDIR="$whole_deadline_tmp" \
PATH="$deadline_fake_bin:$PATH" \
REVIEW_EVAL_REAL_GIT="$deadline_real_git" \
REVIEW_EVAL_REAL_PYTHON="$deadline_real_python" \
REVIEW_EVAL_DELAY_HELPER="$deadline_delay_helper" \
REVIEW_EVAL_DELAY_MARKER="$deadline_delay_marker" \
REVIEW_EVAL_DETACHED_PID_FILE="$DETACHED_TEST_PID_FILE" \
REVIEW_EVAL_DETACHED_PARENT_FILE="$detached_test_parent_file" \
  review_eval_run_trial "$runtime_source" "$runtime_source_sha" baseline \
    small-control 1 claude "test-claude" "high" 2 "$whole_deadline_trial" || \
      whole_deadline_status=$?
whole_deadline_elapsed=$(( $(date +%s) - whole_deadline_started ))
assert_eq "124" "$whole_deadline_status" "whole-trial preflight deadline exit"
# The trial's deadline is 2s and its fake provider would otherwise sleep 30s,
# so any bound well under 30 proves the deadline fired rather than the work
# finishing. 7s left 5s of slack, which run-all.sh does not have: it runs eight
# tests at once, and this one was seen taking 33s on a loaded machine — a
# flake, not a regression. 20s still distinguishes the two outcomes.
[[ $whole_deadline_elapsed -le 20 ]] || \
  fail "whole-trial deadline took too long: ${whole_deadline_elapsed}s"
python3 - "$whole_deadline_trial/manifest.json" "$DETACHED_TEST_PID_FILE" <<'PY'
import json
import subprocess
import sys
import time

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
assert manifest["status"] == "censored", manifest
assert manifest["product_exit_code"] == 124, manifest
pid = int(open(sys.argv[2], encoding="utf-8").read())
for _ in range(30):
    state = subprocess.run(
        ["ps", "-p", str(pid), "-o", "state="],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    ).stdout.strip()
    if not state:
        break
    time.sleep(0.1)
else:
    raise AssertionError(f"detached preflight descendant is still alive: {pid} ({state})")
PY
if find "$whole_deadline_tmp" -mindepth 1 -maxdepth 1 \
    \( -name 'dex-review-trial.*' -o -name 'dex-review-observer-*' \) \
    -print -quit 2>/dev/null | grep -q .; then
  fail "whole-trial deadline left private execution state behind"
fi

rm -f "$deadline_delay_marker" "$DETACHED_TEST_PID_FILE" "$detached_test_parent_file"
detached_cancel_trial="$TMP_DIR/detached-cancel-trial"
detached_cancel_tmp="$TMP_DIR/detached-cancel-tmp"
mkdir -p "$detached_cancel_tmp"
TMPDIR="$detached_cancel_tmp" \
PATH="$deadline_fake_bin:$PATH" \
REVIEW_EVAL_REAL_GIT="$deadline_real_git" \
REVIEW_EVAL_REAL_PYTHON="$deadline_real_python" \
REVIEW_EVAL_DELAY_HELPER="$deadline_delay_helper" \
REVIEW_EVAL_DELAY_MARKER="$deadline_delay_marker" \
REVIEW_EVAL_DETACHED_PID_FILE="$DETACHED_TEST_PID_FILE" \
REVIEW_EVAL_DETACHED_PARENT_FILE="$detached_test_parent_file" \
  review_eval_run_trial "$runtime_source" "$runtime_source_sha" baseline \
    small-control 1 claude "test-claude" "high" 60 "$detached_cancel_trial" &
detached_cancel_pid=$!
detached_cancel_ready=0
for _ in $(seq 1 100); do
  if [[ -s "$DETACHED_TEST_PID_FILE" ]]; then
    detached_cancel_ready=1
    break
  fi
  sleep 0.1
done
if [[ $detached_cancel_ready -ne 1 ]]; then
  kill -TERM "$detached_cancel_pid" 2>/dev/null || true
  wait "$detached_cancel_pid" 2>/dev/null || true
  fail "detached cancellation trial did not reach the delayed preflight"
fi
python3 - "$detached_test_parent_file" <<'PY'
import subprocess
import sys
import time

parent_pid = int(open(sys.argv[1], encoding="utf-8").read())
for _ in range(30):
    state = subprocess.run(
        ["ps", "-p", str(parent_pid), "-o", "state="],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    ).stdout.strip()
    if not state:
        break
    time.sleep(0.1)
else:
    raise AssertionError(f"double-fork parent did not exit: {parent_pid} ({state})")
PY
detached_cancel_started=$(date +%s)
kill -TERM "$detached_cancel_pid"
detached_cancel_status=0
wait "$detached_cancel_pid" || detached_cancel_status=$?
detached_cancel_elapsed=$(( $(date +%s) - detached_cancel_started ))
assert_eq "143" "$detached_cancel_status" "detached cancellation exit"
# Same reasoning as the whole-trial bound above: the alternative to prompt
# cancellation is a 30s sleep, so 15s tells the two apart with room for load.
[[ $detached_cancel_elapsed -le 15 ]] || \
  fail "detached cancellation took too long: ${detached_cancel_elapsed}s"
python3 - "$DETACHED_TEST_PID_FILE" <<'PY'
import subprocess
import sys
import time

pid = int(open(sys.argv[1], encoding="utf-8").read())
for _ in range(30):
    state = subprocess.run(
        ["ps", "-p", str(pid), "-o", "state="],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    ).stdout.strip()
    if not state:
        break
    time.sleep(0.1)
else:
    raise AssertionError(f"detached cancelled descendant is still alive: {pid} ({state})")
PY
if find "$detached_cancel_tmp" -mindepth 1 -maxdepth 1 \
    \( -name 'dex-review-trial.*' -o -name 'dex-review-observer-*' \) \
    -print -quit 2>/dev/null | grep -q .; then
  fail "detached cancellation left private execution state behind"
fi
DETACHED_TEST_PID_FILE=""

dry_run="$TMP_DIR/dry-run.tsv"
bash "$ROOT/research/review-loop/run.sh" \
  --stage baseline --replicas 3 --runner claude --runner codex \
  --jobs 2 --dex-ref HEAD --dry-run > "$dry_run"
assert_eq "54" "$(wc -l < "$dry_run" | tr -d ' ')" "CLI dry-run matrix"

if bash "$ROOT/research/review-loop/run.sh" --stage baseline --jobs 0 --dry-run >/dev/null 2>&1; then
  fail "zero jobs should be rejected"
fi
if bash "$ROOT/research/review-loop/run.sh" --stage baseline --replicas 21 --dry-run >/dev/null 2>&1; then
  fail "excessive replicas should be rejected"
fi
if bash "$ROOT/research/review-loop/run.sh" --stage baseline --jobs 17 --dry-run >/dev/null 2>&1; then
  fail "excessive jobs should be rejected"
fi
if bash "$ROOT/research/review-loop/run.sh" --stage baseline --trial-timeout 86401 --dry-run >/dev/null 2>&1; then
  fail "excessive trial timeouts should be rejected"
fi
if bash "$ROOT/research/review-loop/run.sh" --stage unknown --dry-run >/dev/null 2>&1; then
  fail "unknown stage should be rejected"
fi
if bash "$ROOT/research/review-loop/run.sh" \
    --runner claude --runner claude --dry-run >/dev/null 2>&1; then
  fail "duplicate runners should be rejected"
fi
if REVIEW_EVAL_TEST_STUB=1 bash "$ROOT/research/review-loop/run.sh" \
    --runner claude --dry-run >/dev/null 2>&1; then
  fail "run.sh accepted the test provider stub"
fi

python3 - "$external_python_path" "$external_python_state" <<'PY'
import hashlib
import json
import stat
import sys
from pathlib import Path

source = Path(sys.argv[1])
before = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
metadata = source.stat()
after = {
    "device": metadata.st_dev,
    "inode": metadata.st_ino,
    "links": metadata.st_nlink,
    "mode": stat.S_IMODE(metadata.st_mode),
    "sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
}
assert after == before, (before, after)
PY

printf 'review-evaluation-harness-test passed\n'
