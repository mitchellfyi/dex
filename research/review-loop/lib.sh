#!/usr/bin/env bash
set -euo pipefail

_REVIEW_EVAL_SOURCE="${BASH_SOURCE[0]:-$0}"
REVIEW_EVAL_DIR="$(cd "$(dirname "$_REVIEW_EVAL_SOURCE")" && pwd)"
# shellcheck disable=SC2034  # consumed by run.sh after sourcing this library
REVIEW_EVAL_REPO_ROOT="$(cd "$REVIEW_EVAL_DIR/../.." && pwd)"
REVIEW_EVAL_SCENARIOS_DIR="${REVIEW_EVAL_SCENARIOS_DIR:-$REVIEW_EVAL_DIR/scenarios}"
REVIEW_EVAL_RESULTS_DIR="${REVIEW_EVAL_RESULTS_DIR:-${DX_RUN_ROOT:-$HOME/.dex/runs}/review-evaluations}"
REVIEW_EVAL_MAX_REPLICAS=20
# shellcheck disable=SC2034  # enforced by run.sh after sourcing this library
REVIEW_EVAL_MAX_JOBS=16
# shellcheck disable=SC2034  # enforced by run.sh after sourcing this library
REVIEW_EVAL_MAX_TRIAL_TIMEOUT=86400
unset _REVIEW_EVAL_SOURCE

review_eval_error() {
  printf 'review-loop evaluation: %s\n' "$*" >&2
}

review_eval_positive_integer() {
  local value="${1:-}"
  case "$value" in
    ""|*[!0-9]*) return 1 ;;
  esac
  while [[ "$value" == 0* ]]; do
    value="${value#0}"
  done
  [[ -n "$value" && ${#value} -le 9 ]] || return 1
  printf '%s\n' "$value"
}

review_eval_bounded_timeout() {
  local requested="$1" reserve="${2:-0}" deadline="${REVIEW_EVAL_TRIAL_DEADLINE_NS:-}"
  review_eval_positive_integer "$requested" >/dev/null || return 1
  case "$reserve" in
    ""|*[!0-9]*) return 1 ;;
  esac
  if [[ -z "$deadline" ]]; then
    printf '%s\n' "$requested"
    return 0
  fi
  case "$deadline" in
    *[!0-9]*) return 1 ;;
  esac
  python3 - "$requested" "$reserve" "$deadline" <<'PY'
import math
import sys
import time

requested = int(sys.argv[1])
reserve = int(sys.argv[2])
deadline = int(sys.argv[3])
remaining = (deadline - time.monotonic_ns()) / 1_000_000_000 - reserve
if remaining <= 0:
    raise SystemExit(1)
print(max(1, min(requested, math.ceil(remaining))))
PY
}

review_eval_scenario_name_valid() {
  local name="${1:-}"
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] && [[ "$name" != *".."* ]]
}

review_eval_scenario_dir() {
  local scenario="${1:-}"
  review_eval_scenario_name_valid "$scenario" || return 1
  printf '%s/%s\n' "$REVIEW_EVAL_SCENARIOS_DIR" "$scenario"
}

review_eval_list_scenarios() {
  [[ -d "$REVIEW_EVAL_SCENARIOS_DIR" ]] || return 1
  find "$REVIEW_EVAL_SCENARIOS_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | LC_ALL=C sort
}

review_eval_validate_catalog() {
  python3 - "$REVIEW_EVAL_SCENARIOS_DIR" <<'PY'
import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
expected = {
    "small-control": ("small", "small", True),
    "small-zero-missing": ("small", "small", False),
    "small-off-by-one": ("small", "small", False),
    "normal-control": ("normal", "small", True),
    "normal-contract-mismatch": ("normal", "small", False),
    "normal-error-masking": ("normal", "small", False),
    "complex-control": ("complex", "complex", True),
    "complex-tenant-cache": ("complex", "complex", False),
    "complex-lock-ownership": ("complex", "complex", False),
}
actual = {path.name for path in root.iterdir() if path.is_dir()} if root.is_dir() else set()
if actual != set(expected):
    raise SystemExit(f"scenario catalog mismatch: expected {sorted(expected)}, got {sorted(actual)}")

required = {
    "schema_version",
    "id",
    "tier",
    "expected_tier",
    "expected_floor",
    "control",
    "visible_test_command",
    "hidden_oracle_command",
    "candidate_overlay",
    "expected_candidate_oracle",
    "description",
}
allowed = required | {"canonical_fix_overlay"}

for scenario, (tier, floor, control) in expected.items():
    directory = root / scenario
    try:
        data = json.loads((directory / "scenario.json").read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise SystemExit(f"{scenario}: invalid scenario.json: {exc}")
    if not isinstance(data, dict) or not required.issubset(data) or not set(data).issubset(allowed):
        raise SystemExit(f"{scenario}: scenario.json keys do not match the contract")
    if data["id"] != scenario or data["tier"] != tier or data["expected_tier"] != tier:
        raise SystemExit(f"{scenario}: tier metadata does not match the catalog")
    if data["schema_version"] != 1:
        raise SystemExit(f"{scenario}: unsupported schema version")
    if data["expected_floor"] != floor or data["control"] is not control:
        raise SystemExit(f"{scenario}: floor/control metadata does not match the catalog")
    expected_oracle = "pass" if control else "fail"
    if data["expected_candidate_oracle"] != expected_oracle:
        raise SystemExit(f"{scenario}: candidate oracle expectation does not match the catalog")
    if not isinstance(data["description"], str) or not data["description"].strip():
        raise SystemExit(f"{scenario}: description must be non-empty")
    for key in ("visible_test_command", "hidden_oracle_command"):
        value = data[key]
        if not isinstance(value, list) or not value or any(not isinstance(item, str) or not item for item in value):
            raise SystemExit(f"{scenario}: {key} must be a non-empty string array")
    overlay = data["candidate_overlay"]
    if not isinstance(overlay, str) or not re.fullmatch(r"[A-Za-z0-9._-]+", overlay):
        raise SystemExit(f"{scenario}: invalid candidate overlay")
    if not (directory / "base").is_dir() or not (directory / overlay).is_dir():
        raise SystemExit(f"{scenario}: base or candidate overlay is missing")
    fix = data.get("canonical_fix_overlay")
    if control:
        if fix not in (None, ""):
            raise SystemExit(f"{scenario}: controls cannot define a canonical fix")
    elif not isinstance(fix, str) or not re.fullmatch(r"[A-Za-z0-9._-]+", fix) or not (directory / fix).is_dir():
        raise SystemExit(f"{scenario}: defect scenario is missing its canonical fix")
    rendered_oracle = [part.replace("{scenario_dir}", str(directory)).replace("{workspace}", "/workspace") for part in data["hidden_oracle_command"]]
    oracle_paths = [Path(part) for part in rendered_oracle if part.startswith(str(directory))]
    if not oracle_paths or any(not path.is_file() for path in oracle_paths):
        raise SystemExit(f"{scenario}: hidden oracle command does not name a scenario file")
PY
}

review_eval_scenario_field() {
  local scenario="$1" field="$2" directory
  directory=$(review_eval_scenario_dir "$scenario") || return 1
  python3 - "$directory/scenario.json" "$field" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
if sys.argv[2] not in data:
    raise SystemExit(1)
value = data[sys.argv[2]]
if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("")
elif isinstance(value, (str, int)) and not isinstance(value, bool):
    print(value)
else:
    print(json.dumps(value, separators=(",", ":")))
PY
}

review_eval_copy_overlay() {
  local source_dir="$1" target_dir="$2"
  [[ -d "$source_dir" && -d "$target_dir" ]] || return 1
  cp -R "$source_dir/." "$target_dir/"
}

review_eval_prepare_workspace() {
  local scenario="$1" trial_dir="$2" scenario_root seed_repo origin_repo workspace overlay
  scenario_root=$(review_eval_scenario_dir "$scenario") || return 1
  [[ -f "$scenario_root/scenario.json" && -d "$scenario_root/base" ]] || return 1
  [[ ! -e "$trial_dir" ]] || {
    review_eval_error "trial path already exists: $trial_dir"
    return 1
  }

  seed_repo="$trial_dir/seed"
  origin_repo="$trial_dir/origin.git"
  workspace="$trial_dir/workspace"
  mkdir -p "$seed_repo"
  review_eval_copy_overlay "$scenario_root/base" "$seed_repo"
  git -C "$seed_repo" init -q -b main
  git -C "$seed_repo" config user.name "Dex Review Evaluation"
  git -C "$seed_repo" config user.email "review-eval@dex.local"
  git -C "$seed_repo" add -A
  git -C "$seed_repo" commit -qm "test: seed review evaluation"

  git clone -q --bare "$seed_repo" "$origin_repo"
  git clone -q "$origin_repo" "$workspace"
  git -C "$workspace" config user.name "Dex Review Evaluation"
  git -C "$workspace" config user.email "review-eval@dex.local"
  git -C "$workspace" checkout -qb "review-eval/candidate"

  overlay=$(review_eval_scenario_field "$scenario" candidate_overlay) || return 1
  review_eval_copy_overlay "$scenario_root/$overlay" "$workspace"
  [[ -n "$(git -C "$workspace" status --porcelain)" ]] || {
    review_eval_error "$scenario candidate overlay does not change the baseline"
    return 1
  }
  git -C "$workspace" add -A
  git -C "$workspace" commit -qm "feat: apply review candidate"
  printf '%s\n' "$workspace"
}

review_eval_run_scenario_command() {
  local scenario="$1" workspace="$2" field="$3" log_file="${4:-}" scenario_root
  scenario_root=$(review_eval_scenario_dir "$scenario") || return 1
  REVIEW_EVAL_SCENARIO_ROOT="$scenario_root" \
  REVIEW_EVAL_WORKSPACE="$workspace" \
  REVIEW_EVAL_COMMAND_FIELD="$field" \
  REVIEW_EVAL_LOG_FILE="$log_file" \
    python3 - "$scenario_root/scenario.json" <<'PY'
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

metadata_path = Path(sys.argv[1])
with metadata_path.open(encoding="utf-8") as handle:
    metadata = json.load(handle)
scenario_root = os.environ["REVIEW_EVAL_SCENARIO_ROOT"]
workspace = os.environ["REVIEW_EVAL_WORKSPACE"]
command = [
    part.replace("{scenario_dir}", scenario_root).replace("{workspace}", workspace)
    for part in metadata[os.environ["REVIEW_EVAL_COMMAND_FIELD"]]
]
log_path = os.environ.get("REVIEW_EVAL_LOG_FILE", "")
timeout_text = os.environ.get("REVIEW_EVAL_CHECK_TIMEOUT_SECONDS", "60")
if not timeout_text.isdigit() or not 1 <= int(timeout_text) <= 600:
    raise SystemExit("invalid review evaluation check timeout")
timeout = float(timeout_text)
deadline_text = os.environ.get("REVIEW_EVAL_TRIAL_DEADLINE_NS", "")
if deadline_text:
    if not deadline_text.isdigit():
        raise SystemExit("invalid review evaluation trial deadline")
    remaining = (int(deadline_text) - time.monotonic_ns()) / 1_000_000_000
    if remaining <= 0:
        raise SystemExit(124)
    timeout = min(timeout, remaining)
subprocess_environment = {
    key: os.environ[key]
    for key in ("LANG", "LC_ALL", "PATH", "TMPDIR")
    if key in os.environ
}


def run(output):
    process = subprocess.Popen(
        command,
        cwd=workspace,
        env=subprocess_environment,
        stdout=output,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )

    def signal_group(selected_signal):
        try:
            os.killpg(process.pid, selected_signal)
        except ProcessLookupError:
            pass

    def terminate_group(grace_seconds):
        signal_group(signal.SIGTERM)
        deadline = time.monotonic() + grace_seconds
        while time.monotonic() < deadline:
            try:
                os.killpg(process.pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.05)
        signal_group(signal.SIGKILL)
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            signal_group(signal.SIGKILL)
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            signal_group(signal.SIGKILL)

    try:
        return_code = process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        terminate_group(2)
        return 124
    terminate_group(0.2)
    return return_code


with tempfile.TemporaryDirectory(prefix="dex-review-check-") as isolated_home:
    subprocess_environment["HOME"] = isolated_home
    if log_path:
        path = Path(log_path)
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("wb") as log:
            return_code = run(log)
    else:
        return_code = run(subprocess.DEVNULL)
raise SystemExit(return_code)
PY
}

review_eval_run_visible_check() {
  review_eval_run_scenario_command "$1" "$2" visible_test_command "${3:-}"
}

review_eval_oracle_status() {
  local status=0
  review_eval_run_scenario_command "$1" "$2" hidden_oracle_command "${3:-}" || status=$?
  case "$status" in
    0) printf '%s\n' "pass" ;;
    1) printf '%s\n' "fail" ;;
    *) printf '%s\n' "invalid" ;;
  esac
}

