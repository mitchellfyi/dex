#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

# shellcheck disable=SC2034  # read by lib/common.sh while it is sourced
DX_COMMON_MODULES="session session-runtime session-catalog output"
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: dx sessions <list|show|doctor|pause|cancel|resume> [options]

Inspect lifecycle sessions, control live runs, or relaunch one dead lifecycle.

Commands:
  list [--all] [--include-children]
      List sessions in the current repository. Use --all for every repository
      Dex can recover from trusted session metadata.

  show <selector> [--include-children]
      Show one session selected by an exact session ID, ticket:<id>,
      workspace:<name-or-path>, or an exact unqualified value.

  doctor [selector] [--include-children]
      Check catalog and runtime structure for one session or every session in
      the current repository.

  pause <selector>
      Ask one verified live session in the current repository to pause.

  cancel <selector>
      Ask one verified live session in the current repository to cancel.

  resume <selector>
      Relaunch one verified dead lifecycle in the current repository.

Options:
  --all               Search every recoverable repository (list only)
  --include-children  Include internal review child sessions
  -h, --help          Show this help
USAGE
}

SESSIONS_TEMP_DIR=""

__dx_sessions_cleanup() {
  if [[ -n "$SESSIONS_TEMP_DIR" && -d "$SESSIONS_TEMP_DIR" ]]; then
    command rm -rf "$SESSIONS_TEMP_DIR"
  fi
}

__dx_sessions_ensure_temp_dir() {
  [[ -n "$SESSIONS_TEMP_DIR" ]] && return 0
  if ! SESSIONS_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/dex-sessions.XXXXXX"); then
    dx_error "Could not create temporary space for the session report."
    return 1
  fi
  trap __dx_sessions_cleanup EXIT
}

__dx_sessions_metadata_workspaces() {
  python3 - "$DX_STATE_DIR" <<'PY'
import os
import re
import stat
import sys


state_dir = sys.argv[1]
session_re = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,179}$")
max_bytes = 64 * 1024


def fingerprint(metadata):
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_uid,
        metadata.st_nlink,
        metadata.st_size,
        getattr(metadata, "st_mtime_ns", int(metadata.st_mtime * 1_000_000_000)),
    )


try:
    entries = os.scandir(state_dir)
except FileNotFoundError:
    raise SystemExit(0)
except OSError as error:
    print(f"dex sessions: cannot read session metadata: {error}", file=sys.stderr)
    raise SystemExit(3)

with entries:
    for entry in entries:
        if not entry.name.endswith(".meta"):
            continue
        session_id = entry.name[:-5]
        if not session_re.fullmatch(session_id):
            continue
        descriptor = None
        try:
            before = entry.stat(follow_symlinks=False)
            permissions = stat.S_IMODE(before.st_mode)
            if (
                not stat.S_ISREG(before.st_mode)
                or before.st_uid != os.geteuid()
                or before.st_nlink != 1
                or permissions & 0o022
                or before.st_size <= 0
                or before.st_size > max_bytes
            ):
                continue
            flags = os.O_RDONLY
            flags |= getattr(os, "O_CLOEXEC", 0)
            flags |= getattr(os, "O_NOFOLLOW", 0)
            flags |= getattr(os, "O_NONBLOCK", 0)
            descriptor = os.open(entry.path, flags)
            opened = os.fstat(descriptor)
            if fingerprint(opened) != fingerprint(before):
                continue
            chunks = []
            remaining = max_bytes + 1
            while remaining > 0:
                chunk = os.read(descriptor, min(remaining, 4096))
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
            payload = b"".join(chunks)
            after = os.fstat(descriptor)
            if fingerprint(after) != fingerprint(opened) or len(payload) > max_bytes:
                continue
            text = payload.decode("utf-8")
        except (OSError, UnicodeDecodeError, ValueError):
            continue
        finally:
            if descriptor is not None:
                os.close(descriptor)

        workspace = None
        duplicate = False
        for raw_line in text.splitlines():
            if not raw_line.startswith("wt_dir="):
                continue
            if workspace is not None:
                duplicate = True
                break
            workspace = raw_line[len("wt_dir=") :]
        if (
            duplicate
            or not workspace
            or not os.path.isabs(workspace)
            or len(workspace) > 4096
            or any(ord(character) < 32 or ord(character) == 127 for character in workspace)
        ):
            continue
        print(workspace)
