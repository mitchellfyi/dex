# shellcheck shell=bash
# Dex shared library - local run IDs and structured event journals.

dx_run_root() { printf '%s\n' "${DX_RUN_ROOT:-$HOME/.dex/runs}"; }

dx_run_validate_id() {
  local run_id="$1"
  [[ -n "$run_id" ]] || return 1
  [[ "$run_id" == run_* ]] || return 1
  [[ "$run_id" != *".."* && "$run_id" != *"/"* ]] || return 1
  [[ "$run_id" != *$'\n'* && "$run_id" != *$'\r'* && "$run_id" != *$'\t'* ]] || return 1
  [[ "$run_id" =~ ^run_[A-Za-z0-9._-]+$ ]]
}

dx_event_validate_type() {
  local event_type="$1"
  [[ "$event_type" =~ ^[a-z][a-z0-9_.-]*$ ]]
}

dx_event_validate_severity() {
  local severity="$1"
  [[ "$severity" =~ ^[a-z][a-z0-9_.-]*$ ]]
}

dx_run_id() {
  local timestamp random_part
  timestamp=$(date -u +"%Y%m%dT%H%M%SZ")
  random_part=""
  if command -v od >/dev/null 2>&1 && [[ -r /dev/urandom ]]; then
    random_part=$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n') || random_part=""
  fi
  [[ -n "$random_part" ]] || random_part="${RANDOM}${RANDOM}"
  printf 'run_%s_%s_%s\n' "$timestamp" "$$" "$random_part"
}

dx_run_dir() {
  local run_id="$1"
  dx_run_validate_id "$run_id" || return 1
  printf '%s/%s\n' "$(dx_run_root)" "$run_id"
}

dx_run_spec_file() { printf '%s/spec.json\n' "$(dx_run_dir "$1")"; }
dx_run_events_file() { printf '%s/events.jsonl\n' "$(dx_run_dir "$1")"; }
dx_run_logs_file() { printf '%s/logs.txt\n' "$(dx_run_dir "$1")"; }
dx_run_summary_file() { printf '%s/summary.json\n' "$(dx_run_dir "$1")"; }
dx_run_artifacts_dir() { printf '%s/artifacts\n' "$(dx_run_dir "$1")"; }
dx_run_artifact_manifest_file() { printf '%s/manifest.json\n' "$(dx_run_artifacts_dir "$1")"; }
dx_run_sequence_file() { printf '%s/.sequence\n' "$(dx_run_dir "$1")"; }
dx_run_started_marker_file() { printf '%s/.run-started-emitted\n' "$(dx_run_dir "$1")"; }
dx_run_phase_started_marker_file() { printf '%s/.phase-%s-started-emitted\n' "$(dx_run_dir "$1")" "$2"; }
dx_run_id_file() { printf '%s/%s.run-id\n' "$DX_STATE_DIR" "$1"; }

dx_run_write_for_session() {
  local session_id="$1" run_id="$2" run_id_file tmp_file
  [[ -n "$session_id" ]] || return 1
  dx_run_validate_id "$run_id" || return 1

  run_id_file=$(dx_run_id_file "$session_id")
  mkdir -p "$(dirname "$run_id_file")"
  tmp_file="${run_id_file}.tmp.$$"
  if ! printf '%s\n' "$run_id" > "$tmp_file" || ! command mv -f "$tmp_file" "$run_id_file"; then
    command rm -f "$tmp_file" 2>/dev/null
    return 1
  fi
}

dx_run_read_for_session() {
  local session_id="$1" run_id run_id_file
  if [[ -n "${DEX_RUN_ID:-}" ]] && dx_run_validate_id "$DEX_RUN_ID"; then
    printf '%s\n' "$DEX_RUN_ID"
    return 0
  fi

  [[ -n "$session_id" ]] || return 1
  run_id_file=$(dx_run_id_file "$session_id")
  [[ -f "$run_id_file" ]] || return 1
  run_id=$(cat "$run_id_file" 2>/dev/null || true)
  dx_run_validate_id "$run_id" || return 1
  printf '%s\n' "$run_id"
}