review_eval_apply_canonical_fix() {
  local scenario="$1" workspace="$2" scenario_root overlay
  scenario_root=$(review_eval_scenario_dir "$scenario") || return 1
  overlay=$(review_eval_scenario_field "$scenario" canonical_fix_overlay) || return 1
  [[ -n "$overlay" && -d "$scenario_root/$overlay" ]] || return 1
  review_eval_copy_overlay "$scenario_root/$overlay" "$workspace"
}

review_eval_score_snapshots() {
  local scenario="$1" result_dir="$2" scenario_root
  scenario_root=$(review_eval_scenario_dir "$scenario") || return 1
  [[ -f "$scenario_root/scenario.json" && -f "$result_dir/waves.jsonl" ]] || return 1
  REVIEW_EVAL_SCORE_SCENARIO_ROOT="$scenario_root" \
  REVIEW_EVAL_SCORE_RESULT_DIR="$result_dir" \
    python3 - <<'PY'
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path, PurePosixPath

scenario_root = Path(os.environ["REVIEW_EVAL_SCORE_SCENARIO_ROOT"]).resolve()
result_root = Path(os.environ["REVIEW_EVAL_SCORE_RESULT_DIR"]).resolve()
metadata = json.loads((scenario_root / "scenario.json").read_text(encoding="utf-8"))
command_template = metadata["hidden_oracle_command"]
timeout_text = os.environ.get("REVIEW_EVAL_CHECK_TIMEOUT_SECONDS", "60")
if not timeout_text.isdigit() or not 1 <= int(timeout_text) <= 600:
    raise SystemExit("invalid review evaluation check timeout")
timeout = float(timeout_text)
deadline_text = os.environ.get("REVIEW_EVAL_TRIAL_DEADLINE_NS", "")
if deadline_text and not deadline_text.isdigit():
    raise SystemExit("invalid review evaluation trial deadline")
subprocess_environment = {
    key: os.environ[key]
    for key in ("LANG", "LC_ALL", "PATH", "TMPDIR")
    if key in os.environ
}
rows = []
seen_iterations = set()


def command_timeout():
    if not deadline_text:
        return timeout
    remaining = (int(deadline_text) - time.monotonic_ns()) / 1_000_000_000
    if remaining <= 0:
        raise TimeoutError
    return min(timeout, remaining)


with tempfile.TemporaryDirectory(prefix="dex-review-oracle-") as isolated_home:
    subprocess_environment["HOME"] = isolated_home
    for line in (result_root / "waves.jsonl").read_text(encoding="utf-8").splitlines():
        payload = json.loads(line)
        if not isinstance(payload, dict) or "snapshot" not in payload or "iteration" not in payload:
            raise SystemExit("invalid wave capture")
        iteration = payload["iteration"]
        if isinstance(iteration, bool) or not isinstance(iteration, int) or iteration < 1 or iteration in seen_iterations:
            raise SystemExit("invalid wave iteration")
        seen_iterations.add(iteration)
        relative = PurePosixPath(payload["snapshot"])
        if relative.is_absolute() or any(part in ("", ".", "..") for part in relative.parts):
            raise SystemExit("unsafe wave snapshot")
        snapshot = result_root.joinpath(*relative.parts).resolve()
        if result_root not in snapshot.parents or not snapshot.is_dir():
            raise SystemExit("wave snapshot is missing")
        command = [
            part.replace("{scenario_dir}", str(scenario_root)).replace("{workspace}", str(snapshot))
            for part in command_template
        ]
        log_dir = result_root / "oracle"
        log_dir.mkdir(parents=True, exist_ok=True)
        log_path = log_dir / f"wave-{iteration:04d}.log"
        with log_path.open("wb") as log:
            process = subprocess.Popen(
                command,
                cwd=snapshot,
                env=subprocess_environment,
                stdout=log,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )

            def signal_group(selected_signal):
                try:
                    os.killpg(process.pid, selected_signal)
                except ProcessLookupError:
                    pass

            def terminate_group(grace_seconds):
                signal_group(signal.SIGTERM)
                deadline = time.monotonic() + grace_seconds
                while time.monotonic() < deadline:
                    try:
                        os.killpg(process.pid, 0)
                    except ProcessLookupError:
                        break
                    time.sleep(0.05)
                signal_group(signal.SIGKILL)
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    signal_group(signal.SIGKILL)

            try:
                return_code = process.wait(timeout=command_timeout())
            except (subprocess.TimeoutExpired, TimeoutError):
                terminate_group(2)
                return_code = 124
            else:
                terminate_group(0.2)
        payload["oracle_status"] = "pass" if return_code == 0 else "fail" if return_code == 1 else "invalid"
        rows.append(payload)

target = result_root / "oracle-waves.jsonl"
temporary = target.with_name(target.name + f".tmp.{os.getpid()}")
with temporary.open("w", encoding="utf-8") as handle:
    for payload in rows:
        handle.write(json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n")
os.replace(temporary, target)
if any(payload["oracle_status"] == "invalid" for payload in rows):
    raise SystemExit(1)
PY
}

review_eval_record_assessment() {
  local result_dir="$1" record="$2" tier reason_codes extra
  IFS=$'\t' read -r tier reason_codes extra <<EOF
$record
EOF
  [[ -n "$tier" && -n "$reason_codes" && -z "${extra:-}" ]] || return 1
  REVIEW_EVAL_ASSESSMENT_FILE="$result_dir/assessment.jsonl" \
  REVIEW_EVAL_ASSESSMENT_TIER="$tier" \
  REVIEW_EVAL_ASSESSMENT_REASONS="$reason_codes" \
    python3 - <<'PY'
import json
import os

payload = {
    "reason_codes": os.environ["REVIEW_EVAL_ASSESSMENT_REASONS"],
    "tier": os.environ["REVIEW_EVAL_ASSESSMENT_TIER"],
}
with open(os.environ["REVIEW_EVAL_ASSESSMENT_FILE"], "a", encoding="utf-8") as handle:
    handle.write(json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n")
PY
}

review_eval_prepare_runtime() {
  local source_repo="$1" requested_ref="$2" runtime_dir="$3" resolved_sha
  [[ -d "$source_repo/.git" || -f "$source_repo/.git" ]] || return 1
  [[ ! -e "$runtime_dir" ]] || return 1
  resolved_sha=$(git -C "$source_repo" rev-parse --verify "${requested_ref}^{commit}") || return 1
  mkdir -p "$runtime_dir"
  # scripts/ is part of the runtime surface: lib/ imports helpers from it
  # (dex_redact.py, run-log-tee.py), so omitting it leaves a pinned runtime
  # whose event emission fails at import time.
  if ! git -C "$source_repo" archive "$resolved_sha" \
      dx.sh settings.json bin hooks lib prompts scripts skills \
      research/review-loop/launch.zsh research/review-loop/agent-observer.sh | \
      tar -xf - -C "$runtime_dir"; then
    review_eval_error "could not extract the pinned agent runtime"
    return 1
  fi

  [[ -f "$runtime_dir/research/review-loop/launch.zsh" && \
     -f "$runtime_dir/research/review-loop/agent-observer.sh" ]] || {
    review_eval_error "pinned Dex ref does not contain the review-loop launcher"
    return 1
  }
  chmod +x "$runtime_dir/research/review-loop/launch.zsh"
  [[ ! -e "$runtime_dir/.git" ]] || return 1
  if find "$runtime_dir" \( -type l -o -path '*/hidden/*' -o \
      -path '*/canonical_fix/*' -o -iname '*oracle*' \) \
      -print -quit | grep -q .; then
    review_eval_error "sanitized runtime contains a link or evaluation truth"
    return 1
  fi
  printf '%s\n' "$resolved_sha"
}

review_eval_runtime_tree_hash() {
  local runtime_dir="$1"
  [[ -d "$runtime_dir" && ! -L "$runtime_dir" ]] || return 1
  python3 - "$runtime_dir" <<'PY'
import hashlib
import os
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
digest = hashlib.sha256(b"dex-review-runtime-v1\0")
for current, directories, files in os.walk(root, followlinks=False):
    current_path = Path(current)
    directories.sort()
    files.sort()
    for name in [*directories, *files]:
        path = current_path / name
        relative = path.relative_to(root).as_posix().encode("utf-8")
        mode = path.lstat().st_mode
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        if stat.S_ISDIR(mode):
            digest.update(b"D")
        elif stat.S_ISREG(mode):
            digest.update(b"F")
            digest.update((mode & 0o111).to_bytes(2, "big"))
            with path.open("rb") as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    digest.update(chunk)
        else:
            raise SystemExit("unsupported runtime file type")
print(digest.hexdigest())
PY
}

review_eval_runtime_make_read_only() {
  local runtime_dir="$1"
  [[ -d "$runtime_dir" && ! -L "$runtime_dir" ]] || return 1
  python3 - "$runtime_dir" <<'PY'
import os
import stat
import sys
from pathlib import Path

root = Path(os.path.abspath(sys.argv[1]))
if any(
    not hasattr(os, name)
    for name in ("O_CLOEXEC", "O_DIRECTORY", "O_NOFOLLOW", "fwalk")
):
    raise SystemExit("platform lacks safe runtime permission primitives")


def chmod_regular(name, directory_fd, expected, mode):
    flags = (
        os.O_RDONLY
        | os.O_CLOEXEC
        | os.O_NOFOLLOW
        | getattr(os, "O_NONBLOCK", 0)
    )
    descriptor = os.open(name, flags, dir_fd=directory_fd)
    try:
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_nlink != 1
            or (metadata.st_dev, metadata.st_ino) != expected
        ):
            raise OSError("runtime file is not an isolated regular file")
        os.fchmod(descriptor, mode)
    finally:
        os.close(descriptor)


for _, directories, files, directory_fd in os.fwalk(
    root, topdown=False, follow_symlinks=False
):
    for name in files:
        metadata = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        if stat.S_ISREG(metadata.st_mode):
            chmod_regular(
                name,
                directory_fd,
                (metadata.st_dev, metadata.st_ino),
                0o555 if metadata.st_mode & 0o111 else 0o444,
            )
        else:
            raise SystemExit("unsupported runtime file type")
    for name in directories:
        metadata = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        if not stat.S_ISDIR(metadata.st_mode):
            raise SystemExit("unsupported runtime directory type")
    if not stat.S_ISDIR(os.fstat(directory_fd).st_mode):
        raise SystemExit("runtime directory changed type")
    os.fchmod(directory_fd, 0o555)
PY
}

review_eval_collect_observer_artifacts() {
  local agent_result="$1" trial_dir="$2" execution_parent="$3" observer_token="$4" required="$5"
  REVIEW_EVAL_OBSERVER_SOURCE="$agent_result" \
  REVIEW_EVAL_OBSERVER_TARGET="$trial_dir" \
  REVIEW_EVAL_OBSERVER_PARENT="$execution_parent" \
  REVIEW_EVAL_OBSERVER_TOKEN="$observer_token" \
  REVIEW_EVAL_OBSERVER_REQUIRED="$required" \
    python3 - <<'PY'
import os
import re
import shutil
import stat
from pathlib import Path

source = Path(os.environ["REVIEW_EVAL_OBSERVER_SOURCE"])
target = Path(os.environ["REVIEW_EVAL_OBSERVER_TARGET"])
expected_parent = Path(os.environ["REVIEW_EVAL_OBSERVER_PARENT"]).resolve()
observer_token = os.environ["REVIEW_EVAL_OBSERVER_TOKEN"]
required = os.environ["REVIEW_EVAL_OBSERVER_REQUIRED"] == "true"
pointer = source / ".observer-pointer"
if not pointer.exists():
    if required:
        raise SystemExit("observer handoff is missing")
    raise SystemExit(0)
if not stat.S_ISREG(pointer.lstat().st_mode) or pointer.is_symlink():
    raise SystemExit("observer handoff is not a regular file")
lines = pointer.read_text(encoding="utf-8").splitlines()
if len(lines) != 1:
    raise SystemExit("observer handoff is malformed")
ready = Path(lines[0])
if (
    not ready.is_absolute()
    or ready.parent.resolve() != expected_parent
    or not re.fullmatch(
        rf"dex-review-observer-{re.escape(observer_token)}\.[A-Za-z0-9]+\.ready",
        ready.name,
    )
    or not ready.is_dir()
    or ready.is_symlink()
):
    raise SystemExit("observer handoff path is invalid")

allowed = {
    "assessment.jsonl",
    "capture-error",
    "provider-observations.jsonl",
    "snapshots",
    "waves.jsonl",
}
try:
    names = {path.name for path in ready.iterdir()}
    if not names <= allowed:
        raise SystemExit("observer handoff contains unexpected entries")
    for current, directories, files in os.walk(ready, followlinks=False):
        current_path = Path(current)
        for name in [*directories, *files]:
            path = current_path / name
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode) or not (stat.S_ISDIR(mode) or stat.S_ISREG(mode)):
                raise SystemExit("observer handoff contains an unsafe file")
    for name in sorted(names):
        source_path = ready / name
        target_path = target / name
        if target_path.exists() or target_path.is_symlink():
            raise SystemExit("observer handoff collides with controller output")
        if source_path.is_dir():
            shutil.copytree(source_path, target_path)
        else:
            shutil.copy2(source_path, target_path)
finally:
    shutil.rmtree(ready, ignore_errors=True)
    try:
        pointer.unlink()
    except FileNotFoundError:
        pass
PY
}