PY
}

__dx_sessions_runtime_workspaces() {
  local runtime_file session_id runtime_record
  [[ -d "$DX_STATE_DIR" ]] || return 0
  if [[ ! -r "$DX_STATE_DIR" ]]; then
    dx_error "Cannot read the lifecycle state directory."
    return 3
  fi
  for runtime_file in "$DX_STATE_DIR"/*.runtime; do
    [[ -e "$runtime_file" || -L "$runtime_file" ]] || continue
    session_id="$(basename "$runtime_file" .runtime)"
    dx_session_id_valid "$session_id" || continue
    if ! runtime_record=$(dx_session_runtime_read "$session_id" 2>/dev/null); then
      continue
    fi
    if ! printf '%s\n' "$runtime_record" | python3 -c '
import json
import sys

try:
    record = json.load(sys.stdin)
except (json.JSONDecodeError, RecursionError):
    raise SystemExit(0)
workspace = record.get("workspace")
if isinstance(workspace, str):
    print(workspace)
'; then
      dx_error "Could not parse a validated runtime record."
      return 3
    fi
  done
}

__dx_sessions_global_repositories() {
  local candidate_file root_file candidate_dir repo_root
  __dx_sessions_ensure_temp_dir || return 1
  candidate_file="$SESSIONS_TEMP_DIR/workspaces"
  root_file="$SESSIONS_TEMP_DIR/repositories"
  : > "$candidate_file"

  if repo_root=$(dx_session_repo_root 2>/dev/null); then
    printf '%s\n' "$repo_root" >> "$candidate_file"
  fi
  if ! __dx_sessions_metadata_workspaces >> "$candidate_file"; then
    dx_error "Could not discover repositories from session metadata."
    return 3
  fi
  if ! __dx_sessions_runtime_workspaces >> "$candidate_file"; then
    dx_error "Could not discover repositories from runtime records."
    return 3
  fi

  : > "$root_file"
  while IFS= read -r candidate_dir; do
    [[ -n "$candidate_dir" && -d "$candidate_dir" ]] || continue
    case "$candidate_dir" in
      *$'\n'*|*$'\r'*|*$'\t'*) continue ;;
    esac
    if repo_root=$(cd "$candidate_dir" 2>/dev/null && dx_session_repo_root); then
      case "$repo_root" in
        *$'\n'*|*$'\r'*|*$'\t'*) continue ;;
      esac
      printf '%s\n' "$repo_root" >> "$root_file"
    fi
  done < "$candidate_file"
  if ! LC_ALL=C sort -u "$root_file"; then
    dx_error "Could not sort the recovered repository list."
    return 3
  fi
}

__dx_sessions_collect_current() {
  local output_file="$1" include_children="$2" collect_result
  local catalog_arguments=(--repo "${PWD:-.}")
  [[ "$include_children" -eq 0 ]] || catalog_arguments+=(--include-children)
  if dx_session_catalog_records "${catalog_arguments[@]}" > "$output_file"; then
    return 0
  else
    collect_result=$?
  fi
  if [[ "$collect_result" -eq 3 ]]; then
    dx_error "Run this command inside a Git repository, or use 'dx sessions list --all'."
  else
    dx_error "Could not read the lifecycle session catalog."
  fi
  return "$collect_result"
}

__dx_sessions_collect_global() {
  local output_file="$1" include_children="$2" repositories_file raw_file
  local repo_dir repo_records collect_result=0 catalog_result discovery_result
  local catalog_arguments
  __dx_sessions_ensure_temp_dir || return 1
  repositories_file="$SESSIONS_TEMP_DIR/repositories-list"
  raw_file="$SESSIONS_TEMP_DIR/global-records.raw"
  : > "$raw_file"
  if __dx_sessions_global_repositories > "$repositories_file"; then
    :
  else
    discovery_result=$?
    return "$discovery_result"
  fi

  while IFS= read -r repo_dir; do
    [[ -n "$repo_dir" ]] || continue
    repo_records="$SESSIONS_TEMP_DIR/repo-records.$$"
    catalog_arguments=(--repo "$repo_dir")
    [[ "$include_children" -eq 0 ]] || catalog_arguments+=(--include-children)
    if dx_session_catalog_records "${catalog_arguments[@]}" > "$repo_records"; then
      if ! command cat "$repo_records" >> "$raw_file"; then
        dx_error "Could not assemble the global session report."
        return 3
      fi
    else
      catalog_result=$?
      dx_warn "Could not inspect sessions for $repo_dir."
      collect_result="$catalog_result"
    fi
  done < "$repositories_file"

  if python3 - "$raw_file" > "$output_file" <<'PY'
import json
import sys


records = {}
with open(sys.argv[1], "r", encoding="utf-8") as records_file:
    for raw_line in records_file:
        if not raw_line.strip():
            continue
        record = json.loads(raw_line)
        records[record["session_id"]] = record
for session_id in sorted(records):
    print(json.dumps(records[session_id], sort_keys=True, separators=(",", ":")))
PY
  then
    :
  else
    dx_error "Could not parse the global session catalog."
    return 3
  fi
  return "$collect_result"
}

__dx_sessions_emit_list() {
  local records_file="$1" formatted_file line
  if [[ ! -s "$records_file" ]]; then
    dx_info "No lifecycle sessions found."
    return 0
  fi
  __dx_sessions_ensure_temp_dir || return 1
  formatted_file="$SESSIONS_TEMP_DIR/list-formatted"
  if python3 - "$records_file" > "$formatted_file" <<'PY'
import json
import sys


with open(sys.argv[1], "r", encoding="utf-8") as records_file:
    for raw_line in records_file:
        record = json.loads(raw_line)
        phase = record.get("phase")
        workspace = record.get("workspace_name") or record.get("workspace") or "-"
        print(
            f'{record["session_id"]} | state={record.get("lifecycle_state") or "unknown"}'
            f' | phase={phase if phase is not None else "-"}'
            f' | runtime={record.get("runtime_health") or "unknown"}'
            f' | provider={record.get("provider") or "-"}'
            f' | workspace={workspace}'
        )
PY
  then
    :
  else
    dx_error "Could not format the lifecycle session list."
    return 3
  fi
  while IFS= read -r line; do
    dx_info "$line"
  done < "$formatted_file"
}

__dx_sessions_select_current() {
  local selector_value="$1" include_children="$2" selected_record select_result
  local catalog_arguments=(--repo "${PWD:-.}")
  [[ "$include_children" -eq 0 ]] || catalog_arguments+=(--include-children)
  if selected_record=$(dx_session_catalog_select \
    "$selector_value" "${catalog_arguments[@]}"); then
    printf '%s\n' "$selected_record"
    return 0
  else
    select_result=$?
  fi
  case "$select_result" in
    1) dx_error "No session matches '$selector_value'." ;;
    2) ;;
    3) dx_error "Could not resolve that selector in the current repository." ;;
    *) dx_error "Could not read the lifecycle session catalog." ;;
  esac
  return "$select_result"
}

__dx_sessions_emit_show() {
  local record_json="$1" formatted_file record_file line
  __dx_sessions_ensure_temp_dir || return 1
  formatted_file="$SESSIONS_TEMP_DIR/show-formatted"
  record_file="$SESSIONS_TEMP_DIR/show-record"
  printf '%s\n' "$record_json" > "$record_file"
  if python3 - "$record_file" > "$formatted_file" <<'PY'
import json
import sys


with open(sys.argv[1], "r", encoding="utf-8") as record_file:
    record = json.load(record_file)


def value(field_name, fallback="-"):
    field_value = record.get(field_name)
    if field_value is None or field_value == "":
        return fallback
    return str(field_value)


print(f'Session: {value("session_id")}')
print(f'Lifecycle state: {value("lifecycle_state", "unknown")}')
print(f'Phase: {value("phase")}')
print(f'Runtime health: {value("runtime_health", "unknown")}')
print(f'Runtime status: {value("runtime_status")}')
print(f'Provider: {value("provider")}')
print(f'Process ID: {value("runtime_pid")}')
print(f'Ticket: {value("ticket")}')
print(f'Workspace: {value("workspace")}')
print(f'Workspace name: {value("workspace_name")}')
print(f'Metadata health: {value("metadata_health", "unknown")}')
if record.get("is_child"):
    print(f'Parent session: {value("parent_session_id")}')
    print(f'Child kind: {value("child_kind")}')
print(f'Artifacts: {", ".join(record.get("artifacts") or []) or "-"}')
print(f'Unsafe artifacts: {", ".join(record.get("unsafe_artifacts") or []) or "none"}')
print(f'Consistency issues: {", ".join(record.get("consistency_issues") or []) or "none"}')
PY
  then
    :
  else
    dx_error "Could not format the lifecycle session record."
    return 3
  fi
  while IFS= read -r line; do
    dx_info "$line"
  done < "$formatted_file"
}

__dx_sessions_emit_doctor() {
  local records_file="$1" validation_mode="${2:-report}"
  local diagnostics_file diagnostics_result line severity message
  [[ "$validation_mode" == "report" || "$validation_mode" == "mutation" ]] \
    || return 3
  __dx_sessions_ensure_temp_dir || return 1
  diagnostics_file="$SESSIONS_TEMP_DIR/doctor-diagnostics"
  if python3 - "$records_file" "$DX_LOOP_DIR" "$validation_mode" \
    > "$diagnostics_file" <<'PY'
import json
import os
import re
import stat
import sys


records = []
with open(sys.argv[1], "r", encoding="utf-8") as records_file:
    for raw_line in records_file:
        if raw_line.strip():
            records.append(json.loads(raw_line))

provider_re = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
max_provider_bytes = 16 * 1024
mutation_mode = sys.argv[3] == "mutation"


def fingerprint(metadata):
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_uid,
        metadata.st_nlink,
        metadata.st_size,
        getattr(metadata, "st_mtime_ns", int(metadata.st_mtime * 1_000_000_000)),
    )


def provider_artifact(record):
    artifacts = set(record.get("artifacts") or [])
    if "provider" not in artifacts:
        return "missing", None
    if "provider" in set(record.get("unsafe_artifacts") or []):
        return "unsafe", None

    provider_file = os.path.join(sys.argv[2], f'{record["session_id"]}.provider')
    descriptor = None
    try:
        before = os.lstat(provider_file)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_uid != os.geteuid()
            or before.st_nlink != 1
            or stat.S_IMODE(before.st_mode) & 0o022
            or before.st_size <= 0
            or before.st_size > max_provider_bytes
        ):
            return "unsafe", None
        flags = os.O_RDONLY
        flags |= getattr(os, "O_CLOEXEC", 0)
        flags |= getattr(os, "O_NOFOLLOW", 0)
        flags |= getattr(os, "O_NONBLOCK", 0)
        descriptor = os.open(provider_file, flags)
        opened = os.fstat(descriptor)
        if fingerprint(opened) != fingerprint(before):
            return "unsafe", None
        chunks = []
        remaining = max_provider_bytes + 1
        while remaining > 0:
            chunk = os.read(descriptor, min(remaining, 4096))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        payload = b"".join(chunks)
        after = os.fstat(descriptor)
        if fingerprint(after) != fingerprint(opened) or len(payload) > max_provider_bytes:
            return "unsafe", None
        text = payload.decode("utf-8")
    except (OSError, UnicodeDecodeError, ValueError):
        return "corrupt", None
    finally:
        if descriptor is not None:
            os.close(descriptor)

    values = {}
    for raw_line in text.splitlines():
        if not raw_line:
            continue
        if "=" not in raw_line:
            return "corrupt", None
        field_name, field_value = raw_line.split("=", 1)
        if field_name not in {"engine", "session"}:
            continue
        if field_name in values:
            return "corrupt", None
        values[field_name] = field_value
    engine = values.get("engine")
    if (
        values.get("session") != record["session_id"]
        or not isinstance(engine, str)
        or not provider_re.fullmatch(engine)
    ):
        return "corrupt", None
    return "valid", engine


def providers_match(runtime_provider, provider_engine):
    if runtime_provider == provider_engine:
        return True
    agent_engines = {
        "claude": {"claude", "anthropic-gateway"},
        "codex": {"codex-plugin"},
    }
    return provider_engine in agent_engines.get(runtime_provider, set())


if not records:
    print("info\tNo lifecycle sessions found.")
    raise SystemExit(0)

attention_count = 0
for record in records:
    session_id = record["session_id"]
    findings = []
    metadata_health = record.get("metadata_health")
    runtime_health = record.get("runtime_health")
    runtime_status = record.get("runtime_status")
    artifacts = set(record.get("artifacts") or [])
    provider_health, provider_engine = provider_artifact(record)

    if record.get("unsafe_artifacts"):
        findings.append(("error", "has unsafe lifecycle artifacts"))
    if record.get("consistency_issues"):
        findings.append(("error", "has inconsistent lifecycle records"))
    if metadata_health == "corrupt":
        findings.append(("error", "metadata is corrupt"))
    elif metadata_health == "missing" and not mutation_mode:
        findings.append(("warn", "has no trusted metadata record"))
    if "phase" in artifacts and record.get("phase") is None:
        findings.append(("error", "phase state is corrupt"))
    if "provider" in artifacts and record.get("provider") is None:
        findings.append(("error", "provider state is corrupt"))
    elif provider_health == "corrupt":
        findings.append(("error", "provider state is corrupt"))
    elif provider_health == "unsafe" and "provider" not in set(
        record.get("unsafe_artifacts") or []
    ):
        findings.append(("error", "provider state cannot be read safely"))
    elif provider_health == "valid" and not providers_match(
        record.get("provider"), provider_engine
    ):
        if runtime_status is not None and runtime_health != "corrupt":
            findings.append(("error", "runtime and provider state disagree"))
        else:
            findings.append(("error", "catalog and provider state disagree"))

    if runtime_health == "corrupt":
        findings.append(("error", "runtime record is corrupt"))
    elif runtime_health == "unverifiable":
        findings.append(("warn", "runtime owner cannot be verified on this host"))
    elif runtime_health == "legacy-unverifiable":
        findings.append(("warn", "has no verifiable runtime lease"))
    elif runtime_health == "dead" and runtime_status == "running":
        findings.append(("error", "runtime owner stopped while the lease was running"))
    elif runtime_health not in {"live", "dead"}:
        findings.append(("error", "has an unknown runtime health value"))
    if mutation_mode and (
        record.get("is_child")
        or record.get("lifecycle_state") != "active"
        or runtime_health != "live"
        or runtime_status != "running"
    ):
        findings.append(("error", "is not a verified live top-level session"))

    if not findings:
        print(f"ok\t{session_id}: Session structure is healthy")
        continue
    attention_count += 1
    for severity, finding in findings:
        print(f"{severity}\t{session_id}: {finding}")

if attention_count:
    print(
        f"warn\tSession diagnostics found {attention_count} "
        f"session(s) that need attention."
    )
    raise SystemExit(1)
print(f"ok\tSession diagnostics passed for {len(records)} session(s).")
PY
  then
    diagnostics_result=0
  else
    diagnostics_result=$?
  fi

  while IFS=$'\t' read -r severity message; do
    case "$severity" in
      ok) dx_ok "$message" ;;
      warn) dx_warn "$message" ;;
      error) dx_error "$message" ;;
      info) dx_info "$message" ;;
      *) dx_error "Session diagnostics returned malformed output." ;;
    esac
  done < "$diagnostics_file"
  return "$diagnostics_result"
}

__dx_sessions_list() {
  local include_children=0 all_repositories=0 seen_children=0 seen_all=0 argument
  local records_file collect_result
  while [[ $# -gt 0 ]]; do
    argument="$1"
    case "$argument" in
      --all)
        if [[ "$seen_all" -eq 1 ]]; then
          dx_error "dx sessions list accepts --all once."
          return 1
        fi
        all_repositories=1
        seen_all=1
        ;;
      --include-children)
        if [[ "$seen_children" -eq 1 ]]; then
          dx_error "dx sessions list accepts --include-children once."
          return 1
        fi
        include_children=1
        seen_children=1
        ;;
      -h|--help)
        usage
        return 0
        ;;
      *)
        dx_error "Unknown dx sessions list option: $argument"
        usage >&2
        return 1
        ;;
    esac
    shift
  done

  __dx_sessions_ensure_temp_dir || return 1
  records_file="$SESSIONS_TEMP_DIR/list-records"
  if [[ "$all_repositories" -eq 1 ]]; then
    if __dx_sessions_collect_global "$records_file" "$include_children"; then
      collect_result=0
    else
      collect_result=$?
    fi
  elif __dx_sessions_collect_current "$records_file" "$include_children"; then
    collect_result=0
  else
    collect_result=$?
  fi
  __dx_sessions_emit_list "$records_file" || return 1
  return "$collect_result"
}

__dx_sessions_show() {
  local selector_value="" include_children=0 seen_children=0 argument selected_record
  while [[ $# -gt 0 ]]; do
    argument="$1"
    case "$argument" in
      --include-children)
        if [[ "$seen_children" -eq 1 ]]; then
          dx_error "dx sessions show accepts --include-children once."
          return 1
        fi
        include_children=1
        seen_children=1
        ;;
      -h|--help)
        usage
        return 0
        ;;
      -*)
        dx_error "Unknown dx sessions show option: $argument"
        usage >&2
        return 1
        ;;
      *)
        if [[ -n "$selector_value" ]]; then
          dx_error "dx sessions show accepts one selector."
          return 1
        fi
        selector_value="$argument"
        ;;
    esac
    shift
  done
  if [[ -z "$selector_value" ]]; then
    dx_error "dx sessions show requires one selector."
    usage >&2
    return 1
  fi
  selected_record=$(__dx_sessions_select_current "$selector_value" "$include_children") \
    || return $?
  __dx_sessions_emit_show "$selected_record"
}

__dx_sessions_doctor() {
  local selector_value="" include_children=0 seen_children=0 argument
  local records_file selected_record collect_result
  while [[ $# -gt 0 ]]; do
    argument="$1"
    case "$argument" in
      --include-children)
        if [[ "$seen_children" -eq 1 ]]; then
          dx_error "dx sessions doctor accepts --include-children once."
          return 1
        fi
        include_children=1
        seen_children=1
        ;;
      -h|--help)
        usage
        return 0
        ;;
      -*)
        dx_error "Unknown dx sessions doctor option: $argument"
        usage >&2
        return 1
        ;;
      *)
        if [[ -n "$selector_value" ]]; then
          dx_error "dx sessions doctor accepts at most one selector."
          return 1
        fi
        selector_value="$argument"
        ;;
    esac
    shift
  done

  __dx_sessions_ensure_temp_dir || return 1
  records_file="$SESSIONS_TEMP_DIR/doctor-records"
  if [[ -n "$selector_value" ]]; then
    selected_record=$(__dx_sessions_select_current "$selector_value" "$include_children") \
      || return $?
    printf '%s\n' "$selected_record" > "$records_file"
  elif __dx_sessions_collect_current "$records_file" "$include_children"; then
    collect_result=0
  else
    collect_result=$?
    return "$collect_result"
  fi
  __dx_sessions_emit_doctor "$records_file"
}

__dx_sessions_mutation_target() {
  local selected_record="$1" mutation_action="$2" session_id
  local selected_file runtime_before_file runtime_after_file diagnostics_file
  local runtime_health
  __dx_sessions_ensure_temp_dir || return 1
  selected_file="$SESSIONS_TEMP_DIR/${mutation_action}-selected"
  runtime_before_file="$SESSIONS_TEMP_DIR/${mutation_action}-runtime-before"
  runtime_after_file="$SESSIONS_TEMP_DIR/${mutation_action}-runtime-after"
  diagnostics_file="$SESSIONS_TEMP_DIR/${mutation_action}-diagnostics"
  printf '%s\n' "$selected_record" > "$selected_file"

  if ! session_id=$(python3 - "$selected_file" <<'PY'
import json
import re
import sys

with open(sys.argv[1], "r", encoding="utf-8") as source:
    record = json.load(source)
session_id = record.get("session_id")
if (
    not isinstance(session_id, str)
    or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,179}", session_id)
    or record.get("is_child") is not False
):
    raise SystemExit(1)
print(session_id)
PY
  ); then
    dx_error "The selected catalog record is not a valid top-level session."
    return 1
  fi

  if ! __dx_sessions_emit_doctor "$selected_file" mutation \
    > "$diagnostics_file" 2>&1; then
    dx_error "Session '$session_id' cannot accept a ${mutation_action} request. Run 'dx sessions doctor session:${session_id}' for details."
    return 1
  fi
  if ! dx_session_runtime_read "$session_id" > "$runtime_before_file" 2>/dev/null; then
    dx_error "Session '$session_id' cannot accept a ${mutation_action} request because its runtime lease is unreadable."
    return 1
  fi
  runtime_health=$(dx_session_runtime_health "$session_id" 2>/dev/null || true)
  if ! dx_session_runtime_read "$session_id" > "$runtime_after_file" 2>/dev/null; then
    dx_error "Session '$session_id' cannot accept a ${mutation_action} request because its runtime lease changed."
    return 1
  fi

  if ! python3 - "$selected_file" "$runtime_before_file" \
    "$runtime_after_file" "$runtime_health" <<'PY'
import json
import os
import sys

with open(sys.argv[1], "r", encoding="utf-8") as source:
    selected = json.load(source)
with open(sys.argv[2], "r", encoding="utf-8") as source:
    runtime_before = json.load(source)
with open(sys.argv[3], "r", encoding="utf-8") as source:
    runtime_after = json.load(source)

if runtime_before != runtime_after or sys.argv[4] != "live":
    raise SystemExit(1)
if selected.get("runtime_health") != "live" or selected.get("runtime_status") != "running":
    raise SystemExit(1)
if runtime_after.get("status") != "running":
    raise SystemExit(1)
for selected_field, runtime_field in (
    ("session_id", "session_id"),
    ("provider", "provider"),
    ("runtime_pid", "pid"),
):
    if selected.get(selected_field) != runtime_after.get(runtime_field):
        raise SystemExit(1)
selected_workspace = selected.get("workspace")
runtime_workspace = runtime_after.get("workspace")
if (
    not isinstance(selected_workspace, str)
    or not isinstance(runtime_workspace, str)
    or not os.path.isabs(selected_workspace)
    or not os.path.isabs(runtime_workspace)
    or os.path.realpath(selected_workspace) != os.path.realpath(runtime_workspace)
):
    raise SystemExit(1)
PY
  then
    dx_error "Session '$session_id' cannot accept a ${mutation_action} request because its live runtime no longer matches the selected provider or workspace."
    return 1
  fi
  printf '%s\n' "$session_id"
}

__dx_sessions_mutate() {
  local mutation_action="$1" selector_value="" argument selected_record session_id
  local action_label
  shift
  while [[ $# -gt 0 ]]; do
    argument="$1"
    case "$argument" in
      -h|--help)
        usage
        return 0
        ;;
      --include-children)
        dx_error "dx sessions ${mutation_action} does not accept --include-children."
        return 1
        ;;
      -*)
        dx_error "Unknown dx sessions ${mutation_action} option: $argument"
        return 1
        ;;
      *)
        if [[ -n "$selector_value" ]]; then
          dx_error "dx sessions ${mutation_action} accepts one selector."
          return 1
        fi
        selector_value="$argument"
        ;;
    esac
    shift
  done
  if [[ -z "$selector_value" ]]; then
    dx_error "dx sessions ${mutation_action} requires one selector."
    usage >&2
    return 1
  fi

  selected_record=$(__dx_sessions_select_current "$selector_value" 0) || return $?
  session_id=$(__dx_sessions_mutation_target "$selected_record" "$mutation_action") \
    || return $?
  if ! bash "$DEX_DIR/bin/control.sh" --session "$session_id" "$mutation_action"; then
    dx_error "Could not publish the ${mutation_action} request for session '$session_id'."
    return 1
  fi
  case "$mutation_action" in
    pause) action_label="Pause" ;;
    cancel) action_label="Cancel" ;;
    *) return 1 ;;
  esac
  dx_done "${action_label} request accepted for session ${session_id}."
}

__dx_sessions_resume() {
  local selector_value="" argument
  while [[ $# -gt 0 ]]; do
    argument="$1"
    case "$argument" in
      -h|--help)
        usage
        return 0
        ;;
      --include-children)
        dx_error "dx sessions resume does not accept --include-children."
        return 1
        ;;
      -*)
        dx_error "Unknown dx sessions resume option: $argument"
        return 1
        ;;
      *)
        if [[ -n "$selector_value" ]]; then
          dx_error "dx sessions resume accepts one selector."
          return 1
        fi
        selector_value="$argument"
        ;;
    esac
    shift
  done
  if [[ -z "$selector_value" ]]; then
    dx_error "dx sessions resume requires one selector."
    usage >&2
    return 1
  fi
  if ! command -v zsh >/dev/null 2>&1; then
    dx_error "zsh is required to relaunch a Dex lifecycle."
    return 1
  fi

  # Invoke the private resume entrypoint directly. Routing back through
  # `dx sessions` would recurse through this Bash dispatcher.
  zsh -fc 'source "$1"; __dx_sessions_resume_selected "$2"' \
    dex-sessions-resume "$DEX_DIR/dx.sh" "$selector_value"
}

main() {
  local command_name="${1:-}"
  case "$command_name" in
    -h|--help|help)
      usage
      return 0
      ;;
    "")
      dx_error "dx sessions requires a command."
      usage >&2
      return 1
      ;;
  esac
  shift
  case "$command_name" in
    list) __dx_sessions_list "$@" ;;
    show) __dx_sessions_show "$@" ;;
    doctor) __dx_sessions_doctor "$@" ;;
    pause|cancel) __dx_sessions_mutate "$command_name" "$@" ;;
    resume) __dx_sessions_resume "$@" ;;
    *)
      dx_error "Unknown dx sessions command: $command_name"
      usage >&2
      return 1
      ;;
  esac
}

main "$@"