dx_run_resolve() {
  local session_id="$1" run_id
  [[ -n "$session_id" ]] || return 1

  if run_id=$(dx_run_read_for_session "$session_id" 2>/dev/null); then
    dx_run_write_for_session "$session_id" "$run_id" 2>/dev/null || true
    printf '%s\n' "$run_id"
    return 0
  fi

  run_id=$(dx_run_id)
  dx_run_validate_id "$run_id" || return 1
  dx_run_write_for_session "$session_id" "$run_id" || return 1
  printf '%s\n' "$run_id"
}

dx_run_write_spec() {
  local run_id="$1" session_id="$2" repo_dir="${3:-$PWD}" workspace_mode="${4:-unknown}"
  local workspace_name="${5:-}" raw_input="${6:-}" command_name="${7:-dx}"
  local spec_file remote_url
  dx_run_validate_id "$run_id" || return 1

  spec_file=$(dx_run_spec_file "$run_id")
  remote_url=$(git -C "$repo_dir" config --get remote.origin.url 2>/dev/null || true)

  DX_RUN_SPEC_FILE="$spec_file" \
  DX_RUN_ID_VALUE="$run_id" \
  DX_RUN_SESSION_ID="$session_id" \
  DX_RUN_REPO_DIR="$repo_dir" \
  DX_RUN_REMOTE_URL="$remote_url" \
  DX_RUN_WORKSPACE_MODE="$workspace_mode" \
  DX_RUN_WORKSPACE_NAME="$workspace_name" \
  DX_RUN_RAW_INPUT="$raw_input" \
  DX_RUN_COMMAND="$command_name" \
  python3 - <<'PY'
import json
import os
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import parse_qsl, urlencode, urlparse, urlsplit, urlunsplit


def utc_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_repo(remote_url, repo_dir):
    remote_url = (remote_url or "").strip()
    candidate = remote_url
    if candidate:
        if "://" in candidate:
            candidate = urlparse(candidate).path.strip("/")
        elif "@" in candidate and ":" in candidate:
            candidate = candidate.split(":", 1)[1].strip("/")
    if candidate.endswith(".git"):
        candidate = candidate[:-4]
    parts = [part for part in candidate.split("/") if part]
    if len(parts) >= 2:
        company = parts[-2]
        project = parts[-1]
        return company, project, f"{company}/{project}"

    project = Path(repo_dir).name or "repo"
    return "", project, project


def redact_remote_url(remote_url):
    remote_url = (remote_url or "").strip()
    if "://" not in remote_url:
        return remote_url

    parsed = urlsplit(remote_url)
    if not parsed.netloc:
        return remote_url

    host = parsed.hostname or ""
    if ":" in host and not host.startswith("["):
        host = f"[{host}]"
    netloc = host
    try:
        port = parsed.port
    except ValueError:
        port = None
    if port:
        netloc = f"{netloc}:{port}"

    query = []
    secret_fragments = ("token", "secret", "password", "credential", "api_key", "api-key")
    for key, value in parse_qsl(parsed.query, keep_blank_values=True):
        if any(fragment in key.lower() for fragment in secret_fragments):
            query.append((key, "[REDACTED]"))
        else:
            query.append((key, value))
    fragment = "[REDACTED]" if any(secret in parsed.fragment.lower() for secret in secret_fragments) else parsed.fragment
    return urlunsplit((parsed.scheme, netloc, parsed.path, urlencode(query), fragment))


spec_path = Path(os.environ["DX_RUN_SPEC_FILE"])
spec_path.parent.mkdir(parents=True, exist_ok=True)

remote_url = os.environ.get("DX_RUN_REMOTE_URL", "")
company_slug, project_slug, repo = parse_repo(
    remote_url,
    os.environ.get("DX_RUN_REPO_DIR", ""),
)

spec = {
    "schema_version": 1,
    "run_id": os.environ["DX_RUN_ID_VALUE"],
    "session_id": os.environ.get("DX_RUN_SESSION_ID", ""),
    "command": os.environ.get("DX_RUN_COMMAND", "dx"),
    "company_slug": company_slug,
    "project_slug": project_slug,
    "repo": repo,
    "repo_path": os.environ.get("DX_RUN_REPO_DIR", ""),
    "remote_url": redact_remote_url(remote_url),
    "workspace_mode": os.environ.get("DX_RUN_WORKSPACE_MODE", "unknown"),
    "workspace_name": os.environ.get("DX_RUN_WORKSPACE_NAME", ""),
    "input": os.environ.get("DX_RUN_RAW_INPUT", ""),
    "created_at": utc_now(),
    "pid": os.getppid(),
}

tmp = tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=str(spec_path.parent), delete=False)
try:
    with tmp:
        json.dump(spec, tmp, indent=2, sort_keys=True)
        tmp.write("\n")
    os.replace(tmp.name, spec_path)