review_eval_collect_product_events() {
  local agent_result="$1" trial_dir="$2"
  REVIEW_EVAL_PRODUCT_SOURCE="$agent_result" \
  REVIEW_EVAL_PRODUCT_TARGET="$trial_dir" \
    python3 - <<'PY'
import os
import re
import shutil
import stat
from pathlib import Path

source = Path(os.environ["REVIEW_EVAL_PRODUCT_SOURCE"]) / "dex-runs"
target = Path(os.environ["REVIEW_EVAL_PRODUCT_TARGET"]) / "dex-runs"
if not source.exists():
    raise SystemExit(0)
if not source.is_dir() or source.is_symlink():
    raise SystemExit("product run root is unsafe")
total_size = 0
for current, directories, files in os.walk(source, followlinks=False):
    current_path = Path(current)
    for name in [*directories, *files]:
        path = current_path / name
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode) or not (stat.S_ISDIR(mode) or stat.S_ISREG(mode)):
            raise SystemExit("product run root contains an unsafe file")
        if stat.S_ISREG(mode):
            total_size += path.stat().st_size
if total_size > 100 * 1024 * 1024:
    raise SystemExit("product run output exceeds the evaluation limit")

target.mkdir()
for run_dir in sorted(path for path in source.iterdir() if path.is_dir()):
    if not re.fullmatch(r"run_[A-Za-z0-9._-]+", run_dir.name):
        raise SystemExit("invalid product run directory")
    selected = [path for path in (run_dir / "events.jsonl", run_dir / "summary.json") if path.is_file()]
    if not selected:
        continue
    destination = target / run_dir.name
    destination.mkdir()
    for path in selected:
        if path.is_symlink() or not stat.S_ISREG(path.lstat().st_mode):
            raise SystemExit("product event artifact is unsafe")
        shutil.copy2(path, destination / path.name)
PY
}

review_eval_seal_provider_output() {
  local agent_result="$1" trial_dir="$2"
  REVIEW_EVAL_PROVIDER_SOURCE="$agent_result" \
  REVIEW_EVAL_PROVIDER_TARGET="$trial_dir/provider-output.json" \
    python3 - <<'PY'
import hashlib
import json
import os
import stat
from pathlib import Path

source = Path(os.environ["REVIEW_EVAL_PROVIDER_SOURCE"])
payload = {"schema_version": 1}
for name in ("stdout.log", "stderr.log"):
    path = source / name
    if not path.exists():
        payload[name[:-4]] = {"bytes": 0, "sha256": hashlib.sha256().hexdigest()}
        continue
    if path.is_symlink() or not stat.S_ISREG(path.lstat().st_mode):
        raise SystemExit("provider output is unsafe")
    content = path.read_bytes()
    payload[name[:-4]] = {
        "bytes": len(content),
        "sha256": hashlib.sha256(content).hexdigest(),
    }
    path.unlink()
target = Path(os.environ["REVIEW_EVAL_PROVIDER_TARGET"])
temporary = target.with_name(target.name + f".tmp.{os.getpid()}")
with temporary.open("w", encoding="utf-8") as handle:
    json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
os.replace(temporary, target)
PY
}

review_eval_trial_product_record_valid() {
  local trial_dir="$1" expected_terminal="$2" product_exit="${3:-}"
  case "$expected_terminal" in
    completed|paused) ;;
    *) return 1 ;;
  esac
  [[ "$product_exit" =~ ^[0-9]+$ ]] || return 1
  python3 - "$trial_dir" "$expected_terminal" "$product_exit" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
expected = sys.argv[2]
product_exit = int(sys.argv[3])


def json_lines(path):
    if not path.is_file():
        return []
    return [
        json.loads(line)
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]


assessments = json_lines(root / "assessment.jsonl")
events = []
for event_file in sorted((root / "dex-runs").glob("run_*/events.jsonl")):
    events.extend(json_lines(event_file))
types = [event.get("type") for event in events]
selected = [event for event in events if event.get("type") == "review.tier.selected"]
paused = [event for event in events if event.get("type") == "review.paused"]
blocked = [event for event in events if event.get("type") == "run.blocked"]
review_completed = [event for event in events if event.get("type") == "review.completed"]
run_completed = [event for event in events if event.get("type") == "run.completed"]
if expected == "paused" and not selected:
    pre_tier_reasons = {
        "assessment_invalid",
        "assessment_mutated_scope",
        "assessment_provider_error",
        "assessment_timeout",
        "review_criteria_changed",
    }
    pause_reasons = [event.get("data", {}).get("reason") for event in paused]
    blocked_reasons = [event.get("data", {}).get("reason") for event in blocked]
    if (
        assessments
        or product_exit == 0
        or len(paused) != 1
        or len(blocked) != 1
        or pause_reasons[0] not in pre_tier_reasons
        or blocked_reasons != pause_reasons
        or any(
            event_type in types
            for event_type in (
                "review.pass.started",
                "review.pass.finished",
                "review.tier.escalated",
                "review.completed",
                "run.completed",
            )
        )
    ):
        raise SystemExit(1)
    if pause_reasons[0] == "assessment_timeout" and paused[0].get("data", {}).get("provider_exit") != 124:
        raise SystemExit(1)
    raise SystemExit(0)
if (
    len(assessments) != 1
    or assessments[0].get("tier") not in {"small", "normal", "complex"}
    or len(selected) != 1
    or selected[0].get("data", {}).get("tier") not in {"small", "normal", "complex"}
):
    raise SystemExit(1)
resolved_tier = selected[0]["data"]["tier"]
for event in events:
    if event.get("type") == "review.tier.escalated":
        candidate = event.get("data", {}).get("tier")
        if candidate not in {"small", "normal", "complex"}:
            raise SystemExit(1)
        resolved_tier = candidate
if expected == "completed":
    if product_exit != 0:
        raise SystemExit(1)
    if (
        len(review_completed) != 1
        or len(run_completed) != 1
        or paused
        or blocked
    ):
        raise SystemExit(1)
    completion = review_completed[0]
    completion_data = completion.get("data", {})
    required = {"small": 3, "normal": 6, "complex": 9}[resolved_tier]
    started = [event.get("data", {}) for event in events if event.get("type") == "review.pass.started"]
    finished = [event.get("data", {}) for event in events if event.get("type") == "review.pass.finished"]
    started_keys = [(event.get("iteration"), event.get("pass_id")) for event in started]
    finished_keys = [(event.get("iteration"), event.get("pass_id")) for event in finished]
    if (
        completion_data.get("tier") != resolved_tier
        or completion_data.get("required_clean") != required
        or completion_data.get("clean_passes") != required
        or completion_data.get("iterations") != len(finished)
        or len(finished) < required
        or started_keys != finished_keys
        or len({pass_id for _, pass_id in finished_keys}) != len(finished_keys)
        or any(not isinstance(pass_id, str) or not pass_id for _, pass_id in finished_keys)
    ):
        raise SystemExit(1)
    final_gate = finished[-required:]
    if [event.get("iteration") for event in finished] != list(range(1, len(finished) + 1)):
        raise SystemExit(1)
    if any(event.get("result_kind") != "clean" for event in final_gate):
        raise SystemExit(1)
    if [event.get("clean_after") for event in final_gate] != list(range(1, required + 1)):
        raise SystemExit(1)
else:
    if (
        product_exit == 0
        or len(paused) != 1
        or len(blocked) != 1
        or review_completed
        or run_completed
    ):
        raise SystemExit(1)
PY
}

__review_eval_copy_private_auth() {
  [[ $# -eq 2 ]] || return 1
  local source_file="$1" target_file="$2"
  [[ -f "$source_file" && ! -L "$source_file" ]] || return 1
  [[ -d "$(dirname "$target_file")" && ! -L "$(dirname "$target_file")" ]] || return 1
  [[ ! -e "$target_file" && ! -L "$target_file" ]] || return 1
  python3 - "$source_file" "$target_file" <<'PY'
import os
import stat
import sys
from pathlib import Path

source_path = Path(sys.argv[1])
target_path = Path(sys.argv[2])
temporary_path = target_path.with_name(f".{target_path.name}.tmp.{os.getpid()}")
if not hasattr(os, "O_NOFOLLOW") or not hasattr(os, "O_CLOEXEC"):
    raise SystemExit("platform lacks safe auth-copy primitives")
no_follow = os.O_NOFOLLOW
source_fd = None
target_fd = None
try:
    try:
        before = source_path.lstat()
        if not stat.S_ISREG(before.st_mode):
            raise OSError("auth source is not a regular file")
        source_fd = os.open(source_path, os.O_RDONLY | os.O_CLOEXEC | no_follow)
        opened = os.fstat(source_fd)
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            raise OSError("auth source changed while opening")
        target_fd = os.open(
            temporary_path,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | no_follow,
            0o600,
        )
        total = 0
        while True:
            chunk = os.read(source_fd, 1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            view = memoryview(chunk)
            while view:
                written = os.write(target_fd, view)
                if written <= 0:
                    raise OSError("auth copy stopped early")
                view = view[written:]
        os.fchmod(target_fd, 0o600)
        os.fsync(target_fd)
        after = os.fstat(source_fd)
        if (
            total != opened.st_size
            or (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
            != (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns)
        ):
            raise OSError("auth source changed while copying")
    finally:
        if target_fd is not None:
            os.close(target_fd)
        if source_fd is not None:
            os.close(source_fd)
    os.replace(temporary_path, target_path)
except BaseException:
    temporary_path.unlink(missing_ok=True)
    raise
PY
}

__review_eval_link_claude_keychains() {
  [[ $# -eq 2 ]] || return 1
  local external_home="$1" trial_home="$2"
  local source_dir="$external_home/Library/Keychains"
  [[ -d "$source_dir" && ! -L "$source_dir" ]] || return 0
  python3 - "$source_dir" "$trial_home/Library/Keychains" <<'PY'
import os
import stat
import sys
from pathlib import Path

source = Path(os.path.abspath(sys.argv[1]))
target = Path(sys.argv[2])
before = source.lstat()
if not stat.S_ISDIR(before.st_mode):
    raise SystemExit("Claude keychain source is not a directory")
target.parent.mkdir(mode=0o700)
parent = target.parent.lstat()
if not stat.S_ISDIR(parent.st_mode) or target.parent.is_symlink():
    raise SystemExit("Claude keychain target parent is unsafe")
target.parent.chmod(0o700)
os.symlink(source, target, target_is_directory=True)
after = source.lstat()
if (
    not stat.S_ISDIR(after.st_mode)
    or (after.st_dev, after.st_ino) != (before.st_dev, before.st_ino)
):
    target.unlink(missing_ok=True)
    raise SystemExit("Claude keychain source changed while linking")
PY
}

review_eval_prepare_trial_home() {
  local runtime_dir="$1" trial_home="$2"
  local runner="${3:-claude}" external_codex_home="${4:-${CODEX_HOME:-$HOME/.codex}}"
  local external_claude_home="${5:-$HOME}" platform="${6:-}"
  [[ -f "$runtime_dir/settings.json" && -d "$runtime_dir/skills" ]] || return 1
  [[ ! -e "$trial_home" && ! -L "$trial_home" ]] || return 1
  case "$runner" in
    claude|codex) ;;
    *) return 1 ;;
  esac
  if [[ -z "$platform" ]]; then
    platform=$(uname -s 2>/dev/null || true)
  fi
  mkdir -p "$trial_home/.claude" "$trial_home/.codex"
  chmod 700 "$trial_home" "$trial_home/.claude" "$trial_home/.codex"
  cp "$runtime_dir/settings.json" "$trial_home/.claude/settings.json"
  ln -s "$runtime_dir/skills" "$trial_home/.claude/skills"

  if [[ "$runner" == "claude" && "$platform" == "Darwin" ]]; then
    if ! __review_eval_link_claude_keychains "$external_claude_home" "$trial_home"; then
      review_eval_error "could not create the isolated Claude keychain bridge"
      return 1
    fi
  elif [[ "$runner" == "claude" && \
          -f "$external_claude_home/.claude/.credentials.json" && \
          ! -L "$external_claude_home/.claude/.credentials.json" ]]; then
    if ! __review_eval_copy_private_auth \
      "$external_claude_home/.claude/.credentials.json" \
      "$trial_home/.claude/.credentials.json"; then
      review_eval_error "could not create the isolated Claude auth copy"
      return 1
    fi
  elif [[ "$runner" == "codex" && -f "$external_codex_home/auth.json" && \
          ! -L "$external_codex_home/auth.json" ]]; then
    if ! __review_eval_copy_private_auth \
      "$external_codex_home/auth.json" "$trial_home/.codex/auth.json"; then
      review_eval_error "could not create the isolated Codex auth copy"
      return 1
    fi
  fi
}

review_eval_matrix_rows() {
  local replicas_raw="$1" replicas scenario provider replica
  shift
  replicas=$(review_eval_positive_integer "$replicas_raw") || return 1
  [[ "$replicas" -le "$REVIEW_EVAL_MAX_REPLICAS" ]] || return 1
  [[ $# -gt 0 ]] || return 1
  for provider in "$@"; do
    case "$provider" in
      claude|codex) ;;
      *) return 1 ;;
    esac
  done
  for scenario in $(review_eval_list_scenarios); do
    for replica in $(seq 1 "$replicas"); do
      for provider in "$@"; do
        printf '%s\t%s\t%s\n' "$scenario" "$replica" "$provider"
      done
    done
  done
}

review_eval_archive_controller_inputs() {
  local run_dir="$1" target
  target="$run_dir/controller-inputs"
  [[ -d "$run_dir" && ! -e "$target" ]] || return 1
  REVIEW_EVAL_ARCHIVE_TARGET="$target" \
  REVIEW_EVAL_ARCHIVE_CONTROLLER="$REVIEW_EVAL_DIR" \
  REVIEW_EVAL_ARCHIVE_SCENARIOS="$REVIEW_EVAL_SCENARIOS_DIR" \
  REVIEW_EVAL_ARCHIVE_REPO="$REVIEW_EVAL_REPO_ROOT" \
    python3 - <<'PY'
import json
import os
import shutil
import stat
import subprocess
from pathlib import Path

target = Path(os.environ["REVIEW_EVAL_ARCHIVE_TARGET"])
controller_source = Path(os.environ["REVIEW_EVAL_ARCHIVE_CONTROLLER"]).resolve()
scenario_source = Path(os.environ["REVIEW_EVAL_ARCHIVE_SCENARIOS"]).resolve()
repository = Path(os.environ["REVIEW_EVAL_ARCHIVE_REPO"]).resolve()
temporary = target.with_name(f".{target.name}.tmp.{os.getpid()}")
controller_files = ("README.md", "agent-observer.sh", "lib.sh", "run.sh")
target_location = target.parent.resolve() / target.name
if controller_source in target_location.parents or scenario_source in target_location.parents:
    raise SystemExit("controller archive cannot be written inside its source inputs")


def copy_regular(source, destination):
    if not hasattr(os, "O_NOFOLLOW") or not hasattr(os, "O_CLOEXEC"):
        raise OSError("platform lacks safe controller copy primitives")
    before = source.lstat()
    if not stat.S_ISREG(before.st_mode):
        raise OSError(f"controller input is not a regular file: {source.name}")
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    source_descriptor = None
    destination_descriptor = None
    failed = False
    try:
        source_descriptor = os.open(
            source,
            os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
        )
        opened = os.fstat(source_descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)
        ):
            raise OSError("controller input changed while opening")
        destination_descriptor = os.open(
            destination,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | os.O_CLOEXEC
            | os.O_NOFOLLOW,
            0o600,
        )
        total = 0
        while True:
            chunk = os.read(source_descriptor, 1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            view = memoryview(chunk)
            while view:
                written = os.write(destination_descriptor, view)
                if written <= 0:
                    raise OSError("controller input copy stopped early")
                view = view[written:]
        os.fchmod(destination_descriptor, 0o600)
        os.fsync(destination_descriptor)
        after = os.fstat(source_descriptor)
        if (
            total != opened.st_size
            or (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
            != (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns)
        ):
            raise OSError("controller input changed while copying")
    except BaseException:
        failed = True
        raise
    finally:
        if destination_descriptor is not None:
            os.close(destination_descriptor)
        if source_descriptor is not None:
            os.close(source_descriptor)
        if failed:
            destination.unlink(missing_ok=True)


def copy_tree(source, destination):
    if not source.is_dir() or source.is_symlink():
        raise OSError("controller catalog is not a directory")
    destination.mkdir(mode=0o700)
    for path in sorted(source.rglob("*")):
        relative = path.relative_to(source)
        output = destination / relative
        metadata = path.lstat()
        if stat.S_ISDIR(metadata.st_mode):
            output.mkdir(mode=0o700)
        elif stat.S_ISREG(metadata.st_mode):
            copy_regular(path, output)
        else:
            raise OSError(f"unsafe controller catalog input: {relative}")


def git_output(arguments):
    try:
        completed = subprocess.run(
            ["git", "-C", str(repository), *arguments],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return completed.stdout.strip()


try:
    temporary.mkdir(mode=0o700)
    archived_controller = temporary / "controller"
    archived_controller.mkdir(mode=0o700)
    for name in controller_files:
        copy_regular(controller_source / name, archived_controller / name)
    copy_tree(scenario_source, temporary / "scenarios")
    head = git_output(["rev-parse", "HEAD"])
    dirty = git_output(
        ["status", "--porcelain=v1", "--untracked-files=all", "--", "research/review-loop"]
    )
    source_payload = {
        "schema_version": 1,
        "repository_head": head,
        "working_tree_dirty": dirty is None or bool(dirty),
        "source_paths": [
            "research/review-loop/README.md",
            "research/review-loop/agent-observer.sh",
            "research/review-loop/lib.sh",
            "research/review-loop/run.sh",
            "research/review-loop/scenarios/",
        ],
    }
    source_path = temporary / "source.json"
    source_path.write_text(
        json.dumps(source_payload, sort_keys=True, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    source_path.chmod(0o600)
    os.replace(temporary, target)
except BaseException:
    if temporary.exists():
        shutil.rmtree(temporary)
    raise
print(target)
PY
}

review_eval_write_run_metadata() {
  local run_dir="$1" stage="$2" dex_sha="$3" replicas="$4" jobs="$5"
  local trial_timeout="$6" claude_model="$7" claude_effort="$8"
  local codex_model="$9" codex_effort="${10}" runners="${11}"
  [[ -d "$run_dir" && "$dex_sha" =~ ^[a-f0-9]{40}$ ]] || return 1
  case "$stage" in
    baseline|final) ;;
    *) return 1 ;;
  esac
  REVIEW_EVAL_METADATA_PATH="$run_dir/run.json" \
  REVIEW_EVAL_METADATA_STAGE="$stage" \
  REVIEW_EVAL_METADATA_DEX_SHA="$dex_sha" \
  REVIEW_EVAL_METADATA_REPLICAS="$replicas" \
  REVIEW_EVAL_METADATA_JOBS="$jobs" \
  REVIEW_EVAL_METADATA_TIMEOUT="$trial_timeout" \
  REVIEW_EVAL_METADATA_CLAUDE_MODEL="$claude_model" \
  REVIEW_EVAL_METADATA_CLAUDE_EFFORT="$claude_effort" \
  REVIEW_EVAL_METADATA_CODEX_MODEL="$codex_model" \
  REVIEW_EVAL_METADATA_CODEX_EFFORT="$codex_effort" \
  REVIEW_EVAL_METADATA_RUNNERS="$runners" \
  REVIEW_EVAL_METADATA_REPO_ROOT="${REVIEW_EVAL_METADATA_SOURCE_REPO:-$REVIEW_EVAL_REPO_ROOT}" \
  REVIEW_EVAL_METADATA_SCENARIOS="${REVIEW_EVAL_METADATA_SCENARIOS:-$REVIEW_EVAL_SCENARIOS_DIR}" \
  REVIEW_EVAL_METADATA_CONTROLLER="${REVIEW_EVAL_METADATA_CONTROLLER:-$REVIEW_EVAL_DIR}" \
  REVIEW_EVAL_METADATA_CONTROLLER_INPUTS="${REVIEW_EVAL_METADATA_CONTROLLER_INPUTS:-$run_dir/controller-inputs}" \
    python3 - <<'PY'
import datetime
import hashlib
import json
import os
import subprocess
from pathlib import Path


def version(command):
    try:
        completed = subprocess.run(
            [command, "--version"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=10,
            env={"PATH": os.environ.get("PATH", "/usr/bin:/bin")},
        )
    except (OSError, subprocess.SubprocessError):
        return "unavailable"
    first_line = completed.stdout.splitlines()[0] if completed.stdout.splitlines() else ""
    return first_line[:200] if first_line else f"exit-{completed.returncode}"


def file_hash(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def tree_hash(root):
    digest = hashlib.sha256(b"dex-review-evaluation-catalog-v1\0")
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        relative = path.relative_to(root).as_posix().encode("utf-8")
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        digest.update(bytes.fromhex(file_hash(path)))
    return digest.hexdigest()


def committed_hash(repo, commit, relative):
    completed = subprocess.run(
        ["git", "-C", str(repo), "show", f"{commit}:{relative}"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    return hashlib.sha256(completed.stdout).hexdigest()


path = Path(os.environ["REVIEW_EVAL_METADATA_PATH"])
repo = Path(os.environ["REVIEW_EVAL_METADATA_REPO_ROOT"])
scenarios = Path(os.environ["REVIEW_EVAL_METADATA_SCENARIOS"])
controller = Path(os.environ["REVIEW_EVAL_METADATA_CONTROLLER"])
controller_inputs = Path(os.environ["REVIEW_EVAL_METADATA_CONTROLLER_INPUTS"])
expected_inputs = path.parent / "controller-inputs"
if (
    controller_inputs.resolve() != expected_inputs.resolve()
    or controller.resolve() != (controller_inputs / "controller").resolve()
    or scenarios.resolve() != (controller_inputs / "scenarios").resolve()
):
    raise SystemExit("controller metadata does not use the archived inputs")
source = json.loads((controller_inputs / "source.json").read_text(encoding="utf-8"))
if (
    not isinstance(source, dict)
    or source.get("schema_version") != 1
    or not isinstance(source.get("working_tree_dirty"), bool)
    or not isinstance(source.get("source_paths"), list)
):
    raise SystemExit("invalid controller source metadata")
runners = os.environ["REVIEW_EVAL_METADATA_RUNNERS"].split()
if not runners or any(runner not in {"claude", "codex"} for runner in runners):
    raise SystemExit("invalid runner metadata")
payload = {
    "schema_version": 1,
    "created_at": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat(),
    "stage": os.environ["REVIEW_EVAL_METADATA_STAGE"],
    "dex_sha": os.environ["REVIEW_EVAL_METADATA_DEX_SHA"],
    "replicas": int(os.environ["REVIEW_EVAL_METADATA_REPLICAS"]),
    "jobs": int(os.environ["REVIEW_EVAL_METADATA_JOBS"]),
    "trial_timeout_seconds": int(os.environ["REVIEW_EVAL_METADATA_TIMEOUT"]),
    "runners": runners,
    "models": {
        "claude": os.environ["REVIEW_EVAL_METADATA_CLAUDE_MODEL"],
        "codex": os.environ["REVIEW_EVAL_METADATA_CODEX_MODEL"],
    },
    "effort": {
        "claude": os.environ["REVIEW_EVAL_METADATA_CLAUDE_EFFORT"],
        "codex": os.environ["REVIEW_EVAL_METADATA_CODEX_EFFORT"],
    },
    "controller_inputs": {
        "archive": "controller-inputs",
        "source_commit": source.get("repository_head"),
        "source_dirty": source["working_tree_dirty"],
        "source_paths": source["source_paths"],
    },
    "artifact_hashes": {
        "matrix_sha256": file_hash(path.parent / "matrix.tsv"),
        "catalog_sha256": tree_hash(scenarios),
        "controller_inputs_sha256": tree_hash(controller_inputs),
        "controller_lib_sha256": file_hash(controller / "lib.sh"),
        "controller_observer_sha256": file_hash(controller / "agent-observer.sh"),
        "controller_readme_sha256": file_hash(controller / "README.md"),
        "controller_run_sha256": file_hash(controller / "run.sh"),
        "launcher_sha256": committed_hash(
            repo,
            os.environ["REVIEW_EVAL_METADATA_DEX_SHA"],
            "research/review-loop/launch.zsh",
        ),
        "observer_sha256": committed_hash(
            repo,
            os.environ["REVIEW_EVAL_METADATA_DEX_SHA"],
            "research/review-loop/agent-observer.sh",
        ),
    },
    "tool_versions": {
        tool: version(tool)
        for tool in dict.fromkeys(["git", "zsh", "node", *runners])
    },
}
temporary = path.with_name(path.name + f".tmp.{os.getpid()}")
with temporary.open("w", encoding="utf-8") as handle:
    json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
os.replace(temporary, path)
PY
}

__review_eval_trial_manifest_start() {
  local manifest="$1" stage="$2" scenario="$3" replica="$4" runner="$5"
  local model="$6" effort="$7" dex_sha="$8" started_at="$9"
  local expected_tier="${10}" expected_floor="${11}" control="${12}"
  REVIEW_EVAL_MANIFEST_PATH="$manifest" \
  REVIEW_EVAL_MANIFEST_STAGE="$stage" \
  REVIEW_EVAL_MANIFEST_SCENARIO="$scenario" \
  REVIEW_EVAL_MANIFEST_REPLICA="$replica" \
  REVIEW_EVAL_MANIFEST_RUNNER="$runner" \
  REVIEW_EVAL_MANIFEST_MODEL="$model" \
  REVIEW_EVAL_MANIFEST_EFFORT="$effort" \
  REVIEW_EVAL_MANIFEST_DEX_SHA="$dex_sha" \
  REVIEW_EVAL_MANIFEST_STARTED_AT="$started_at" \
  REVIEW_EVAL_MANIFEST_EXPECTED_TIER="$expected_tier" \
  REVIEW_EVAL_MANIFEST_EXPECTED_FLOOR="$expected_floor" \
  REVIEW_EVAL_MANIFEST_CONTROL="$control" \
    python3 - <<'PY'
import json
import os
from pathlib import Path

path = Path(os.environ["REVIEW_EVAL_MANIFEST_PATH"])
payload = {
    "schema_version": 1,
    "stage": os.environ["REVIEW_EVAL_MANIFEST_STAGE"],
    "scenario": os.environ["REVIEW_EVAL_MANIFEST_SCENARIO"],
    "replica": int(os.environ["REVIEW_EVAL_MANIFEST_REPLICA"]),
    "runner": os.environ["REVIEW_EVAL_MANIFEST_RUNNER"],
    "model": os.environ["REVIEW_EVAL_MANIFEST_MODEL"],
    "effort": os.environ["REVIEW_EVAL_MANIFEST_EFFORT"],
    "dex_sha": os.environ["REVIEW_EVAL_MANIFEST_DEX_SHA"],
    "expected_tier": os.environ["REVIEW_EVAL_MANIFEST_EXPECTED_TIER"],
    "expected_floor": os.environ["REVIEW_EVAL_MANIFEST_EXPECTED_FLOOR"],
    "control": os.environ["REVIEW_EVAL_MANIFEST_CONTROL"] == "true",
    "started_at": os.environ["REVIEW_EVAL_MANIFEST_STARTED_AT"],
    "status": "running",
    "product_exit_code": None,
    "visible_before": "not-run",
    "visible_after": "not-run",
    "oracle_before": "not-run",
    "oracle_after": "not-run",
    "wave_count": 0,
    "first_oracle_pass_iteration": None,
    "working_tree_changed": False,
    "control_edited": False,
    "duration_seconds": 0,
    "finished_at": None,
    "harness_reason": None,
}
temporary = path.with_name(path.name + f".tmp.{os.getpid()}")
with temporary.open("w", encoding="utf-8") as handle:
    json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
os.replace(temporary, path)
PY
}

__review_eval_trial_manifest_finish() {
  local manifest="$1" status="$2" product_exit="$3" visible_before="$4"
  local visible_after="$5" oracle_before="$6" oracle_after="$7"
  local wave_count="$8" first_oracle_pass="$9" working_changed="${10}"
  local control_edited="${11}" duration="${12}" finished_at="${13}"
  local harness_reason="${14}"
  REVIEW_EVAL_MANIFEST_PATH="$manifest" \
  REVIEW_EVAL_MANIFEST_STATUS="$status" \
  REVIEW_EVAL_MANIFEST_PRODUCT_EXIT="$product_exit" \
  REVIEW_EVAL_MANIFEST_VISIBLE_BEFORE="$visible_before" \
  REVIEW_EVAL_MANIFEST_VISIBLE_AFTER="$visible_after" \
  REVIEW_EVAL_MANIFEST_ORACLE_BEFORE="$oracle_before" \
  REVIEW_EVAL_MANIFEST_ORACLE_AFTER="$oracle_after" \
  REVIEW_EVAL_MANIFEST_WAVE_COUNT="$wave_count" \
  REVIEW_EVAL_MANIFEST_FIRST_ORACLE_PASS="$first_oracle_pass" \
  REVIEW_EVAL_MANIFEST_WORKING_CHANGED="$working_changed" \
  REVIEW_EVAL_MANIFEST_CONTROL_EDITED="$control_edited" \
  REVIEW_EVAL_MANIFEST_DURATION="$duration" \
  REVIEW_EVAL_MANIFEST_FINISHED_AT="$finished_at" \
  REVIEW_EVAL_MANIFEST_HARNESS_REASON="$harness_reason" \
    python3 - <<'PY'
import json
import os
from pathlib import Path


def optional_int(name):
    value = os.environ[name]
    return int(value) if value else None


path = Path(os.environ["REVIEW_EVAL_MANIFEST_PATH"])
payload = json.loads(path.read_text(encoding="utf-8"))
payload.update(
    {
        "status": os.environ["REVIEW_EVAL_MANIFEST_STATUS"],
        "product_exit_code": optional_int("REVIEW_EVAL_MANIFEST_PRODUCT_EXIT"),
        "visible_before": os.environ["REVIEW_EVAL_MANIFEST_VISIBLE_BEFORE"],
        "visible_after": os.environ["REVIEW_EVAL_MANIFEST_VISIBLE_AFTER"],
        "oracle_before": os.environ["REVIEW_EVAL_MANIFEST_ORACLE_BEFORE"],
        "oracle_after": os.environ["REVIEW_EVAL_MANIFEST_ORACLE_AFTER"],
        "wave_count": int(os.environ["REVIEW_EVAL_MANIFEST_WAVE_COUNT"]),
        "first_oracle_pass_iteration": optional_int(
            "REVIEW_EVAL_MANIFEST_FIRST_ORACLE_PASS"
        ),
        "working_tree_changed": os.environ["REVIEW_EVAL_MANIFEST_WORKING_CHANGED"] == "true",
        "control_edited": os.environ["REVIEW_EVAL_MANIFEST_CONTROL_EDITED"] == "true",
        "duration_seconds": int(os.environ["REVIEW_EVAL_MANIFEST_DURATION"]),
        "finished_at": os.environ["REVIEW_EVAL_MANIFEST_FINISHED_AT"],
        "harness_reason": os.environ["REVIEW_EVAL_MANIFEST_HARNESS_REASON"] or None,
    }
)
temporary = path.with_name(path.name + f".tmp.{os.getpid()}")
with temporary.open("w", encoding="utf-8") as handle:
    json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
os.replace(temporary, path)
PY
}

__review_eval_force_terminal_manifest() {
  local source_repo="$1" dex_sha="$2" stage="$3" scenario="$4" replica="$5"
  local runner="$6" model="$7" effort="$8" trial_timeout="$9" trial_dir="${10}"
  local manifest="$trial_dir/manifest.json" started_epoch="${11}" started_at="${12}"
  local terminal_code="${13}"
  local expected_tier expected_floor control finished_epoch finished_at duration
  : "$source_repo" "$trial_timeout"

  if [[ ! -f "$manifest" ]]; then
    expected_tier=$(review_eval_scenario_field "$scenario" expected_tier) || return 1
    expected_floor=$(review_eval_scenario_field "$scenario" expected_floor) || return 1
    control=$(review_eval_scenario_field "$scenario" control) || return 1
    mkdir -p "$trial_dir"
    chmod 700 "$trial_dir"
    __review_eval_trial_manifest_start "$manifest" "$stage" "$scenario" "$replica" \
      "$runner" "$model" "$effort" "$dex_sha" "$started_at" "$expected_tier" \
      "$expected_floor" "$control" || return 1
  fi

  finished_epoch=$(date +%s)
  finished_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  duration=$((finished_epoch - started_epoch))
  REVIEW_EVAL_MANIFEST_PATH="$manifest" \
  REVIEW_EVAL_MANIFEST_DURATION="$duration" \
  REVIEW_EVAL_MANIFEST_FINISHED_AT="$finished_at" \
  REVIEW_EVAL_MANIFEST_TERMINAL_CODE="$terminal_code" \
    python3 - <<'PY'
import json
import os
from pathlib import Path

path = Path(os.environ["REVIEW_EVAL_MANIFEST_PATH"])
payload = json.loads(path.read_text(encoding="utf-8"))
if not isinstance(payload, dict) or payload.get("schema_version") != 1:
    raise SystemExit(1)
terminal_code = int(os.environ["REVIEW_EVAL_MANIFEST_TERMINAL_CODE"])
if terminal_code not in (124, 129, 130, 143):
    raise SystemExit(1)
payload.update(
    {
        "status": "censored" if terminal_code == 124 else "harness_error",
        "product_exit_code": terminal_code,
        "visible_before": payload.get("visible_before", "not-run"),
        "visible_after": payload.get("visible_after", "not-run"),
        "oracle_before": payload.get("oracle_before", "not-run"),
        "oracle_after": payload.get("oracle_after", "not-run"),
        "wave_count": payload.get("wave_count", 0),
        "first_oracle_pass_iteration": payload.get(
            "first_oracle_pass_iteration"
        ),
        "working_tree_changed": payload.get("working_tree_changed", False),
        "control_edited": payload.get("control_edited", False),
        "duration_seconds": int(os.environ["REVIEW_EVAL_MANIFEST_DURATION"]),
        "finished_at": os.environ["REVIEW_EVAL_MANIFEST_FINISHED_AT"],
        "harness_reason": None if terminal_code == 124 else "trial_interrupted",
    }
)
temporary = path.with_name(path.name + f".tmp.{os.getpid()}")
with temporary.open("w", encoding="utf-8") as handle:
    json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
os.replace(temporary, path)
PY
}

__review_eval_wave_summary() {
  local oracle_journal="$1"
  python3 - "$oracle_journal" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
rows = [
    json.loads(line)
    for line in path.read_text(encoding="utf-8").splitlines()
    if line.strip()
] if path.is_file() else []
first_pass = next(
    (row["iteration"] for row in rows if row.get("oracle_status") == "pass"),
    None,
)
print(f"{len(rows)}\t{first_pass if first_pass is not None else ''}")
PY
}

__review_eval_run_provider() {
  local timeout="$1" workspace="$2" trial_home="$3" runtime_dir="$4"
  local agent_result="$5" runner="$6" model="$7" effort="$8"
  local test_stub="$9" test_stub_mode="${10}" observer_token="${11}"
  local stdout_log="${12}" stderr_log="${13}"
  local supervisor_pid="" supervisor_status=0 supervisor_signal_status=0
  local prior_int prior_term prior_hup

  prior_int=$(trap -p INT)
  prior_term=$(trap -p TERM)
  prior_hup=$(trap -p HUP)
  trap 'supervisor_signal_status=130; [[ -z "$supervisor_pid" ]] || kill -INT "$supervisor_pid" 2>/dev/null || true' INT
  trap 'supervisor_signal_status=143; [[ -z "$supervisor_pid" ]] || kill -TERM "$supervisor_pid" 2>/dev/null || true' TERM
  trap 'supervisor_signal_status=129; [[ -z "$supervisor_pid" ]] || kill -HUP "$supervisor_pid" 2>/dev/null || true' HUP

  (
    builtin cd "$workspace" || exit 2
    exec env -i \
      HOME="$trial_home" \
      PATH="${PATH:-/usr/bin:/bin}" \
      LANG="${LANG:-}" \
      LC_ALL="${LC_ALL:-}" \
      TMPDIR="${TMPDIR:-/tmp}" \
      USER="${USER:-}" \
      LOGNAME="${LOGNAME:-}" \
      SHELL="${SHELL:-/bin/zsh}" \
      TERM="${TERM:-dumb}" \
      python3 - "$timeout" "$workspace" "$trial_home" "$runtime_dir" "$agent_result" \
        "$runner" "$model" "$effort" "$test_stub" "$test_stub_mode" \
        "$observer_token" "$stdout_log" "$stderr_log"
  ) <<'PY' &
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

(
    timeout_text,
    workspace,
    trial_home,
    runtime,
    result_dir,
    runner,
    model,
    effort,
    test_stub,
    test_stub_mode,
    observer_token,
    stdout_path,
    stderr_path,
) = sys.argv[1:]
if not timeout_text.isdigit() or int(timeout_text) < 1:
    raise SystemExit(2)
timeout = int(timeout_text)
child_environment = {
    "HOME": trial_home,
    "CODEX_HOME": str(Path(trial_home) / ".codex"),
    "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
    "LANG": os.environ.get("LANG", ""),
    "LC_ALL": os.environ.get("LC_ALL", ""),
    "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
    "USER": os.environ.get("USER", ""),
    "LOGNAME": os.environ.get("LOGNAME", ""),
    "SHELL": os.environ.get("SHELL", "/bin/zsh"),
    "TERM": os.environ.get("TERM", "dumb"),
    "PYTHONDONTWRITEBYTECODE": "1",
    "REVIEW_EVAL_TEST_STUB": test_stub,
    "REVIEW_EVAL_TEST_STUB_MODE": test_stub_mode,
}
command = [
    "zsh",
    str(Path(runtime) / "research/review-loop/launch.zsh"),
    runtime,
    workspace,
    result_dir,
    runner,
    model,
    effort,
    "",
    observer_token,
]


def signal_group(process, selected_signal):
    try:
        os.killpg(process.pid, selected_signal)
    except ProcessLookupError:
        pass


def terminate_group(process, grace_seconds):
    signal_group(process, signal.SIGTERM)
    deadline = time.monotonic() + grace_seconds
    while time.monotonic() < deadline:
        try:
            os.killpg(process.pid, 0)
        except ProcessLookupError:
            break
        time.sleep(0.05)
    signal_group(process, signal.SIGKILL)
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        signal_group(process, signal.SIGKILL)


with open(stdout_path, "wb") as stdout, open(stderr_path, "wb") as stderr:
    process = subprocess.Popen(
        command,
        cwd=workspace,
        env=child_environment,
        stdout=stdout,
        stderr=stderr,
        start_new_session=True,
    )

    def forward_signal(selected_signal, _frame):
        terminate_group(process, 2)
        raise SystemExit(128 + selected_signal)

    for selected_signal in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(selected_signal, forward_signal)
    try:
        return_code = process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        terminate_group(process, 2)
        raise SystemExit(124)
    terminate_group(process, 0.2)
    raise SystemExit(return_code)
PY
  supervisor_pid=$!
  if [[ $supervisor_signal_status -ne 0 ]]; then
    kill -TERM "$supervisor_pid" 2>/dev/null || true
  fi
  wait "$supervisor_pid" 2>/dev/null || supervisor_status=$?
  if [[ $supervisor_signal_status -ne 0 ]]; then
    wait "$supervisor_pid" 2>/dev/null || true
    supervisor_status=$supervisor_signal_status
  fi
  trap - INT TERM HUP
  # shellcheck disable=SC2294  # trusted trap definitions captured from this shell
  [[ -z "$prior_int" ]] || eval "$prior_int"
  # shellcheck disable=SC2294  # trusted trap definitions captured from this shell
  [[ -z "$prior_term" ]] || eval "$prior_term"
  # shellcheck disable=SC2294  # trusted trap definitions captured from this shell
  [[ -z "$prior_hup" ]] || eval "$prior_hup"
  return "$supervisor_status"
}

__review_eval_remove_execution_root() {
  local execution_root="${1:-}" execution_parent="${2:-}" root_name root_parent
  [[ -n "$execution_root" && -n "$execution_parent" && -d "$execution_root" ]] || return 0
  root_name=$(basename "$execution_root") || return 1
  root_parent=$(dirname "$execution_root") || return 1
  [[ "$root_parent" == "$execution_parent" && "$root_name" == dex-review-trial.* ]] || return 1
  REVIEW_EVAL_REMOVE_ROOT="$execution_root" python3 - <<'PY'
import os
import shutil
import stat
from pathlib import Path

root = Path(os.environ["REVIEW_EVAL_REMOVE_ROOT"])
if any(
    not hasattr(os, name)
    for name in ("O_DIRECTORY", "O_NOFOLLOW", "fwalk")
):
    raise SystemExit("platform lacks safe cleanup primitives")
metadata = root.lstat()
if not stat.S_ISDIR(metadata.st_mode) or not shutil.rmtree.avoids_symlink_attacks:
    raise SystemExit("execution root is not a directory")
for _, _, _, directory_fd in os.fwalk(root, topdown=False, follow_symlinks=False):
    if not stat.S_ISDIR(os.fstat(directory_fd).st_mode):
        raise SystemExit("cleanup path changed type")
    os.fchmod(directory_fd, 0o700)
shutil.rmtree(root)
PY
}

__review_eval_cleanup_observer_token() {
  local execution_parent="${1:-}" observer_token="${2:-}"
  [[ -d "$execution_parent" && "$observer_token" =~ ^[a-f0-9]{32}$ ]] || return 0
  REVIEW_EVAL_CLEANUP_PARENT="$execution_parent" \
  REVIEW_EVAL_CLEANUP_TOKEN="$observer_token" \
    python3 - <<'PY'
import os
import re
import shutil
from pathlib import Path

parent = Path(os.environ["REVIEW_EVAL_CLEANUP_PARENT"]).resolve()
token = os.environ["REVIEW_EVAL_CLEANUP_TOKEN"]
pattern = re.compile(rf"dex-review-observer-{re.escape(token)}\.[A-Za-z0-9]+(?:\.ready)?")
for path in parent.iterdir():
    if pattern.fullmatch(path.name) and path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
PY
}

__review_eval_cleanup_controller_token() {
  local execution_parent="${1:-}" controller_token="${2:-}"
  [[ -d "$execution_parent" && "$controller_token" =~ ^[a-f0-9]{32}$ ]] || return 0
  REVIEW_EVAL_CLEANUP_PARENT="$execution_parent" \
  REVIEW_EVAL_CLEANUP_TOKEN="$controller_token" \
    python3 - <<'PY'
import os
import re
import shutil
import stat
from pathlib import Path

parent = Path(os.environ["REVIEW_EVAL_CLEANUP_PARENT"]).resolve()
token = os.environ["REVIEW_EVAL_CLEANUP_TOKEN"]
if any(
    not hasattr(os, name)
    for name in ("O_DIRECTORY", "O_NOFOLLOW", "fwalk")
):
    raise SystemExit("platform lacks safe cleanup primitives")
patterns = (
    re.compile(rf"dex-review-trial\.{re.escape(token)}\.[A-Za-z0-9]+"),
    re.compile(rf"dex-review-observer-{re.escape(token)}\.[A-Za-z0-9]+(?:\.ready)?"),
)


def remove_owned(path):
    if path.is_symlink() or not path.is_dir():
        path.unlink()
        return
    if not shutil.rmtree.avoids_symlink_attacks:
        raise OSError("platform does not provide symlink-safe tree removal")
    for _, _, _, directory_fd in os.fwalk(
        path, topdown=False, follow_symlinks=False
    ):
        if not stat.S_ISDIR(os.fstat(directory_fd).st_mode):
            raise OSError("cleanup path changed type")
        os.fchmod(directory_fd, 0o700)
    shutil.rmtree(path)


for candidate in parent.iterdir():
    if any(pattern.fullmatch(candidate.name) for pattern in patterns):
        remove_owned(candidate)
PY
}

__review_eval_salvage_test_pid() {
  local execution_parent="${1:-}" controller_token="${2:-}" trial_dir="${3:-}"
  [[ "${REVIEW_EVAL_TEST_STUB:-0}" == "1" && -d "$execution_parent" && \
     "$controller_token" =~ ^[a-f0-9]{32}$ && -d "$trial_dir" ]] || return 0
  REVIEW_EVAL_SALVAGE_PARENT="$execution_parent" \
  REVIEW_EVAL_SALVAGE_TOKEN="$controller_token" \
  REVIEW_EVAL_SALVAGE_TARGET="$trial_dir/stub-grandchild.pid" \
    python3 - <<'PY'
import os
import re
from pathlib import Path

parent = Path(os.environ["REVIEW_EVAL_SALVAGE_PARENT"]).resolve()
token = os.environ["REVIEW_EVAL_SALVAGE_TOKEN"]
target = Path(os.environ["REVIEW_EVAL_SALVAGE_TARGET"])
pattern = re.compile(rf"dex-review-trial\.{re.escape(token)}\.[A-Za-z0-9]+")
sources = [
    candidate / "result" / "stub-grandchild.pid"
    for candidate in parent.iterdir()
    if pattern.fullmatch(candidate.name) and candidate.is_dir() and not candidate.is_symlink()
]
for source in sources:
    if not source.is_file() or source.is_symlink():
        continue
    value = source.read_text(encoding="ascii").strip()
    if not value.isdigit():
        continue
    temporary = target.with_name(target.name + f".tmp.{os.getpid()}")
    temporary.write_text(value + "\n", encoding="ascii")
    os.chmod(temporary, 0o600)
    os.replace(temporary, target)
    break
PY
}

__review_eval_run_trial_worker() {
  umask 077
  local source_repo="$1" dex_sha="$2" stage="$3" scenario="$4" replica="$5"
  local runner="$6" model="$7" effort="$8" trial_timeout="$9" trial_dir="${10}"
  local manifest="$trial_dir/manifest.json" started_epoch started_at finished_epoch finished_at
  local execution_parent execution_root="" agent_result="" workspace="" runtime_dir="" trial_home=""
  local candidate_head="" expected_oracle expected_tier expected_floor control
  local external_codex_home external_claude_home prepared_sha
  local controller_token="${REVIEW_EVAL_CONTROLLER_TOKEN:-}" observer_token=""
  local runtime_hash_before="" runtime_hash_after="" provider_timeout
  local product_exit="" status="harness_error" harness_reason=""
  local visible_before="not-run" visible_after="not-run"
  local oracle_before="not-run" oracle_after="not-run"
  local wave_count=0 first_oracle_pass="" working_changed=false control_edited=false
  local launch_status=0 wave_record duration

  [[ ! -e "$trial_dir" && "$dex_sha" =~ ^[a-f0-9]{40}$ ]] || return 1
  case "$stage:$runner" in
    baseline:claude|baseline:codex|final:claude|final:codex) ;;
    *) return 1 ;;
  esac
  review_eval_positive_integer "$replica" >/dev/null || return 1
  review_eval_positive_integer "$trial_timeout" >/dev/null || return 1
  expected_tier=$(review_eval_scenario_field "$scenario" expected_tier) || return 1
  expected_floor=$(review_eval_scenario_field "$scenario" expected_floor) || return 1
  control=$(review_eval_scenario_field "$scenario" control) || return 1
  execution_parent=$(cd "${TMPDIR:-/tmp}" && pwd -P) || return 1
  if [[ ! "$controller_token" =~ ^[a-f0-9]{32}$ ]]; then
    controller_token=$(python3 -c 'import secrets; print(secrets.token_hex(16))') || return 1
  fi
  observer_token="$controller_token"
  REVIEW_EVAL_WORKER_EXECUTION_PARENT="$execution_parent"
  REVIEW_EVAL_WORKER_EXECUTION_ROOT=""
  REVIEW_EVAL_WORKER_OBSERVER_TOKEN="$observer_token"
  trap '__review_eval_cleanup_observer_token "$REVIEW_EVAL_WORKER_EXECUTION_PARENT" "$REVIEW_EVAL_WORKER_OBSERVER_TOKEN"; __review_eval_remove_execution_root "$REVIEW_EVAL_WORKER_EXECUTION_ROOT" "$REVIEW_EVAL_WORKER_EXECUTION_PARENT"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  started_epoch=$(date +%s)
  started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  mkdir -p "$trial_dir"
  __review_eval_trial_manifest_start "$manifest" "$stage" "$scenario" "$replica" \
    "$runner" "$model" "$effort" "$dex_sha" "$started_at" "$expected_tier" \
    "$expected_floor" "$control" || return 1

  execution_root=$(mktemp -d "$execution_parent/dex-review-trial.${controller_token}.XXXXXX") || \
    harness_reason="execution_root_failed"
  REVIEW_EVAL_WORKER_EXECUTION_ROOT="$execution_root"
  if [[ -n "$execution_root" ]]; then
    agent_result="$execution_root/result"
    runtime_dir="$execution_root/runtime"
    trial_home="$execution_root/home"
    mkdir -p "$agent_result"
  fi

  if [[ -z "$harness_reason" ]] && \
     ! workspace=$(review_eval_prepare_workspace "$scenario" "$execution_root/fixture"); then
    harness_reason="workspace_prepare_failed"
  elif [[ -z "$harness_reason" ]] && \
       ! review_eval_run_visible_check "$scenario" "$workspace" "$trial_dir/visible-before.log"; then
    visible_before="fail"
    harness_reason="fixture_visible_check_failed"
  elif [[ -z "$harness_reason" ]]; then
    visible_before="pass"
  fi

  if [[ -z "$harness_reason" ]]; then
    oracle_before=$(review_eval_oracle_status "$scenario" "$workspace" "$trial_dir/oracle-before.log")
    expected_oracle=$(review_eval_scenario_field "$scenario" expected_candidate_oracle) || expected_oracle=""
    if [[ "$oracle_before" == "invalid" || "$oracle_before" != "$expected_oracle" ]]; then
      harness_reason="fixture_oracle_mismatch"
    fi
  fi

  if [[ -z "$harness_reason" ]]; then
    candidate_head=$(git -C "$workspace" rev-parse HEAD 2>/dev/null || true)
    if [[ -z "$candidate_head" ]]; then
      harness_reason="candidate_head_missing"
    elif ! prepared_sha=$(review_eval_prepare_runtime "$source_repo" "$dex_sha" "$runtime_dir"); then
      harness_reason="runtime_prepare_failed"
    elif [[ "$prepared_sha" != "$dex_sha" ]]; then
      harness_reason="runtime_sha_mismatch"
    else
      external_codex_home="${CODEX_HOME:-${HOME}/.codex}"
      external_claude_home="$HOME"
      if [[ "${REVIEW_EVAL_TEST_STUB:-0}" == "1" ]]; then
        external_claude_home="$execution_root/no-claude-auth"
      fi
    fi
    if [[ -z "$harness_reason" ]] && \
       ! review_eval_prepare_trial_home "$runtime_dir" "$trial_home" "$runner" \
         "$external_codex_home" "$external_claude_home"; then
      harness_reason="trial_home_prepare_failed"
    elif [[ -z "$harness_reason" ]] && ! review_eval_runtime_make_read_only "$runtime_dir"; then
      harness_reason="runtime_permissions_failed"
    elif [[ -z "$harness_reason" ]] && \
         ! runtime_hash_before=$(review_eval_runtime_tree_hash "$runtime_dir"); then
      harness_reason="runtime_hash_failed"
    fi
  fi

  if [[ -z "$harness_reason" ]]; then
    provider_timeout=$(review_eval_bounded_timeout "$trial_timeout" 3) || provider_timeout=1
    if __review_eval_run_provider "$provider_timeout" "$workspace" "$trial_home" \
        "$runtime_dir" "$agent_result" "$runner" "$model" "$effort" \
        "${REVIEW_EVAL_TEST_STUB:-0}" "${REVIEW_EVAL_TEST_STUB_MODE:-normal}" \
        "$observer_token" "$agent_result/stdout.log" "$agent_result/stderr.log"; then
      product_exit=0
    else
      launch_status=$?
      product_exit="$launch_status"
    fi

    if ! runtime_hash_after=$(review_eval_runtime_tree_hash "$runtime_dir") || \
       [[ "$runtime_hash_after" != "$runtime_hash_before" ]]; then
      harness_reason="runtime_mutated"
    fi
    if ! review_eval_seal_provider_output "$agent_result" "$trial_dir"; then
      harness_reason="provider_output_invalid"
    fi
    if ! review_eval_collect_product_events "$agent_result" "$trial_dir"; then
      harness_reason="product_events_invalid"
    fi
    local observer_required=true
    case "$product_exit" in
      124|129|130|143) observer_required=false ;;
    esac
    if ! review_eval_collect_observer_artifacts "$agent_result" "$trial_dir" \
        "$execution_parent" "$observer_token" "$observer_required"; then
      harness_reason="observer_handoff_invalid"
    fi
    case "$product_exit" in
      0)
        review_eval_trial_product_record_valid "$trial_dir" completed "$product_exit" || \
          harness_reason="invalid_product_terminal"
        ;;
      124|129|130|143) ;;
      *)
        review_eval_trial_product_record_valid "$trial_dir" paused "$product_exit" || \
          harness_reason="invalid_product_terminal"
        ;;
    esac
    if [[ "${REVIEW_EVAL_TEST_STUB:-0}" == "1" && \
          -f "$agent_result/stub-grandchild.pid" && \
          ! -L "$agent_result/stub-grandchild.pid" ]]; then
      cp "$agent_result/stub-grandchild.pid" "$trial_dir/stub-grandchild.pid"
    fi

    case "$product_exit" in
      129|130|143)
        harness_reason="trial_interrupted"
        ;;
      *)
        if [[ -f "$trial_dir/waves.jsonl" ]]; then
          if ! review_eval_score_snapshots "$scenario" "$trial_dir"; then
            harness_reason="wave_scoring_failed"
          fi
        else
          : > "$trial_dir/oracle-waves.jsonl"
        fi
        wave_record=$(__review_eval_wave_summary "$trial_dir/oracle-waves.jsonl") || {
          wave_record="0\t"
          harness_reason="wave_summary_failed"
        }
        IFS=$'\t' read -r wave_count first_oracle_pass <<EOF
$wave_record
EOF

        if review_eval_run_visible_check "$scenario" "$workspace" "$trial_dir/visible-after.log"; then
          visible_after="pass"
        else
          visible_after="fail"
        fi
        oracle_after=$(review_eval_oracle_status "$scenario" "$workspace" "$trial_dir/oracle-after.log")
        [[ "$oracle_after" != "invalid" ]] || harness_reason="final_oracle_invalid"

        if ! git -C "$workspace" diff --quiet "$candidate_head" -- 2>/dev/null || \
           [[ -n "$(git -C "$workspace" ls-files --others --exclude-standard 2>/dev/null)" ]]; then
          working_changed=true
        fi
        if [[ "$control" == "true" && "$working_changed" == "true" ]]; then
          control_edited=true
        fi
        [[ ! -e "$trial_dir/capture-error" ]] || harness_reason="wave_capture_failed"
        # shellcheck source=research/review-loop/agent-observer.sh
        source "$REVIEW_EVAL_DIR/agent-observer.sh"
        if ! review_eval_agent_snapshot_checkout "$workspace" "$trial_dir/final-workspace"; then
          harness_reason="final_snapshot_failed"
        fi
        ;;
    esac
  fi

  if [[ -z "$harness_reason" ]]; then
    case "$product_exit" in
      0) status="completed" ;;
      124) status="censored" ;;
      *) status="paused" ;;
    esac
  elif [[ "$harness_reason" == "invalid_product_terminal" ]]; then
    status="product_error"
  fi

  finished_epoch=$(date +%s)
  finished_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  duration=$((finished_epoch - started_epoch))
  if [[ -n "$execution_root" && -d "$execution_root" ]]; then
    __review_eval_remove_execution_root "$execution_root" "$execution_parent"
    execution_root=""
    REVIEW_EVAL_WORKER_EXECUTION_ROOT=""
  fi
  __review_eval_cleanup_observer_token "$execution_parent" "$observer_token"
  observer_token=""
  REVIEW_EVAL_WORKER_OBSERVER_TOKEN=""
  __review_eval_trial_manifest_finish "$manifest" "$status" "$product_exit" \
    "$visible_before" "$visible_after" "$oracle_before" "$oracle_after" \
    "$wave_count" "$first_oracle_pass" "$working_changed" "$control_edited" \
    "$duration" "$finished_at" "$harness_reason" || return 1
  trap - EXIT INT TERM HUP
  case "$status" in
    harness_error|product_error) return 1 ;;
    censored) return 124 ;;
    *) return 0 ;;
  esac
}