except Exception:
    try:
        os.unlink(tmp.name)
    except OSError:
        pass
    raise
PY
}

dx_run_prepare() {
  local session_id="$1" repo_dir="${2:-$PWD}" workspace_mode="${3:-unknown}"
  local workspace_name="${4:-}" raw_input="${5:-}" command_name="${6:-dx}"
  local run_id run_dir spec_file
  run_id=$(dx_run_resolve "$session_id") || return 1
  run_dir=$(dx_run_dir "$run_id") || return 1
  spec_file=$(dx_run_spec_file "$run_id") || return 1

  mkdir -p "$run_dir" "$(dx_run_artifacts_dir "$run_id")"
  [[ -f "$(dx_run_logs_file "$run_id")" ]] || : > "$(dx_run_logs_file "$run_id")"
  dx_run_artifact_manifest_prepare "$run_id" || return 1
  if [[ ! -f "$spec_file" ]]; then
    dx_run_write_spec "$run_id" "$session_id" "$repo_dir" "$workspace_mode" "$workspace_name" "$raw_input" "$command_name" || return 1
  fi
  printf '%s\n' "$run_id"
}

dx_run_artifact_manifest_prepare() {
  local run_id="$1" manifest_file
  dx_run_validate_id "$run_id" || return 1
  manifest_file=$(dx_run_artifact_manifest_file "$run_id") || return 1

  DX_RUN_ARTIFACT_MANIFEST_FILE="$manifest_file" python3 - <<'PY'
import json
import os
import tempfile
from datetime import datetime, timezone
from pathlib import Path


def utc_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


manifest_path = Path(os.environ["DX_RUN_ARTIFACT_MANIFEST_FILE"])
manifest_path.parent.mkdir(parents=True, exist_ok=True)
if manifest_path.exists():
    raise SystemExit(0)

manifest = {
    "schema_version": 1,
    "artifacts": [],
    "created_at": utc_now(),
    "updated_at": utc_now(),
}
tmp = tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=str(manifest_path.parent), delete=False)
try:
    with tmp:
        json.dump(manifest, tmp, indent=2, sort_keys=True)
        tmp.write("\n")
    os.replace(tmp.name, manifest_path)
except Exception:
    try:
        os.unlink(tmp.name)
    except OSError:
        pass
    raise
PY
}

dx_run_artifact_file() {
  local run_id="$1" rel_path="$2"
  dx_run_validate_id "$run_id" || return 1
  [[ -n "$rel_path" ]] || return 1

  DX_RUN_ARTIFACT_DIR="$(dx_run_artifacts_dir "$run_id")" \
  DX_RUN_ARTIFACT_REL_PATH="$rel_path" \
  python3 - <<'PY'
import os
import sys
from pathlib import Path, PurePosixPath

root = Path(os.environ["DX_RUN_ARTIFACT_DIR"]).resolve()
rel_raw = os.environ["DX_RUN_ARTIFACT_REL_PATH"]
rel = PurePosixPath(rel_raw)
if rel.is_absolute() or not rel.parts or any(part in ("", ".", "..") for part in rel.parts):
    raise SystemExit(1)
target = (root / Path(*rel.parts)).resolve()
if target != root and root not in target.parents:
    raise SystemExit(1)
print(target)
PY
}