review_eval_run_trial() {
  local trial_timeout="${9:-}" trial_dir="${10:-}"
  local controller_token execution_parent deadline_ns started_epoch started_at
  local supervisor_pid="" worker_status=0 worker_signal_status=0
  local prior_int prior_term prior_hup

  [[ $# -eq 10 && -n "$trial_dir" ]] || return 1
  review_eval_positive_integer "$trial_timeout" >/dev/null || return 1
  execution_parent=$(cd "${TMPDIR:-/tmp}" && pwd -P) || return 1
  started_epoch=$(date +%s)
  started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  controller_token=$(python3 -c 'import secrets; print(secrets.token_hex(16))') || return 1
  deadline_ns=$(python3 - "$trial_timeout" <<'PY'
import sys
import time

print(time.monotonic_ns() + int(sys.argv[1]) * 1_000_000_000)
PY
  ) || return 1

  prior_int=$(trap -p INT)
  prior_term=$(trap -p TERM)
  prior_hup=$(trap -p HUP)
  REVIEW_EVAL_CONTROLLER_TOKEN="$controller_token" \
  REVIEW_EVAL_TRIAL_DEADLINE_NS="$deadline_ns" \
    python3 - "$deadline_ns" "$REVIEW_EVAL_DIR/lib.sh" "$@" <<'PY' &
import os
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

deadline = int(sys.argv[1])
library = sys.argv[2]
worker_arguments = sys.argv[3:]
environment = os.environ.copy()
command = [
    "bash",
    "--noprofile",
    "--norc",
    "-c",
    'source "$1"; shift; __review_eval_run_trial_worker "$@"',
    "review-eval-worker",
    library,
    *worker_arguments,
]
ps_command = next(
    (str(path) for path in (Path("/bin/ps"), Path("/usr/bin/ps")) if path.is_file()),
    "ps",
)


def process_table():
    try:
        completed = subprocess.run(
            [ps_command, "-axo", "pid=,ppid=,lstart="],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=1,
        )
    except (OSError, subprocess.SubprocessError):
        return {}
    table = {}
    for line in completed.stdout.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) != 3 or not fields[0].isdigit() or not fields[1].isdigit():
            continue
        table[int(fields[0])] = (int(fields[1]), fields[2])
    return table


def remember_descendants(root_pid, table, known):
    owned = {root_pid}
    owned.update(
        pid
        for pid, identity in known.items()
        if pid in table and table[pid][1] == identity
    )
    changed = True
    while changed:
        changed = False
        for pid, (parent_pid, _identity) in table.items():
            if pid not in owned and parent_pid in owned:
                owned.add(pid)
                changed = True
    for pid in owned:
        if pid in table:
            known[pid] = table[pid][1]


def live_known(table, known):
    return {
        pid
        for pid, identity in known.items()
        if pid > 1 and pid in table and table[pid][1] == identity
    }


def signal_pids(pids, selected_signal):
    for pid in sorted(pids, reverse=True):
        try:
            os.kill(pid, selected_signal)
        except (ProcessLookupError, PermissionError):
            pass


def signal_session(process, selected_signal):
    try:
        os.killpg(process.pid, selected_signal)
    except (ProcessLookupError, PermissionError):
        pass


def update_known(process, table):
    with tracked_lock:
        remember_descendants(process.pid, table, tracked_processes)
        return dict(tracked_processes)


def monitor_descendants(process):
    while not monitor_stop.is_set():
        update_known(process, process_table())
        monitor_stop.wait(0.25)


def terminate_tree(process, grace_seconds=0.75):
    monitor_stop.set()
    monitor_thread.join(timeout=1.25)
    table = process_table()
    known = update_known(process, table)
    signal_pids(live_known(table, known), signal.SIGTERM)
    signal_session(process, signal.SIGTERM)
    stop_at = time.monotonic() + grace_seconds
    while time.monotonic() < stop_at:
        table = process_table()
        known = update_known(process, table)
        alive = live_known(table, known)
        if not alive:
            break
        signal_pids(alive, signal.SIGTERM)
        time.sleep(0.05)
    table = process_table()
    known = update_known(process, table)
    signal_pids(live_known(table, known), signal.SIGKILL)
    signal_session(process, signal.SIGKILL)
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        signal_session(process, signal.SIGKILL)


process = subprocess.Popen(
    command,
    env=environment,
    start_new_session=True,
)
tracked_processes = {}
tracked_lock = threading.Lock()
monitor_stop = threading.Event()
monitor_thread = threading.Thread(
    target=monitor_descendants,
    args=(process,),
    daemon=True,
    name="review-eval-descendants",
)
monitor_thread.start()


def forward_signal(selected_signal, _frame):
    terminate_tree(process)
    raise SystemExit(128 + selected_signal)


for watched_signal in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(watched_signal, forward_signal)
try:
    remaining = (deadline - time.monotonic_ns()) / 1_000_000_000
    if remaining <= 0:
        raise subprocess.TimeoutExpired(command, 0)
    return_code = process.wait(timeout=remaining)
except subprocess.TimeoutExpired:
    terminate_tree(process)
    raise SystemExit(124)
terminate_tree(process, 0.2)
raise SystemExit(return_code)
PY
  supervisor_pid=$!
  trap 'worker_signal_status=130; kill -INT "$supervisor_pid" 2>/dev/null || true' INT
  trap 'worker_signal_status=143; kill -TERM "$supervisor_pid" 2>/dev/null || true' TERM
  trap 'worker_signal_status=129; kill -HUP "$supervisor_pid" 2>/dev/null || true' HUP
  wait "$supervisor_pid" 2>/dev/null || worker_status=$?
  if [[ $worker_signal_status -ne 0 ]]; then
    wait "$supervisor_pid" 2>/dev/null || true
    worker_status=$worker_signal_status
  fi
  trap - INT TERM HUP
  # shellcheck disable=SC2294  # trusted trap definitions captured from this shell
  [[ -z "$prior_int" ]] || eval "$prior_int"
  # shellcheck disable=SC2294  # trusted trap definitions captured from this shell
  [[ -z "$prior_term" ]] || eval "$prior_term"
  # shellcheck disable=SC2294  # trusted trap definitions captured from this shell
  [[ -z "$prior_hup" ]] || eval "$prior_hup"

  __review_eval_salvage_test_pid "$execution_parent" "$controller_token" "$trial_dir"
  __review_eval_cleanup_controller_token "$execution_parent" "$controller_token"
  case "$worker_status" in
    124|129|130|143)
      __review_eval_force_terminal_manifest "$@" "$started_epoch" "$started_at" \
        "$worker_status" || return 1
      ;;
  esac
  return "$worker_status"
}