dx_run_register_artifact() {
  local run_id="$1" artifact_type="$2" rel_path="$3" title="$4" metadata_json="${5:-}"
  local manifest_file artifact_root event_data
  [[ -n "$metadata_json" ]] || metadata_json="{}"
  dx_run_validate_id "$run_id" || return 1
  dx_event_validate_type "$artifact_type" || return 1
  [[ -n "$rel_path" && -n "$title" ]] || return 1
  manifest_file=$(dx_run_artifact_manifest_file "$run_id") || return 1
  artifact_root=$(dx_run_artifacts_dir "$run_id") || return 1
  dx_run_artifact_manifest_prepare "$run_id" || return 1

  event_data=$(DX_RUN_ARTIFACT_MANIFEST_FILE="$manifest_file" \
    DX_RUN_ARTIFACT_ROOT="$artifact_root" \
    DX_RUN_ARTIFACT_TYPE="$artifact_type" \
    DX_RUN_ARTIFACT_PATH="$rel_path" \
    DX_RUN_ARTIFACT_TITLE="$title" \
    python3 - "$metadata_json" <<'PY'
import hashlib
import json
import os
import sys
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath


def utc_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def safe_artifact_path(root, rel_raw):
    rel = PurePosixPath(rel_raw)
    if rel.is_absolute() or not rel.parts or any(part in ("", ".", "..") for part in rel.parts):
        raise SystemExit("unsafe artifact path")
    target = (root / Path(*rel.parts)).resolve()
    if target != root and root not in target.parents:
        raise SystemExit("unsafe artifact path")
    return rel, target


metadata = json.loads(sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else "{}")
if not isinstance(metadata, dict):
    raise SystemExit("artifact metadata must be a JSON object")

manifest_path = Path(os.environ["DX_RUN_ARTIFACT_MANIFEST_FILE"])
root = Path(os.environ["DX_RUN_ARTIFACT_ROOT"]).resolve()
root.mkdir(parents=True, exist_ok=True)
rel, target = safe_artifact_path(root, os.environ["DX_RUN_ARTIFACT_PATH"])

manifest = {"schema_version": 1, "artifacts": [], "created_at": utc_now(), "updated_at": utc_now()}
if manifest_path.exists():
    with manifest_path.open("r", encoding="utf-8") as fh:
        loaded = json.load(fh)
        if isinstance(loaded, dict):
            manifest.update(loaded)
            if not isinstance(manifest.get("artifacts"), list):
                manifest["artifacts"] = []

size_bytes = target.stat().st_size if target.exists() else None
sha256 = None
if target.exists() and target.is_file():
    digest = hashlib.sha256()
    with target.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    sha256 = digest.hexdigest()

artifact = None
for item in manifest["artifacts"]:
    if item.get("type") == os.environ["DX_RUN_ARTIFACT_TYPE"] and item.get("path") == rel.as_posix():
        artifact = item
        break

created = artifact is None
if artifact is None:
    artifact = {"id": f"art_{uuid.uuid4().hex[:12]}"}
    manifest["artifacts"].append(artifact)

artifact.update(
    {
        "type": os.environ["DX_RUN_ARTIFACT_TYPE"],
        "path": rel.as_posix(),
        "title": os.environ["DX_RUN_ARTIFACT_TITLE"],
        "created_at": artifact.get("created_at") or utc_now(),
        "updated_at": utc_now(),
        "size_bytes": size_bytes,
        "sha256": sha256,
        "metadata": metadata,
    }
)
manifest["updated_at"] = utc_now()

tmp = tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=str(manifest_path.parent), delete=False)
try:
    with tmp:
        json.dump(manifest, tmp, indent=2, sort_keys=True)
        tmp.write("\n")
    os.replace(tmp.name, manifest_path)
except Exception:
    try:
        os.unlink(tmp.name)
    except OSError:
        pass
    raise

print(json.dumps({
    "artifact_id": artifact["id"],
    "type": artifact["type"],
    "path": artifact["path"],
    "title": artifact["title"],
    "size_bytes": size_bytes,
    "created": created,
}, sort_keys=True, separators=(",", ":")))
PY
  ) || return 1

  dx_event_emit_safe "$run_id" "artifact.created" "info" "Artifact captured: ${title}" "" "$event_data"
}

dx_run_register_artifact_safe() {
  dx_run_register_artifact "$@" 2>/dev/null || return 0
}

dx_run_log_append() {
  local run_id="$1" level="${2:-info}" source="${3:-dex}" message="${4:-}" log_file
  dx_run_validate_id "$run_id" || return 1
  dx_event_validate_severity "$level" || return 1
  log_file=$(dx_run_logs_file "$run_id") || return 1

  DX_RUN_LOG_FILE="$log_file" \
  DX_RUN_LOG_LEVEL="$level" \
  DX_RUN_LOG_SOURCE="$source" \
  DX_RUN_LOG_MESSAGE="$message" \
  python3 - <<'PY'
import os
import re
from datetime import datetime, timezone
from pathlib import Path


SECRET_PATTERNS = [
    re.compile(r"(?i)(authorization\s*:\s*(?:bearer|basic)\s+)[A-Za-z0-9._~+/=-]+"),
    re.compile(r"(?i)(\b(?!authorization\b)[A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|PASS|API[_-]?KEY|AUTH)[A-Z0-9_]*\s*[=:]\s*)([\"']?)[^\"'\s]+"),
    re.compile(r"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{16,}\b"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}\b"),
    re.compile(r"\bsk-[A-Za-z0-9_-]{20,}\b"),
    re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"),
]
SECRET_URL_RE = re.compile(r"(?i)\b([a-z][a-z0-9+.-]*://)([^/@\s]+)@")


def utc_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def redact(text):
    text = SECRET_URL_RE.sub(r"\1[REDACTED]@", text)
    text = SECRET_PATTERNS[0].sub(r"\1[REDACTED]", text)
    text = SECRET_PATTERNS[1].sub(r"\1\2[REDACTED]", text)
    for pattern in SECRET_PATTERNS[2:]:
        text = pattern.sub("[REDACTED]", text)
    return text


log_path = Path(os.environ["DX_RUN_LOG_FILE"])
log_path.parent.mkdir(parents=True, exist_ok=True)
line = "[{ts}] [{level}] [{source}] {message}\n".format(
    ts=utc_now(),
    level=os.environ.get("DX_RUN_LOG_LEVEL", "info"),
    source=os.environ.get("DX_RUN_LOG_SOURCE", "dex"),
    message=redact(os.environ.get("DX_RUN_LOG_MESSAGE", "")),
)
with log_path.open("a", encoding="utf-8") as fh:
    fh.write(line)
PY
}

dx_run_log_append_safe() {
  dx_run_log_append "$@" 2>/dev/null || return 0
}

dx_run_log_append_for_session() {
  local session_id="$1" run_id
  shift
  run_id=$(dx_run_read_for_session "$session_id" 2>/dev/null || true)
  [[ -n "$run_id" ]] || return 0
  dx_run_log_append_safe "$run_id" "$@"
}

dx_run_log_tee() {
  local run_id="$1" source="${2:-harness}" line
  if ! dx_run_validate_id "$run_id"; then
    cat
    return 0
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s\n' "$line"
    dx_run_log_append_safe "$run_id" "info" "$source" "$line"
  done
}

__dx_event_acquire_lock() {
  local lock_dir="$1" attempts=0
  while ! mkdir "$lock_dir" 2>/dev/null; do
    attempts=$((attempts + 1))
    [[ "$attempts" -lt 100 ]] || return 1
    sleep 0.05
  done
}