review_eval_summarize_run() {
  local run_dir="$1"
  [[ -f "$run_dir/matrix.tsv" && -f "$run_dir/run.json" ]] || return 1
  python3 - "$run_dir" <<'PY'
import csv
import datetime
import hashlib
import json
import os
import sys
from collections import Counter
from pathlib import Path

root = Path(sys.argv[1])
run_metadata = json.loads((root / "run.json").read_text(encoding="utf-8"))
if run_metadata.get("schema_version") != 1:
    raise SystemExit("unsupported run metadata")
matrix = []
for number, line in enumerate((root / "matrix.tsv").read_text(encoding="utf-8").splitlines(), 1):
    parts = line.split("\t")
    if len(parts) != 3:
        raise SystemExit(f"invalid matrix row {number}")
    scenario, replica_text, runner = parts
    matrix.append((scenario, int(replica_text), runner))
if len(matrix) != len(set(matrix)):
    raise SystemExit("duplicate matrix rows")
matrix_hash = hashlib.sha256((root / "matrix.tsv").read_bytes()).hexdigest()
artifact_hashes = run_metadata.get("artifact_hashes", {})
if artifact_hashes.get("matrix_sha256") != matrix_hash:
    raise SystemExit("matrix hash does not match run metadata")


def file_hash(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def tree_hash(directory):
    digest = hashlib.sha256(b"dex-review-evaluation-catalog-v1\0")
    for path in sorted(item for item in directory.rglob("*") if item.is_file()):
        relative = path.relative_to(directory).as_posix().encode("utf-8")
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        digest.update(bytes.fromhex(file_hash(path)))
    return digest.hexdigest()


controller_inputs = root / "controller-inputs"
controller = controller_inputs / "controller"
scenarios = controller_inputs / "scenarios"
if (
    run_metadata.get("controller_inputs", {}).get("archive") != "controller-inputs"
    or artifact_hashes.get("controller_inputs_sha256") != tree_hash(controller_inputs)
    or artifact_hashes.get("controller_lib_sha256") != file_hash(controller / "lib.sh")
    or artifact_hashes.get("controller_run_sha256") != file_hash(controller / "run.sh")
    or artifact_hashes.get("controller_observer_sha256") != file_hash(controller / "agent-observer.sh")
    or artifact_hashes.get("controller_readme_sha256") != file_hash(controller / "README.md")
    or artifact_hashes.get("catalog_sha256") != tree_hash(scenarios)
):
    raise SystemExit("evaluation controller or catalog changed during the run")

expected_manifests = {
    root / "trials" / scenario / f"replica-{replica}" / runner / "manifest.json"
    for scenario, replica, runner in matrix
}
actual_manifests = set((root / "trials").glob("*/replica-*/*/manifest.json"))
if actual_manifests != expected_manifests:
    expected_display = sorted(str(path.relative_to(root)) for path in expected_manifests)
    actual_display = sorted(str(path.relative_to(root)) for path in actual_manifests)
    raise SystemExit(
        f"trial manifests do not form an exact matrix bijection: "
        f"expected {expected_display}, got {actual_display}"
    )


def read_json_lines(path):
    if not path.is_file():
        return []
    return [
        json.loads(line)
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]


rows = []
statuses = Counter({
    key: 0
    for key in ("completed", "paused", "product_error", "censored", "harness_error")
})
wave_statuses = Counter({key: 0 for key in ("pass", "fail", "invalid")})
for scenario, replica, runner in matrix:
    trial = root / "trials" / scenario / f"replica-{replica}" / runner
    manifest_path = trial / "manifest.json"
    if not manifest_path.is_file():
        raise SystemExit(f"missing trial manifest: {scenario}/{replica}/{runner}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if (
        manifest.get("schema_version") != 1
        or manifest.get("scenario") != scenario
        or manifest.get("replica") != replica
        or manifest.get("runner") != runner
        or manifest.get("stage") != run_metadata.get("stage")
        or manifest.get("dex_sha") != run_metadata.get("dex_sha")
        or manifest.get("model") != run_metadata.get("models", {}).get(runner)
        or manifest.get("effort") != run_metadata.get("effort", {}).get(runner)
        or manifest.get("expected_tier") not in {"small", "normal", "complex"}
        or manifest.get("expected_floor") not in {"small", "normal", "complex"}
        or not isinstance(manifest.get("control"), bool)
    ):
        raise SystemExit(f"trial manifest does not match matrix: {scenario}/{replica}/{runner}")
    status = manifest.get("status")
    if status not in statuses:
        raise SystemExit(f"invalid trial status: {status!r}")
    statuses[status] += 1

    proposed_tier = ""
    assessments = read_json_lines(trial / "assessment.jsonl")
    if assessments:
        proposed_tier = assessments[-1].get("tier", "")
    resolved_tier = ""
    product_finished = []
    for event_file in sorted((trial / "dex-runs").glob("run_*/events.jsonl")):
        for event in read_json_lines(event_file):
            if event.get("type") in {"review.tier.selected", "review.tier.escalated"}:
                resolved_tier = event.get("data", {}).get("tier", resolved_tier)
            if event.get("type") == "review.pass.finished":
                product_finished.append(event.get("data", {}))

    wave_rows = read_json_lines(trial / "oracle-waves.jsonl")
    wave_iterations = [wave.get("iteration") for wave in wave_rows]
    if wave_iterations != list(range(1, len(wave_rows) + 1)):
        raise SystemExit(f"non-consecutive wave iterations: {scenario}/{replica}/{runner}")
    product_keys = [
        (event.get("iteration"), event.get("pass_id"))
        for event in product_finished
    ]
    wave_keys = [(wave.get("iteration"), wave.get("pass_id")) for wave in wave_rows]
    pass_ids = [pass_id for _, pass_id in product_keys]
    if (
        any(not isinstance(pass_id, str) or not pass_id for pass_id in pass_ids)
        or len(set(pass_ids)) != len(pass_ids)
    ):
        raise SystemExit(f"product pass identities are not unique: {scenario}/{replica}/{runner}")
    if status in {"completed", "paused"}:
        capture_matches = product_keys == wave_keys
    else:
        capture_matches = product_keys[:len(wave_keys)] == wave_keys
    if not capture_matches:
        raise SystemExit(f"captured waves do not match product events: {scenario}/{replica}/{runner}")
    first_oracle_pass = next(
        (wave.get("iteration") for wave in wave_rows if wave.get("oracle_status") == "pass"),
        None,
    )
    if (
        manifest.get("wave_count") != len(wave_rows)
        or manifest.get("first_oracle_pass_iteration") != first_oracle_pass
    ):
        raise SystemExit(f"manifest wave summary is inconsistent: {scenario}/{replica}/{runner}")
    for wave in wave_rows:
        oracle_status = wave.get("oracle_status")
        if oracle_status not in wave_statuses:
            raise SystemExit(f"invalid oracle wave status: {oracle_status!r}")
        wave_statuses[oracle_status] += 1
    rows.append(
        {
            "scenario": scenario,
            "replica": replica,
            "runner": runner,
            "status": status,
            "product_exit_code": manifest.get("product_exit_code"),
            "proposed_tier": proposed_tier,
            "resolved_tier": resolved_tier,
            "wave_count": manifest.get("wave_count"),
            "first_oracle_pass_iteration": manifest.get("first_oracle_pass_iteration"),
            "oracle_after": manifest.get("oracle_after"),
            "visible_after": manifest.get("visible_after"),
            "control_edited": manifest.get("control_edited"),
            "harness_reason": manifest.get("harness_reason"),
            "expected_tier": manifest.get("expected_tier"),
            "expected_floor": manifest.get("expected_floor"),
            "control": manifest.get("control"),
            "false_clean_waves": sum(
                wave.get("result_kind") == "clean" and wave.get("oracle_status") == "fail"
                for wave in wave_rows
            ),
        }
    )

eligible = [row for row in rows if row["status"] not in {"censored", "harness_error"}]
summary = {
    "schema_version": 1,
    "created_at": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat(),
    "scheduled": len(matrix),
    "collected": len(rows),
    "statuses": dict(sorted(statuses.items())),
    "final_oracle_pass": sum(row["oracle_after"] == "pass" for row in rows),
    "final_visible_pass": sum(row["visible_after"] == "pass" for row in rows),
    "controls_edited": sum(row["control_edited"] is True for row in rows),
    "eligible_trials": len(eligible),
    "false_clean_waves": sum(row["false_clean_waves"] for row in rows),
    "waves": dict(sorted(wave_statuses.items())),
    "proposed_tiers": dict(sorted(Counter(row["proposed_tier"] or "unknown" for row in rows).items())),
    "resolved_tiers": dict(sorted(Counter(row["resolved_tier"] or "unknown" for row in rows).items())),
    "tier_accuracy": {
        "proposed_matches": sum(
            row["proposed_tier"] == row["expected_tier"] for row in eligible
        ),
        "resolved_matches": sum(
            row["resolved_tier"] == row["expected_tier"] for row in eligible
        ),
    },
    "defects": {
        "eligible": sum(not row["control"] for row in eligible),
        "fixed": sum(
            not row["control"] and row["oracle_after"] == "pass" for row in eligible
        ),
    },
}

summary_path = root / "summary.json"
summary_tmp = summary_path.with_name(summary_path.name + f".tmp.{os.getpid()}")
with summary_tmp.open("w", encoding="utf-8") as handle:
    json.dump(summary, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
os.replace(summary_tmp, summary_path)

table_path = root / "trials.tsv"
table_tmp = table_path.with_name(table_path.name + f".tmp.{os.getpid()}")
fieldnames = [
    "scenario",
    "replica",
    "runner",
    "status",
    "product_exit_code",
    "proposed_tier",
    "resolved_tier",
    "wave_count",
    "first_oracle_pass_iteration",
    "oracle_after",
    "visible_after",
    "control_edited",
    "harness_reason",
    "expected_tier",
    "expected_floor",
    "control",
    "false_clean_waves",
]
with table_tmp.open("w", encoding="utf-8", newline="") as handle:
    writer = csv.DictWriter(handle, fieldnames=fieldnames, delimiter="\t", lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)
os.replace(table_tmp, table_path)
PY
}