dx_event_emit() {
  local run_id="$1" event_type="$2" severity="${3:-info}" message="${4:-}"
  local phase="${5:-}" data_json="${6:-}"
  local run_dir events_file sequence_file lock_dir event_status
  [[ -n "$data_json" ]] || data_json="{}"
  dx_run_validate_id "$run_id" || return 1
  dx_event_validate_type "$event_type" || return 1
  dx_event_validate_severity "$severity" || return 1

  run_dir=$(dx_run_dir "$run_id") || return 1
  events_file=$(dx_run_events_file "$run_id") || return 1
  sequence_file=$(dx_run_sequence_file "$run_id") || return 1
  lock_dir="$run_dir/.events.lock"
  mkdir -p "$run_dir"
  __dx_event_acquire_lock "$lock_dir" || return 1

  if DX_EVENT_RUN_DIR="$run_dir" \
    DX_EVENT_FILE="$events_file" \
    DX_EVENT_SEQUENCE_FILE="$sequence_file" \
    DX_EVENT_RUN_ID="$run_id" \
    DX_EVENT_TYPE="$event_type" \
    DX_EVENT_SEVERITY="$severity" \
    DX_EVENT_MESSAGE="$message" \
    DX_EVENT_PHASE="$phase" \
    python3 - "$data_json" <<'PY'
import json
import os
import re
import sys
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path


SECRET_PATTERNS = [
    re.compile(r"(?i)(authorization\s*:\s*(?:bearer|basic)\s+)[A-Za-z0-9._~+/=-]+"),
    re.compile(r"(?i)(\b(?!authorization\b)[A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|PASS|API[_-]?KEY|AUTH)[A-Z0-9_]*\s*[=:]\s*)([\"']?)[^\"'\s]+"),
    re.compile(r"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{16,}\b"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}\b"),
    re.compile(r"\bsk-[A-Za-z0-9_-]{20,}\b"),
    re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"),
]
SECRET_URL_RE = re.compile(r"(?i)\b([a-z][a-z0-9+.-]*://)([^/@\s]+)@")
SECRET_KEY_RE = re.compile(r"(?i)(token|secret|password|passwd|api[_-]?key|credential)")


def utc_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def redact(text):
    text = SECRET_URL_RE.sub(r"\1[REDACTED]@", text)
    text = SECRET_PATTERNS[0].sub(r"\1[REDACTED]", text)
    text = SECRET_PATTERNS[1].sub(r"\1\2[REDACTED]", text)
    for pattern in SECRET_PATTERNS[2:]:
        text = pattern.sub("[REDACTED]", text)
    return text


def redact_value(value, key=""):
    normalized_key = str(key).lower().replace("-", "_")
    auth_key = normalized_key in {"auth", "authorization"} or normalized_key.startswith("auth_") or normalized_key.endswith("_auth") or "_auth_" in normalized_key
    if SECRET_KEY_RE.search(str(key)) or auth_key:
        return "[REDACTED]" if value else value
    if isinstance(value, dict):
        return {item_key: redact_value(item_value, item_key) for item_key, item_value in value.items()}
    if isinstance(value, list):
        return [redact_value(item) for item in value]
    if isinstance(value, str):
        return redact(value)
    return value


run_dir = Path(os.environ["DX_EVENT_RUN_DIR"])
events_file = Path(os.environ["DX_EVENT_FILE"])
sequence_file = Path(os.environ["DX_EVENT_SEQUENCE_FILE"])
spec_file = run_dir / "spec.json"

try:
    data = json.loads(sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else "{}")
except json.JSONDecodeError as exc:
    raise SystemExit(f"invalid event data JSON: {exc}") from exc
if not isinstance(data, dict):
    raise SystemExit("event data must be a JSON object")

spec = {}
if spec_file.exists():
    with spec_file.open("r", encoding="utf-8") as fh:
        loaded = json.load(fh)
        if isinstance(loaded, dict):
            spec = loaded

try:
    sequence = int(sequence_file.read_text(encoding="utf-8").strip() or "0")
except (OSError, ValueError):
    sequence = 0
sequence += 1

phase_raw = os.environ.get("DX_EVENT_PHASE", "")
phase = None if phase_raw == "" else phase_raw

event = {
    "id": f"evt_{sequence:06d}_{uuid.uuid4().hex[:8]}",
    "run_id": os.environ["DX_EVENT_RUN_ID"],
    "sequence": sequence,
    "type": os.environ["DX_EVENT_TYPE"],
    "company_slug": spec.get("company_slug", ""),
    "project_slug": spec.get("project_slug", ""),
    "repo": spec.get("repo", ""),
    "phase": phase,
    "severity": os.environ.get("DX_EVENT_SEVERITY", "info"),
    "message": redact(os.environ.get("DX_EVENT_MESSAGE", "")),
    "data": redact_value(data),
    "created_at": utc_now(),
}

events_file.parent.mkdir(parents=True, exist_ok=True)
with events_file.open("a", encoding="utf-8") as fh:
    fh.write(json.dumps(event, sort_keys=True, separators=(",", ":")))
    fh.write("\n")

tmp = tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=str(sequence_file.parent), delete=False)
try:
    with tmp:
        tmp.write(f"{sequence}\n")
    os.replace(tmp.name, sequence_file)
except Exception:
    try:
        os.unlink(tmp.name)
    except OSError:
        pass
    raise
PY
  then
    event_status=0
  else
    event_status=$?
  fi
  command rmdir "$lock_dir" 2>/dev/null || command rm -rf "$lock_dir" 2>/dev/null || true
  if [[ "$event_status" -eq 0 ]] && command -v dx_factory_sync_pending_events_safe >/dev/null 2>&1; then
    dx_factory_sync_pending_events_safe "$run_id" || true
  fi
  return "$event_status"
}

dx_event_emit_safe() {
  dx_event_emit "$@" 2>/dev/null || true
  return 0
}

dx_event_emit_for_session() {
  local session_id="$1" run_id
  shift
  run_id=$(dx_run_read_for_session "$session_id" 2>/dev/null || true)
  [[ -n "$run_id" ]] || return 0
  dx_event_emit_safe "$run_id" "$@"
}

dx_run_maybe_emit_started() {
  local run_id="$1" message="${2:-Dex run started}" data_json="${3:-}"
  local marker
  [[ -n "$data_json" ]] || data_json="{}"
  marker=$(dx_run_started_marker_file "$run_id") || return 0
  [[ -f "$marker" ]] && return 0
  if dx_event_emit "$run_id" "run.started" "info" "$message" "" "$data_json" 2>/dev/null; then
    : > "$marker" 2>/dev/null || true
  fi
  return 0
}

dx_event_maybe_emit_phase_started() {
  local run_id="$1" phase="$2" phase_name="$3" source="${4:-hook}" marker data_json
  dx_run_validate_id "$run_id" || return 0
  [[ "$phase" =~ ^[0-6]$ ]] || return 0
  marker=$(dx_run_phase_started_marker_file "$run_id" "$phase") || return 0
  [[ -f "$marker" ]] && return 0
  data_json=$(DX_EVENT_PHASE_NAME="$phase_name" DX_EVENT_SOURCE="$source" python3 - <<'PY'
import json
import os

print(json.dumps({
    "phase_name": os.environ.get("DX_EVENT_PHASE_NAME", ""),
    "source": os.environ.get("DX_EVENT_SOURCE", ""),
}, sort_keys=True, separators=(",", ":")))
PY
  ) || return 0
  if dx_event_emit "$run_id" "phase.started" "info" "Phase ${phase} started: ${phase_name}" "$phase" "$data_json" 2>/dev/null; then
    : > "$marker" 2>/dev/null || true
  fi
  return 0
}

dx_event_maybe_emit_phase_started_for_session() {
  local session_id="$1" phase="$2" phase_name="$3" source="${4:-hook}" run_id
  run_id=$(dx_run_read_for_session "$session_id" 2>/dev/null || true)
  [[ -n "$run_id" ]] || return 0
  dx_event_maybe_emit_phase_started "$run_id" "$phase" "$phase_name" "$source"
}

dx_run_write_summary() {
  local run_id="$1" run_status="$2" message="${3:-}" summary_file
  dx_run_validate_id "$run_id" || return 1
  summary_file=$(dx_run_summary_file "$run_id") || return 1
  dx_run_write_summary_artifact "$run_id" "$run_status" "$message" 2>/dev/null || true

  DX_RUN_SUMMARY_FILE="$summary_file" \
  DX_RUN_ID_VALUE="$run_id" \
  DX_RUN_STATUS="$run_status" \
  DX_RUN_MESSAGE="$message" \
  DX_RUN_SEQUENCE_FILE="$(dx_run_sequence_file "$run_id")" \
  python3 - <<'PY'
import json
import os
import re
import tempfile
from datetime import datetime, timezone
from pathlib import Path


SECRET_PATTERNS = [
    re.compile(r"(?i)(authorization\s*:\s*(?:bearer|basic)\s+)[A-Za-z0-9._~+/=-]+"),
    re.compile(r"(?i)(\b(?!authorization\b)[A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|PASS|API[_-]?KEY|AUTH)[A-Z0-9_]*\s*[=:]\s*)([\"']?)[^\"'\s]+"),
    re.compile(r"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{16,}\b"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}\b"),
    re.compile(r"\bsk-[A-Za-z0-9_-]{20,}\b"),
    re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"),
]
SECRET_URL_RE = re.compile(r"(?i)\b([a-z][a-z0-9+.-]*://)([^/@\s]+)@")


def utc_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def redact(text):
    text = SECRET_URL_RE.sub(r"\1[REDACTED]@", text)
    text = SECRET_PATTERNS[0].sub(r"\1[REDACTED]", text)
    text = SECRET_PATTERNS[1].sub(r"\1\2[REDACTED]", text)
    for pattern in SECRET_PATTERNS[2:]:
        text = pattern.sub("[REDACTED]", text)
    return text


summary_path = Path(os.environ["DX_RUN_SUMMARY_FILE"])
sequence_file = Path(os.environ["DX_RUN_SEQUENCE_FILE"])
try:
    last_sequence = int(sequence_file.read_text(encoding="utf-8").strip() or "0")
except (OSError, ValueError):
    last_sequence = 0

summary = {
    "schema_version": 1,
    "run_id": os.environ["DX_RUN_ID_VALUE"],
    "status": os.environ.get("DX_RUN_STATUS", "unknown"),
    "message": redact(os.environ.get("DX_RUN_MESSAGE", "")),
    "last_sequence": last_sequence,
    "updated_at": utc_now(),
}

summary_path.parent.mkdir(parents=True, exist_ok=True)
tmp = tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=str(summary_path.parent), delete=False)
try:
    with tmp:
        json.dump(summary, tmp, indent=2, sort_keys=True)
        tmp.write("\n")
    os.replace(tmp.name, summary_path)
except Exception:
    try:
        os.unlink(tmp.name)
    except OSError:
        pass
    raise
PY
}

dx_run_write_summary_artifact() {
  local run_id="$1" run_status="$2" message="${3:-}" artifact_file
  dx_run_validate_id "$run_id" || return 1
  artifact_file=$(dx_run_artifact_file "$run_id" "run-summary.md") || return 1

  DX_RUN_SUMMARY_ARTIFACT_FILE="$artifact_file" \
  DX_RUN_ID_VALUE="$run_id" \
  DX_RUN_STATUS="$run_status" \
  DX_RUN_MESSAGE="$message" \
  DX_RUN_SUMMARY_JSON_PATH="$(dx_run_summary_file "$run_id")" \
  python3 - <<'PY'
import os
import re
import tempfile
from datetime import datetime, timezone
from pathlib import Path


SECRET_PATTERNS = [
    re.compile(r"(?i)(authorization\s*:\s*(?:bearer|basic)\s+)[A-Za-z0-9._~+/=-]+"),
    re.compile(r"(?i)(\b(?!authorization\b)[A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|PASS|API[_-]?KEY|AUTH)[A-Z0-9_]*\s*[=:]\s*)([\"']?)[^\"'\s]+"),
    re.compile(r"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{16,}\b"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}\b"),
    re.compile(r"\bsk-[A-Za-z0-9_-]{20,}\b"),
    re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"),
]
SECRET_URL_RE = re.compile(r"(?i)\b([a-z][a-z0-9+.-]*://)([^/@\s]+)@")


def utc_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def redact(text):
    text = SECRET_URL_RE.sub(r"\1[REDACTED]@", text)
    text = SECRET_PATTERNS[0].sub(r"\1[REDACTED]", text)
    text = SECRET_PATTERNS[1].sub(r"\1\2[REDACTED]", text)
    for pattern in SECRET_PATTERNS[2:]:
        text = pattern.sub("[REDACTED]", text)
    return text


artifact_path = Path(os.environ["DX_RUN_SUMMARY_ARTIFACT_FILE"])
artifact_path.parent.mkdir(parents=True, exist_ok=True)
content = "\n".join(
    [
        "# Dex Run Summary",
        "",
        f"- Run ID: `{os.environ['DX_RUN_ID_VALUE']}`",
        f"- Status: `{os.environ.get('DX_RUN_STATUS', 'unknown')}`",
        f"- Message: {redact(os.environ.get('DX_RUN_MESSAGE', ''))}",
        f"- Summary JSON: `{os.environ.get('DX_RUN_SUMMARY_JSON_PATH', '')}`",
        f"- Updated at: {utc_now()}",
        "",
    ]
)
tmp = tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=str(artifact_path.parent), delete=False)
try:
    with tmp:
        tmp.write(content)
    os.replace(tmp.name, artifact_path)
except Exception:
    try:
        os.unlink(tmp.name)
    except OSError:
        pass
    raise
PY
  dx_run_register_artifact_safe "$run_id" "run_summary" "run-summary.md" "Run summary" "{\"status\":\"${run_status}\"}"
}

dx_run_write_summary_safe() {
  dx_run_write_summary "$@" 2>/dev/null || return 0
}

dx_run_write_summary_for_session() {
  local session_id="$1" run_id
  shift
  run_id=$(dx_run_read_for_session "$session_id" 2>/dev/null || true)
  [[ -n "$run_id" ]] || return 0
  dx_run_write_summary_safe "$run_id" "$@"
}
