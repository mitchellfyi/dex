# shellcheck shell=bash
# Dex shared review policy, state, result, and telemetry helpers.

dx_review_normalize_tier() {
  case "${1:-}" in
    small|light) printf '%s\n' "small" ;;
    normal|standard) printf '%s\n' "normal" ;;
    complex|thorough|high|high-risk) printf '%s\n' "complex" ;;
    *) return 1 ;;
  esac
}

dx_review_tier_profile() {
  local tier
  tier=$(dx_review_normalize_tier "${1:-}") || return 1
  case "$tier" in
    small) printf '%s\n' "light" ;;
    normal) printf '%s\n' "standard" ;;
    complex) printf '%s\n' "thorough" ;;
  esac
}

dx_review_tier_rank() {
  local tier
  tier=$(dx_review_normalize_tier "${1:-}") || return 1
  case "$tier" in
    small) printf '%s\n' "1" ;;
    normal) printf '%s\n' "2" ;;
    complex) printf '%s\n' "3" ;;
  esac
}


dx_review_is_positive_integer() {
  local value="${1:-}"
  case "$value" in
    ""|*[!0-9]*) return 1 ;;
  esac
  [[ "$value" == *[1-9]* ]] || return 1
  [[ ${#value} -le 18 ]]
}

dx_review_is_nonnegative_integer() {
  local value="${1:-}"
  case "$value" in
    ""|*[!0-9]*) return 1 ;;
  esac
  [[ ${#value} -le 18 ]]
}

dx_review_reason_codes_valid() {
  local value="${1:-}"
  [[ -n "$value" && ${#value} -le 200 ]] || return 1
  [[ "$value" =~ ^[a-z0-9][a-z0-9_-]*(,[a-z0-9][a-z0-9_-]*)*$ ]]
}

dx_review_assessment_reason_codes_valid() {
  local value="${1:-}" code
  dx_review_reason_codes_valid "$value" || return 1
  while [[ -n "$value" ]]; do
    code="${value%%,*}"
    case "$code" in
      localized-change|focused-verification|bounded-production-change|cross-module|public-contract|security-sensitive|data-migration|concurrency|shell-hooks-ci|deployment-packaging|broad-impact|uncertain-coverage) ;;
      *) return 1 ;;
    esac
    if [[ "$value" == *,* ]]; then
      value="${value#*,}"
    else
      value=""
    fi
  done
}

dx_review_tier_reason_codes_valid() {
  local requested_tier="${1:-}" value="${2:-}" tier code
  local has_localized=0 has_focused=0 has_bounded=0 has_complex=0
  tier=$(dx_review_normalize_tier "$requested_tier") || return 1
  dx_review_assessment_reason_codes_valid "$value" || return 1
  while [[ -n "$value" ]]; do
    code="${value%%,*}"
    case "$code" in
      localized-change) has_localized=1 ;;
      focused-verification) has_focused=1 ;;
      bounded-production-change) has_bounded=1 ;;
      cross-module|public-contract|security-sensitive|data-migration|concurrency|shell-hooks-ci|deployment-packaging|broad-impact|uncertain-coverage)
        has_complex=1
        ;;
    esac
    if [[ "$value" == *,* ]]; then
      value="${value#*,}"
    else
      value=""
    fi
  done

  case "$tier" in
    small)
      [[ $has_localized -eq 1 && $has_focused -eq 1 && $has_bounded -eq 0 && $has_complex -eq 0 ]]
      ;;
    normal)
      [[ $has_complex -eq 0 ]] &&
        [[ $has_bounded -eq 1 || $has_localized -eq 0 || $has_focused -eq 0 ]]
      ;;
    complex)
      [[ $has_complex -eq 1 ]]
      ;;
  esac
}

dx_review_selection_reason_codes_valid() {
  local tier="${1:-}" source="${2:-}" reason_codes="${3:-}"
  case "$source" in
    lifecycle-agent|lifecycle-assessor|standalone-assessor)
      dx_review_tier_reason_codes_valid "$tier" "$reason_codes"
      ;;
    environment)
      [[ "$reason_codes" == "operator-override" ]]
      ;;
    wave-escalation)
      [[ "$reason_codes" == "wave-escalation" ]]
      ;;
    deterministic-floor)
      dx_review_tier_reason_codes_valid "$tier" "$reason_codes"
      ;;
    *)
      return 1
      ;;
  esac
}

dx_review_parse_assessment_file() {
  local assessment_file="$1" expected_generation="${2:-}" parsed tier reason_codes
  [[ $# -eq 1 || $# -eq 2 ]] || return 2
  if [[ $# -eq 2 && ! "$expected_generation" =~ ^[0-9a-f]{32}$ ]]; then
    return 1
  fi
  [[ -f "$assessment_file" ]] || return 1
  parsed=$(python3 - "$assessment_file" "$expected_generation" <<'PY'
import json
import re
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        payload = json.load(handle)
except (OSError, UnicodeError, json.JSONDecodeError):
    raise SystemExit(1)

expected_generation = sys.argv[2]
expected_keys = {"tier", "reason_codes"}
if expected_generation:
    expected_keys.add("completion_generation")
if not isinstance(payload, dict) or set(payload) != expected_keys:
    raise SystemExit(1)
tier = payload["tier"]
reason_codes = payload["reason_codes"]
if not isinstance(tier, str) or not isinstance(reason_codes, str):
    raise SystemExit(1)
if expected_generation:
    generation = payload["completion_generation"]
    if (
        not isinstance(generation, str)
        or not re.fullmatch(r"[0-9a-f]{32}", generation)
        or generation != expected_generation
    ):
        raise SystemExit(1)
if "\t" in tier or "\n" in tier or "\t" in reason_codes or "\n" in reason_codes:
    raise SystemExit(1)
print(f"{tier}\t{reason_codes}")
PY
  ) || return 1
  IFS=$'\t' read -r tier reason_codes <<EOF
$parsed
EOF
  tier=$(dx_review_normalize_tier "$tier") || return 1
  dx_review_tier_reason_codes_valid "$tier" "$reason_codes" || return 1
  printf '%s\t%s\n' "$tier" "$reason_codes"
}

# Lifecycle review criteria are deliberately small, one-line JSON strings. The
# strict shape makes the approved requirements portable without turning a state
# file into an unbounded prompt or command channel.
dx_review_criteria_valid() {
  local criteria_file="$1"
  [[ -f "$criteria_file" ]] || return 1
  python3 - "$criteria_file" <<'PY'
import json
import os
import re
import sys

path = sys.argv[1]
try:
    size = os.path.getsize(path)
    if size < 1 or size > 65536:
        raise ValueError
    with open(path, "r", encoding="utf-8") as handle:
        payload = json.load(handle)
except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
    raise SystemExit(1)

required_keys = {
    "version",
    "source",
    "objectives",
    "acceptance_criteria",
    "verification_requirements",
}
if not isinstance(payload, dict) or set(payload) != required_keys:
    raise SystemExit(1)
if isinstance(payload["version"], bool) or payload["version"] != 1:
    raise SystemExit(1)
if not isinstance(payload["source"], str) or payload["source"] not in {"approved-plan", "headless-run-spec"}:
    raise SystemExit(1)

limits = {
    "objectives": 32,
    "acceptance_criteria": 64,
    "verification_requirements": 64,
}
for key, limit in limits.items():
    values = payload[key]
    if not isinstance(values, list) or not 1 <= len(values) <= limit:
        raise SystemExit(1)
    if any(not isinstance(value, str) for value in values):
        raise SystemExit(1)
    if len(values) != len(set(values)):
        raise SystemExit(1)
    for value in values:
        if not 1 <= len(value) <= 2000:
            raise SystemExit(1)
        if value != value.strip() or any(ord(char) < 32 or ord(char) == 127 for char in value):
            raise SystemExit(1)
        if value.casefold() in {"n/a", "na", "tbd", "todo", "placeholder"}:
            raise SystemExit(1)
        if re.fullmatch(r"<[^<>]+>", value):
            raise SystemExit(1)
PY
}

dx_review_criteria_hash() {
  local criteria_file="$1"
  dx_review_criteria_valid "$criteria_file" || return 1
  python3 - "$criteria_file" <<'PY'
import hashlib
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)
canonical = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
print(hashlib.sha256(canonical.encode("utf-8")).hexdigest())
PY
}

__dx_review_invalidate_criteria_authorization() {
  local session_id="$1" approval_mode="$2"
  command rm -f \
    "$(dx_review_selection_file "$session_id")" \
    "$(dx_review_state_file "$session_id")" \
    "$(dx_review_receipt_file "$session_id")" \
    "$(dx_findings_file "$session_id")" 2>/dev/null || return 1
  dx_review_ledger_reset "$session_id" || return 1
  if [[ "$approval_mode" == "reapproved" ]]; then
    command rm -f \
      "$(dx_complete_file "$session_id")" \
      "$(dx_phase_ready_file "$session_id" 2)" \
      "$(dx_phase_ready_file "$session_id" 3)" 2>/dev/null || return 1
  fi
}

dx_review_approve_criteria() {
  local session_id="$1" approval_mode="${2:-}" expected_previous="" expected_hash=""
  local criteria_file approval_file current_hash raw version revision approved_hash extra next_revision tmp_file
  [[ "$approval_mode" == "initial" || "$approval_mode" == "reapproved" ]] || return 1
  case "$approval_mode" in
    initial)
      [[ $# -eq 3 ]] || return 1
      expected_hash="$3"
      ;;
    reapproved)
      [[ $# -eq 4 ]] || return 1
      expected_previous="$3"
      expected_hash="$4"
      [[ "$expected_previous" =~ ^[a-f0-9]{64}$ ]] || return 1
      ;;
  esac
  [[ "$expected_hash" =~ ^[a-f0-9]{64}$ ]] || return 1
  criteria_file=$(dx_review_criteria_file "$session_id") || return 1
  approval_file=$(dx_review_criteria_approval_file "$session_id") || return 1
  current_hash=$(dx_review_criteria_hash "$criteria_file") || return 1
  [[ "$expected_hash" == "$current_hash" ]] || return 1

  next_revision=1
  if [[ -e "$approval_file" ]]; then
    raw=$(cat "$approval_file" 2>/dev/null) || return 1
    [[ "$raw" != *$'\n'* && "$raw" != *$'\r'* ]] || return 1
    IFS=$'\t' read -r version revision approved_hash extra <<EOF
$raw
EOF
    [[ "$version" == "1" && -z "$extra" ]] || return 1
    dx_review_is_positive_integer "$revision" || return 1
    [[ "$approved_hash" =~ ^[a-f0-9]{64}$ ]] || return 1
    if [[ "$approval_mode" == "reapproved" && "$approved_hash" != "$expected_previous" ]]; then
      return 1
    fi
    if [[ "$approved_hash" == "$current_hash" ]]; then
      if [[ "$approval_mode" == "reapproved" ]]; then
        __dx_review_invalidate_criteria_authorization "$session_id" "$approval_mode" || return 1
      fi
      printf '%s\n' "$current_hash"
      return 0
    fi
    [[ "$approval_mode" == "reapproved" ]] || return 1
    next_revision=$((10#$revision + 1))
    dx_review_is_positive_integer "$next_revision" || return 1
  elif [[ "$approval_mode" != "initial" ]]; then
    return 1
  fi

  __dx_review_invalidate_criteria_authorization "$session_id" "$approval_mode" || return 1
  mkdir -p "$(dirname "$approval_file")" || return 1
  tmp_file="${approval_file}.tmp.$$"
  if ! printf '1\t%s\t%s\n' "$next_revision" "$current_hash" > "$tmp_file" ||
     [[ "$(dx_review_criteria_hash "$criteria_file" 2>/dev/null)" != "$current_hash" ]] ||
     ! command mv -f "$tmp_file" "$approval_file"; then
    command rm -f "$tmp_file" 2>/dev/null || true
    return 1
  fi
  if [[ "$(dx_review_criteria_hash "$criteria_file" 2>/dev/null)" != "$current_hash" ]]; then
    return 1
  fi
  printf '%s\n' "$current_hash"
}

dx_review_read_criteria_approval() {
  local session_id="$1" criteria_file approval_file raw version revision approved_hash extra current_hash
  criteria_file=$(dx_review_criteria_file "$session_id") || return 1
  approval_file=$(dx_review_criteria_approval_file "$session_id") || return 1
  [[ -f "$approval_file" ]] || return 1
  raw=$(cat "$approval_file" 2>/dev/null) || return 1
  [[ "$raw" != *$'\n'* && "$raw" != *$'\r'* ]] || return 1
  IFS=$'\t' read -r version revision approved_hash extra <<EOF
$raw
EOF
  [[ "$version" == "1" && -z "$extra" ]] || return 1
  dx_review_is_positive_integer "$revision" || return 1
  [[ "$approved_hash" =~ ^[a-f0-9]{64}$ ]] || return 1
  current_hash=$(dx_review_criteria_hash "$criteria_file") || return 1
  [[ "$current_hash" == "$approved_hash" ]] || return 1
  printf '%s\n' "$approved_hash"
}

dx_review_criteria_binding_valid() {
  local binding="${1:-}"
  [[ "$binding" == "standalone" || "$binding" =~ ^[a-f0-9]{64}$ ]]
}

dx_review_policy_binding_valid() {
  local binding="${1:-}"
  [[ "$binding" =~ ^[a-f0-9]{64}$ ]]
}

dx_review_pass_id_valid() {
  local pass_id="${1:-}"
  [[ "$pass_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,179}$ ]]
}

dx_review_pass_binding() {
  local pass_id="${1:-}" fingerprint="${2:-}" criteria_binding="${3:-}" policy_binding="${4:-}"
  [[ $# -eq 4 ]] || return 1
  dx_review_pass_id_valid "$pass_id" || return 1
  [[ "$fingerprint" =~ ^[a-f0-9]{64}$ ]] || return 1
  dx_review_criteria_binding_valid "$criteria_binding" || return 1
  dx_review_policy_binding_valid "$policy_binding" || return 1
  DX_REVIEW_PASS_ID="$pass_id" \
  DX_REVIEW_PASS_FINGERPRINT="$fingerprint" \
  DX_REVIEW_PASS_CRITERIA_BINDING="$criteria_binding" \
  DX_REVIEW_PASS_POLICY_BINDING="$policy_binding" \
  python3 - <<'PY'
import hashlib
import json
import os

payload = [
    "dex-review-pass-v1",
    os.environ["DX_REVIEW_PASS_ID"],
    os.environ["DX_REVIEW_PASS_FINGERPRINT"],
    os.environ["DX_REVIEW_PASS_CRITERIA_BINDING"],
    os.environ["DX_REVIEW_PASS_POLICY_BINDING"],
]
canonical = json.dumps(payload, ensure_ascii=True, separators=(",", ":"))
print(hashlib.sha256(canonical.encode("ascii")).hexdigest())
PY
}

dx_review_sha256_stdin() {
  python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
}

# A deterministic baseline contains only project-wide command evidence. It is
# reusable while every supplied binding still matches and every command passed.
dx_review_baseline_valid() {
  [[ $# -eq 5 ]] || return 1
  local baseline_file="$1" expected_scope="$2" expected_working="$3"
  local expected_criteria="$4" expected_policy="$5"
  [[ "$expected_scope" =~ ^[a-f0-9]{64}$ ]] || return 1
  [[ "$expected_working" =~ ^[a-f0-9]{64}$ ]] || return 1
  dx_review_criteria_binding_valid "$expected_criteria" || return 1
  dx_review_policy_binding_valid "$expected_policy" || return 1
  __dx_review_regular_files_bounded 262144 "$baseline_file" || return 1
  DX_REVIEW_BASELINE_SCOPE="$expected_scope" \
  DX_REVIEW_BASELINE_WORKING="$expected_working" \
  DX_REVIEW_BASELINE_CRITERIA="$expected_criteria" \
  DX_REVIEW_BASELINE_POLICY="$expected_policy" \
  python3 - "$baseline_file" <<'PY'
import json
import os
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        payload = json.load(handle)
except (OSError, UnicodeError, json.JSONDecodeError):
    raise SystemExit(1)

required = {
    "version",
    "scope_fingerprint",
    "working_fingerprint",
    "criteria_binding",
    "policy_binding",
    "commands",
}
if (
    not isinstance(payload, dict)
    or set(payload) != required
    or isinstance(payload["version"], bool)
    or payload["version"] != 1
):
    raise SystemExit(1)
expected = {
    "scope_fingerprint": os.environ["DX_REVIEW_BASELINE_SCOPE"],
    "working_fingerprint": os.environ["DX_REVIEW_BASELINE_WORKING"],
    "criteria_binding": os.environ["DX_REVIEW_BASELINE_CRITERIA"],
    "policy_binding": os.environ["DX_REVIEW_BASELINE_POLICY"],
}
if any(payload[key] != value for key, value in expected.items()):
    raise SystemExit(1)
commands = payload["commands"]
if not isinstance(commands, list) or not 1 <= len(commands) <= 64:
    raise SystemExit(1)
for item in commands:
    if not isinstance(item, dict) or set(item) != {
        "name", "command", "status", "duration_seconds"
    }:
        raise SystemExit(1)
    name = item["name"]
    command = item["command"]
    duration = item["duration_seconds"]
    if (
        not isinstance(name, str)
        or not 1 <= len(name) <= 160
        or name != name.strip()
        or any(ord(char) < 32 or ord(char) == 127 for char in name)
        or not isinstance(command, str)
        or not 1 <= len(command) <= 4096
        or command != command.strip()
        or any(ord(char) < 32 or ord(char) == 127 for char in command)
        or item["status"] != "pass"
        or isinstance(duration, bool)
        or not isinstance(duration, int)
        or not 0 <= duration <= 999999999999999
    ):
        raise SystemExit(1)
PY
}

dx_review_baseline_hash() {
  [[ $# -eq 1 ]] || return 1
  local baseline_file="$1"
  __dx_review_regular_files_bounded 262144 "$baseline_file" || return 1
  python3 - "$baseline_file" <<'PY'
import hashlib
import sys

with open(sys.argv[1], "rb") as handle:
    print(hashlib.sha256(handle.read()).hexdigest())
PY
}

dx_review_baseline_summary() {
  [[ $# -eq 1 ]] || return 1
  local baseline_file="$1"
  __dx_review_regular_files_bounded 262144 "$baseline_file" || return 1
  python3 - "$baseline_file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    commands = json.load(handle)["commands"]
print(f"{len(commands)}\t{sum(item['duration_seconds'] for item in commands)}")
PY
}

# dx_review_baseline_write <file> <scope> <working> <criteria> <policy>
#   <name> <command> <duration> [<name> <command> <duration> ...]
# Build the baseline JSON in one trusted helper instead of asking an agent to
# hand-assemble the schema. The validator remains the final acceptance gate.
dx_review_baseline_write() {
  [[ $# -ge 8 && $((($# - 5) % 3)) -eq 0 ]] || return 1
  local baseline_file="$1" scope_fingerprint="$2" working_fingerprint="$3"
  local criteria_binding="$4" policy_binding="$5" payload
  shift 5
  [[ "$scope_fingerprint" =~ ^[a-f0-9]{64}$ \
    && "$working_fingerprint" =~ ^[a-f0-9]{64}$ ]] || return 1
  dx_review_criteria_binding_valid "$criteria_binding" || return 1
  dx_review_policy_binding_valid "$policy_binding" || return 1
  payload=$(DX_REVIEW_BASELINE_SCOPE="$scope_fingerprint" \
    DX_REVIEW_BASELINE_WORKING="$working_fingerprint" \
    DX_REVIEW_BASELINE_CRITERIA="$criteria_binding" \
    DX_REVIEW_BASELINE_POLICY="$policy_binding" \
    python3 - "$@" <<'PY'
import json
import os
import sys

arguments = sys.argv[1:]
commands = []
for offset in range(0, len(arguments), 3):
    name, command, raw_duration = arguments[offset:offset + 3]
    try:
        duration = int(raw_duration)
    except ValueError:
        raise SystemExit(1)
    if (
        not 1 <= len(name) <= 160
        or name != name.strip()
        or any(ord(char) < 32 or ord(char) == 127 for char in name)
        or not 1 <= len(command) <= 4096
        or command != command.strip()
        or any(ord(char) < 32 or ord(char) == 127 for char in command)
        or not 0 <= duration <= 999999999999999
    ):
        raise SystemExit(1)
    commands.append({
        "name": name,
        "command": command,
        "status": "pass",
        "duration_seconds": duration,
    })
if not 1 <= len(commands) <= 64:
    raise SystemExit(1)
payload = {
    "version": 1,
    "scope_fingerprint": os.environ["DX_REVIEW_BASELINE_SCOPE"],
    "working_fingerprint": os.environ["DX_REVIEW_BASELINE_WORKING"],
    "criteria_binding": os.environ["DX_REVIEW_BASELINE_CRITERIA"],
    "policy_binding": os.environ["DX_REVIEW_BASELINE_POLICY"],
    "commands": commands,
}
print(json.dumps(payload, sort_keys=True, separators=(",", ":")))
PY
  ) || return 1
  dx_review_write_atomic "$baseline_file" "$payload" || return 1
  dx_review_baseline_valid "$baseline_file" "$scope_fingerprint" \
    "$working_fingerprint" "$criteria_binding" "$policy_binding"
}

# dx_review_baseline_publish <session> <repo> <name> <command> <duration> [...]
# Publish final implementation evidence for the first review wave. Lifecycle
# sessions use their sealed criteria; standalone callers bind to `standalone`.
dx_review_baseline_publish() {
  [[ $# -ge 5 && $((($# - 2) % 3)) -eq 0 ]] || return 1
  local session_id="$1" repo_dir="$2" criteria_binding="standalone"
  local policy_record policy_small policy_normal policy_complex policy_binding
  local policy_ref policy_oid scope_fingerprint working_fingerprint baseline_file
  shift 2
  dx_session_id_valid "$session_id" || return 1
  [[ -d "$repo_dir" ]] || return 1
  criteria_binding=$(dx_review_read_criteria_approval "$session_id" \
    2>/dev/null || printf '%s\n' "standalone")
  dx_review_criteria_binding_valid "$criteria_binding" || return 1
  policy_record=$(dx_review_policy_resolve "$repo_dir") || return 1
  IFS=$'\t' read -r policy_small policy_normal policy_complex policy_binding \
    policy_ref policy_oid <<EOF
$policy_record
EOF
  : "$policy_small" "$policy_normal" "$policy_complex"
  dx_review_policy_provenance_valid "$policy_ref" "$policy_oid" || return 1
  scope_fingerprint=$(dx_review_scope_fingerprint "$repo_dir") || return 1
  working_fingerprint=$(dx_review_working_fingerprint "$repo_dir") || return 1
  baseline_file=$(dx_review_baseline_file "$session_id") || return 1
  dx_review_baseline_write "$baseline_file" "$scope_fingerprint" \
    "$working_fingerprint" "$criteria_binding" "$policy_binding" "$@"
}

dx_review_metrics_start() {
  [[ $# -eq 1 ]] || return 1
  local metrics_file="$1" payload
  payload=$(python3 - <<'PY'
import json
import time

print(json.dumps({
    "version": 2,
    "started_ms": time.time_ns() // 1_000_000,
    "finished_ms": None,
    "stages": [],
}, sort_keys=True, separators=(",", ":")))
PY
  ) || return 1
  dx_review_write_atomic "$metrics_file" "$payload"
}

dx_review_metrics_mark() {
  [[ $# -eq 2 ]] || return 1
  local metrics_file="$1" stage="$2" payload
  case "$stage" in
    context|checks|scout|verifier|fixes) ;;
    *) return 1 ;;
  esac
  __dx_review_regular_files_bounded 4096 "$metrics_file" || return 1
  payload=$(python3 - "$metrics_file" "$stage" <<'PY'
import json
import sys
import time

order = ["context", "checks", "scout", "verifier", "fixes"]
try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        payload = json.load(handle)
except (OSError, UnicodeError, json.JSONDecodeError):
    raise SystemExit(1)
stage = sys.argv[2]
if (
    not isinstance(payload, dict)
    or set(payload) != {"version", "started_ms", "finished_ms", "stages"}
    or payload["version"] != 2
    or payload["finished_ms"] is not None
    or isinstance(payload["started_ms"], bool)
    or not isinstance(payload["started_ms"], int)
    or not isinstance(payload["stages"], list)
):
    raise SystemExit(1)
stages = payload["stages"]
names = [item.get("stage") for item in stages if isinstance(item, dict)]
if len(names) != len(stages) or names != order[:len(names)]:
    raise SystemExit(1)
if names and names[-1] == stage:
    print(json.dumps(payload, sort_keys=True, separators=(",", ":")))
    raise SystemExit(0)
if len(names) >= len(order) or stage != order[len(names)]:
    raise SystemExit(1)
now_ms = max(time.time_ns() // 1_000_000, payload["started_ms"])
if stages:
    previous_ms = stages[-1].get("at_ms")
    if isinstance(previous_ms, bool) or not isinstance(previous_ms, int):
        raise SystemExit(1)
    now_ms = max(now_ms, previous_ms)
stages.append({"stage": stage, "at_ms": now_ms})
print(json.dumps(payload, sort_keys=True, separators=(",", ":")))
PY
  ) || return 1
  dx_review_write_atomic "$metrics_file" "$payload"
}

dx_review_metrics_finish() {
  [[ $# -eq 1 ]] || return 1
  local metrics_file="$1" payload version
  dx_review_metrics_valid "$metrics_file" unfinished || return 1
  version=$(python3 - "$metrics_file" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    print(json.load(handle)["version"])
PY
  ) || return 1
  [[ "$version" == "2" ]] || return 0
  payload=$(python3 - "$metrics_file" <<'PY'
import json
import sys
import time

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)
last_ms = payload["started_ms"]
if payload["stages"]:
    last_ms = payload["stages"][-1]["at_ms"]
payload["finished_ms"] = max(time.time_ns() // 1_000_000, last_ms)
print(json.dumps(payload, sort_keys=True, separators=(",", ":")))
PY
  ) || return 1
  dx_review_write_atomic "$metrics_file" "$payload"
}

dx_review_metrics_valid() {
  [[ $# -eq 1 || ( $# -eq 2 && "$2" == "unfinished" ) ]] || return 1
  local metrics_file="$1" allow_unfinished="${2:-}"
  __dx_review_regular_files_bounded 4096 "$metrics_file" || return 1
  DX_REVIEW_METRICS_ALLOW_UNFINISHED="$allow_unfinished" \
  python3 - "$metrics_file" <<'PY'
import json
import os
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        payload = json.load(handle)
except (OSError, UnicodeError, json.JSONDecodeError):
    raise SystemExit(1)

legacy_keys = {
    "version",
    "context_seconds",
    "checks_seconds",
    "scout_seconds",
    "verifier_seconds",
}
if not isinstance(payload, dict) or isinstance(payload.get("version"), bool):
    raise SystemExit(1)
if payload["version"] == 1:
    if set(payload) != legacy_keys:
        raise SystemExit(1)
    for key in legacy_keys - {"version"}:
        value = payload[key]
        if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= 86400:
            raise SystemExit(1)
    raise SystemExit(0)
if payload["version"] != 2 or set(payload) != {
    "version", "started_ms", "finished_ms", "stages"
}:
    raise SystemExit(1)
started_ms = payload["started_ms"]
finished_ms = payload["finished_ms"]
if isinstance(started_ms, bool) or not isinstance(started_ms, int) or started_ms < 0:
    raise SystemExit(1)
if finished_ms is None:
    if os.environ["DX_REVIEW_METRICS_ALLOW_UNFINISHED"] != "unfinished":
        raise SystemExit(1)
elif (
    isinstance(finished_ms, bool)
    or not isinstance(finished_ms, int)
    or finished_ms < started_ms
):
    raise SystemExit(1)
order = ["context", "checks", "scout", "verifier", "fixes"]
stages = payload["stages"]
if not isinstance(stages, list) or len(stages) > len(order):
    raise SystemExit(1)
previous_ms = started_ms
for index, item in enumerate(stages):
    if not isinstance(item, dict) or set(item) != {"stage", "at_ms"}:
        raise SystemExit(1)
    at_ms = item["at_ms"]
    if (
        item["stage"] != order[index]
        or isinstance(at_ms, bool)
        or not isinstance(at_ms, int)
        or at_ms < previous_ms
        or (finished_ms is not None and at_ms > finished_ms)
    ):
        raise SystemExit(1)
    previous_ms = at_ms
PY
}

dx_review_metrics_summary() {
  local metrics_file="$1"
  dx_review_metrics_valid "$metrics_file" || return 1
  python3 - "$metrics_file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)
if payload["version"] == 1:
    print("\t".join(str(payload[key]) for key in (
        "context_seconds",
        "checks_seconds",
        "scout_seconds",
        "verifier_seconds",
    )))
    raise SystemExit(0)
events = {item["stage"]: item["at_ms"] for item in payload["stages"]}
finished_ms = payload["finished_ms"]
boundaries = [
    events.get("context"),
    events.get("checks"),
    events.get("scout"),
    events.get("verifier"),
    events.get("fixes", finished_ms),
]
durations = []
for current, following in zip(boundaries, boundaries[1:]):
    durations.append(0 if current is None or following is None else max(0, (following - current) // 1000))
print("\t".join(str(value) for value in durations))
PY
}

dx_review_metrics_detailed_summary() {
  local metrics_file="$1"
  dx_review_metrics_valid "$metrics_file" || return 1
  python3 - "$metrics_file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)
if payload["version"] == 1:
    values = [payload[key] for key in (
        "context_seconds", "checks_seconds", "scout_seconds", "verifier_seconds"
    )]
    print("\t".join(str(value) for value in values + [0, "false", "agent-reported"]))
    raise SystemExit(0)
order = ["context", "checks", "scout", "verifier", "fixes"]
events = {item["stage"]: item["at_ms"] for item in payload["stages"]}
finished_ms = payload["finished_ms"]
durations = []
for index, stage in enumerate(order):
    current = events.get(stage)
    following = events.get(order[index + 1]) if index + 1 < len(order) else finished_ms
    durations.append(0 if current is None or following is None else max(0, (following - current) // 1000))
complete = all(stage in events for stage in order)
print("\t".join(str(value) for value in durations + [str(complete).lower(), "wrapper-clock"]))
PY
}

# Resolve an explicit criteria binding, or infer one for compatibility callers.
# A present-but-invalid criteria file is always an error.
dx_review_resolve_criteria_binding() {
  local session_id="$1" expected_binding="${2:-}" criteria_file approval_file current_hash
  criteria_file=$(dx_review_criteria_file "$session_id") || return 1
  approval_file=$(dx_review_criteria_approval_file "$session_id") || return 1
  if [[ -n "$expected_binding" ]]; then
    dx_review_criteria_binding_valid "$expected_binding" || return 1
    if [[ "$expected_binding" == "standalone" ]]; then
      [[ ! -e "$criteria_file" && ! -e "$approval_file" ]] || return 1
    else
      current_hash=$(dx_review_read_criteria_approval "$session_id") || return 1
      [[ "$current_hash" == "$expected_binding" ]] || return 1
    fi
    printf '%s\n' "$expected_binding"
    return 0
  fi
  if [[ -e "$criteria_file" ]]; then
    dx_review_read_criteria_approval "$session_id"
  elif [[ -e "$approval_file" ]]; then
    return 1
  else
    printf '%s\n' "standalone"
  fi
}

dx_review_criteria_coverage_json() {
  local binding="${1:-}" criteria_file="${2:-}"
  dx_review_criteria_binding_valid "$binding" || return 1
  if [[ "$binding" == "standalone" ]]; then
    [[ -z "$criteria_file" || ! -e "$criteria_file" ]] || return 1
    printf '%s\n' '{"acceptance_criteria":[],"objectives":[],"verification_requirements":[]}'
    return 0
  fi
  [[ -n "$criteria_file" ]] || return 1
  [[ "$(dx_review_criteria_hash "$criteria_file" 2>/dev/null)" == "$binding" ]] || return 1
  python3 - "$criteria_file" <<'PY'
import hashlib
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)

coverage = {}
for section in ("objectives", "acceptance_criteria", "verification_requirements"):
    coverage[section] = [
        hashlib.sha256(
            json.dumps([section, index, value], ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        ).hexdigest()
        for index, value in enumerate(payload[section])
    ]
print(json.dumps(coverage, sort_keys=True, separators=(",", ":")))
PY
}

dx_review_copy_criteria() {
  local source_file="$1" target_file="$2" expected_hash="$3" tmp_file
  [[ "$source_file" != "$target_file" && "$expected_hash" =~ ^[a-f0-9]{64}$ ]] || return 1
  [[ "$(dx_review_criteria_hash "$source_file" 2>/dev/null)" == "$expected_hash" ]] || return 1
  mkdir -p "$(dirname "$target_file")" || return 1
  tmp_file="${target_file}.tmp.$$"
  if ! command cp "$source_file" "$tmp_file" ||
     ! dx_review_criteria_valid "$tmp_file" ||
     [[ "$(dx_review_criteria_hash "$tmp_file" 2>/dev/null)" != "$expected_hash" ]] ||
     ! command mv -f "$tmp_file" "$target_file"; then
    command rm -f "$tmp_file" 2>/dev/null || true
    return 1
  fi
  [[ "$(dx_review_criteria_hash "$target_file" 2>/dev/null)" == "$expected_hash" ]]
}

dx_review_result_valid() {
  local result="${1:-}" reason=""
  [[ -n "$result" && "$result" != *$'\n'* && "$result" != *$'\r'* ]] || return 1
  case "$result" in
    CLEAN) return 0 ;;
    FINDINGS_FIXED:[1-9]*|FINDINGS:[1-9]*)
      dx_review_is_positive_integer "${result#*:}"
      return $?
      ;;
    BLOCKED:*) reason="${result#BLOCKED:}" ;;
    CHURN:*) reason="${result#CHURN:}" ;;
    ESCALATE:normal:*) reason="${result#ESCALATE:normal:}" ;;
    ESCALATE:complex:*) reason="${result#ESCALATE:complex:}" ;;
    ESCALATE_THOROUGH:*) reason="${result#ESCALATE_THOROUGH:}" ;;
    *) return 1 ;;
  esac
  dx_review_reason_codes_valid "$reason"
}

dx_review_result_kind() {
  local result="${1:-}"
  dx_review_result_valid "$result" || return 1
  case "$result" in
    CLEAN) printf '%s\n' "clean" ;;
    FINDINGS_FIXED:*) printf '%s\n' "findings_fixed" ;;
    FINDINGS:*) printf '%s\n' "findings" ;;
    BLOCKED:*) printf '%s\n' "blocked" ;;
    CHURN:*) printf '%s\n' "churn" ;;
    ESCALATE:*|ESCALATE_THOROUGH:*) printf '%s\n' "escalate" ;;
  esac
}

dx_review_result_count() {
  local result="${1:-}"
  case "$result" in
    FINDINGS_FIXED:*|FINDINGS:*) printf '%s\n' "${result#*:}" ;;
    *) printf '%s\n' "0" ;;
  esac
}

dx_review_escalation_tier() {
  local result="${1:-}"
  case "$result" in
    ESCALATE:normal:*) printf '%s\n' "normal" ;;
    ESCALATE:complex:*|ESCALATE_THOROUGH:*) printf '%s\n' "complex" ;;
    *) return 1 ;;
  esac
}

__dx_review_regular_files_bounded() {
  local maximum="$1"
  shift
  python3 - "$maximum" "$@" <<'PY'
import os
import stat
import sys

maximum = int(sys.argv[1])
try:
    for path in sys.argv[2:]:
        before = os.lstat(path)
        if not stat.S_ISREG(before.st_mode) or not 1 <= before.st_size <= maximum:
            raise ValueError
        descriptor = os.open(
            path,
            os.O_RDONLY
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_NONBLOCK", 0),
        )
        try:
            opened = os.fstat(descriptor)
            if (
                not stat.S_ISREG(opened.st_mode)
                or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)
            ):
                raise ValueError
        finally:
            os.close(descriptor)
except (OSError, ValueError):
    raise SystemExit(1)
PY
}

dx_review_evidence_valid() {
  [[ $# -eq 9 ]] || return 1
  local evidence_file="$1" result="$2" profile="$3" expected_fingerprint="$4"
  local expected_binding="$5" criteria_file="$6" pass_id="$7" policy_binding="$8" context_file="$9"
  local expected_pass_binding
  dx_review_result_valid "$result" || return 1
  [[ "$profile" == "light" || "$profile" == "standard" || "$profile" == "thorough" ]] || return 1
  [[ "$expected_fingerprint" =~ ^[a-f0-9]{64}$ ]] || return 1
  dx_review_criteria_binding_valid "$expected_binding" || return 1
  dx_review_policy_binding_valid "$policy_binding" || return 1
  dx_review_pass_id_valid "$pass_id" || return 1
  __dx_review_regular_files_bounded 262144 "$evidence_file" "$context_file" || return 1
  if [[ "$expected_binding" == "standalone" ]]; then
    [[ -z "$criteria_file" || ! -e "$criteria_file" ]] || return 1
  else
    [[ -n "$criteria_file" ]] || return 1
    [[ "$(dx_review_criteria_hash "$criteria_file" 2>/dev/null)" == "$expected_binding" ]] || return 1
  fi
  dx_review_context_valid "$context_file" "$expected_binding" || return 1
  expected_pass_binding=$(dx_review_pass_binding "$pass_id" "$expected_fingerprint" "$expected_binding" "$policy_binding") || return 1
  DX_REVIEW_EVIDENCE_RESULT="$result" \
  DX_REVIEW_EVIDENCE_PROFILE="$profile" \
  DX_REVIEW_EVIDENCE_FINGERPRINT="$expected_fingerprint" \
  DX_REVIEW_EVIDENCE_CRITERIA_BINDING="$expected_binding" \
  DX_REVIEW_EVIDENCE_CRITERIA_FILE="$criteria_file" \
  DX_REVIEW_EVIDENCE_POLICY_BINDING="$policy_binding" \
  DX_REVIEW_EVIDENCE_PASS_BINDING="$expected_pass_binding" \
  DX_REVIEW_EVIDENCE_CONTEXT_FILE="$context_file" \
  python3 - "$evidence_file" <<'PY'
import hashlib
import json
import os
import re
import stat
import sys


def read_regular(raw_path, maximum):
    before = os.lstat(raw_path)
    if not stat.S_ISREG(before.st_mode) or not 1 <= before.st_size <= maximum:
        raise ValueError
    descriptor = os.open(
        raw_path,
        os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0),
    )
    try:
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)
        ):
            raise ValueError
        chunks = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(65536, maximum + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > maximum:
                raise ValueError
        after = os.fstat(descriptor)
        if (
            (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
            != (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns)
            or total != opened.st_size
        ):
            raise ValueError
        return b"".join(chunks)
    finally:
        os.close(descriptor)


try:
    payload = json.loads(read_regular(sys.argv[1], 262144).decode("utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
    raise SystemExit(1)

required_keys = {
    "version",
    "scope_fingerprint",
    "criteria_binding",
    "policy_binding",
    "pass_binding",
    "criteria_evidence",
    "deterministic_checks",
    "coverage",
    "verifier",
    "verified_findings",
    "fixes_applied",
}
if not isinstance(payload, dict) or set(payload) != required_keys:
    raise SystemExit(1)
if isinstance(payload["version"], bool) or payload["version"] != 3:
    raise SystemExit(1)
if payload["scope_fingerprint"] != os.environ["DX_REVIEW_EVIDENCE_FINGERPRINT"]:
    raise SystemExit(1)
if payload["criteria_binding"] != os.environ["DX_REVIEW_EVIDENCE_CRITERIA_BINDING"]:
    raise SystemExit(1)
if payload["policy_binding"] != os.environ["DX_REVIEW_EVIDENCE_POLICY_BINDING"]:
    raise SystemExit(1)
if payload["pass_binding"] != os.environ["DX_REVIEW_EVIDENCE_PASS_BINDING"]:
    raise SystemExit(1)

sections = ("objectives", "acceptance_criteria", "verification_requirements")
binding = os.environ["DX_REVIEW_EVIDENCE_CRITERIA_BINDING"]
if binding == "standalone":
    expected_hashes = {section: [] for section in sections}
else:
    try:
        with open(os.environ["DX_REVIEW_EVIDENCE_CRITERIA_FILE"], "r", encoding="utf-8") as handle:
            criteria = json.load(handle)
    except (OSError, UnicodeError, json.JSONDecodeError):
        raise SystemExit(1)
    expected_hashes = {}
    for section in sections:
        expected_hashes[section] = [
            hashlib.sha256(
                json.dumps(
                    [section, index, value],
                    ensure_ascii=False,
                    separators=(",", ":"),
                ).encode("utf-8")
            ).hexdigest()
            for index, value in enumerate(criteria[section])
        ]

criteria_evidence = payload["criteria_evidence"]
if not isinstance(criteria_evidence, dict) or set(criteria_evidence) != set(sections):
    raise SystemExit(1)

marker_pattern = re.compile(
    r"criteria:(objectives|acceptance_criteria|verification_requirements):"
    r"([1-9][0-9]{0,2}):([a-z0-9][a-z0-9._-]{0,63})"
)
try:
    context_lines = read_regular(
        os.environ["DX_REVIEW_EVIDENCE_CONTEXT_FILE"], 262144
    ).decode("utf-8").splitlines()
except (OSError, UnicodeError, ValueError):
    raise SystemExit(1)

context_markers = {}
for line in context_lines:
    if not line.startswith("Evidence-Ref:"):
        continue
    parts = line.split(" | ", 2)
    if len(parts) != 3 or not parts[0].startswith("Evidence-Ref: "):
        raise SystemExit(1)
    marker = parts[0][len("Evidence-Ref: "):]
    kind = parts[1]
    detail = parts[2]
    if (
        line != f"Evidence-Ref: {marker} | {kind} | {detail}"
        or not marker_pattern.fullmatch(marker)
        or marker in context_markers
        or kind not in {"analysis", "command", "file", "test"}
        or not 12 <= len(detail) <= 500
        or detail != detail.strip()
        or "|" in detail
        or any(ord(char) < 32 or ord(char) == 127 for char in detail)
        or detail.casefold() in {"n/a", "none", "placeholder", "tbd", "todo"}
    ):
        raise SystemExit(1)
    context_markers[marker] = (kind, detail)

allowed_outcomes = {"met", "not_met", "blocked", "not_applicable"}
referenced_markers = set()
outcomes = []
for section in sections:
    entries = criteria_evidence[section]
    hashes = expected_hashes[section]
    if not isinstance(entries, list) or len(entries) != len(hashes):
        raise SystemExit(1)
    for index, (entry, expected_hash) in enumerate(zip(entries, hashes), start=1):
        if not isinstance(entry, dict) or set(entry) != {"item_hash", "outcome", "evidence_refs"}:
            raise SystemExit(1)
        if entry["item_hash"] != expected_hash:
            raise SystemExit(1)
        outcome = entry["outcome"]
        if not isinstance(outcome, str) or outcome not in allowed_outcomes:
            raise SystemExit(1)
        refs = entry["evidence_refs"]
        if not isinstance(refs, list) or not 1 <= len(refs) <= 8:
            raise SystemExit(1)
        if len(refs) != len(set(refs)):
            raise SystemExit(1)
        for ref in refs:
            if not isinstance(ref, str):
                raise SystemExit(1)
            match = marker_pattern.fullmatch(ref)
            if not match or match.group(1) != section or int(match.group(2)) != index:
                raise SystemExit(1)
            if ref not in context_markers:
                raise SystemExit(1)
            referenced_markers.add(ref)
        outcomes.append(outcome)

if set(context_markers) != referenced_markers:
    raise SystemExit(1)
if binding == "standalone" and context_markers:
    raise SystemExit(1)

if payload["deterministic_checks"] not in {"pass", "partial", "fail", "unavailable"}:
    raise SystemExit(1)
if payload["verifier"] not in {"pass", "fail", "not-run"}:
    raise SystemExit(1)
if not isinstance(payload["coverage"], list) or not payload["coverage"]:
    raise SystemExit(1)
allowed_domains = {
    "correctness",
    "security",
    "contracts",
    "tests",
    "architecture",
    "frontend",
    "devops",
    "performance",
    "observability",
}
coverage = payload["coverage"]
if any(not isinstance(item, str) or item not in allowed_domains for item in coverage):
    raise SystemExit(1)
if len(coverage) != len(set(coverage)):
    raise SystemExit(1)
for key in ("verified_findings", "fixes_applied"):
    value = payload[key]
    if isinstance(value, bool) or not isinstance(value, int) or value < 0 or value > 999999999999999999:
        raise SystemExit(1)

result = os.environ["DX_REVIEW_EVIDENCE_RESULT"]
profile = os.environ["DX_REVIEW_EVIDENCE_PROFILE"]
core = {"correctness", "security", "contracts", "tests", "architecture"}
all_domains = core | {"frontend", "devops", "performance", "observability"}

if result == "CLEAN":
    if payload["deterministic_checks"] != "pass" or payload["verifier"] != "pass":
        raise SystemExit(1)
    if payload["verified_findings"] != 0 or payload["fixes_applied"] != 0:
        raise SystemExit(1)
    if any(outcome != "met" for outcome in outcomes):
        raise SystemExit(1)
    required_coverage = all_domains if profile == "thorough" else core
    if not required_coverage.issubset(set(coverage)):
        raise SystemExit(1)
elif result.startswith("FINDINGS_FIXED:"):
    count = int(result.split(":", 1)[1])
    if payload["deterministic_checks"] != "pass" or payload["verifier"] != "pass":
        raise SystemExit(1)
    if payload["verified_findings"] != count or payload["fixes_applied"] != count:
        raise SystemExit(1)
    if any(outcome != "met" for outcome in outcomes):
        raise SystemExit(1)
    required_coverage = all_domains if profile == "thorough" else core
    if not required_coverage.issubset(set(coverage)):
        raise SystemExit(1)
elif result.startswith("FINDINGS:"):
    count = int(result.split(":", 1)[1])
    if payload["verified_findings"] != count or payload["fixes_applied"] > count:
        raise SystemExit(1)
    if binding != "standalone" and not any(outcome in {"not_met", "blocked"} for outcome in outcomes):
        raise SystemExit(1)
elif result.startswith("BLOCKED:"):
    if binding != "standalone" and "blocked" not in outcomes:
        raise SystemExit(1)
elif result.startswith("ESCALATE:") or result.startswith("ESCALATE_THOROUGH:"):
    if payload["verifier"] != "pass" or payload["fixes_applied"] != 0:
        raise SystemExit(1)
PY
}

dx_review_evidence_hash() {
  [[ $# -eq 1 ]] || return 1
  local evidence_file="$1"
  python3 - "$evidence_file" <<'PY'
import hashlib
import os
import stat
import sys

maximum = 262144
descriptor = None
try:
    no_follow = getattr(os, "O_NOFOLLOW", None)
    close_exec = getattr(os, "O_CLOEXEC", None)
    if no_follow is None or close_exec is None:
        raise ValueError
    before = os.lstat(sys.argv[1])
    if not stat.S_ISREG(before.st_mode) or not 1 <= before.st_size <= maximum:
        raise ValueError
    descriptor = os.open(
        sys.argv[1],
        os.O_RDONLY | no_follow | close_exec | getattr(os, "O_NONBLOCK", 0),
    )
    opened = os.fstat(descriptor)
    if (
        not stat.S_ISREG(opened.st_mode)
        or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)
        or not 1 <= opened.st_size <= maximum
    ):
        raise ValueError

    digest = hashlib.sha256()
    total = 0
    while True:
        chunk = os.read(descriptor, min(65536, maximum + 1 - total))
        if not chunk:
            break
        digest.update(chunk)
        total += len(chunk)
        if total > maximum:
            raise ValueError

    after = os.fstat(descriptor)
    if (
        (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
        != (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns)
        or total != opened.st_size
    ):
        raise ValueError
except (OSError, ValueError):
    raise SystemExit(1)
finally:
    if descriptor is not None:
        os.close(descriptor)

print(digest.hexdigest())
PY
}

dx_review_pass_attestation() {
  [[ $# -eq 6 ]] || return 1
  local evidence_file="$1" context_file="$2" result="$3" profile="$4"
  local findings_hash="$5" pass_binding="$6"
  [[ -f "$evidence_file" && ! -L "$evidence_file" ]] || return 1
  [[ -f "$context_file" && ! -L "$context_file" ]] || return 1
  dx_review_result_valid "$result" || return 1
  [[ "$profile" == "light" || "$profile" == "standard" || "$profile" == "thorough" ]] || return 1
  [[ "$findings_hash" =~ ^[a-f0-9]{16}$ ]] || return 1
  [[ "$pass_binding" =~ ^[a-f0-9]{64}$ ]] || return 1
  DX_REVIEW_ATTESTATION_RESULT="$result" \
  DX_REVIEW_ATTESTATION_PROFILE="$profile" \
  DX_REVIEW_ATTESTATION_FINDINGS="$findings_hash" \
  DX_REVIEW_ATTESTATION_PASS_BINDING="$pass_binding" \
    python3 - "$evidence_file" "$context_file" <<'PY'
import hashlib
import json
import os
import stat
import sys
from pathlib import Path


def content_hash(raw_path, maximum):
    path = Path(raw_path)
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode) or not 1 <= before.st_size <= maximum:
        raise ValueError
    descriptor = os.open(
        path,
        os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0),
    )
    try:
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)
        ):
            raise ValueError
        digest = hashlib.sha256()
        total = 0
        while True:
            chunk = os.read(descriptor, min(65536, maximum + 1 - total))
            if not chunk:
                break
            digest.update(chunk)
            total += len(chunk)
            if total > maximum:
                raise ValueError
        after = os.fstat(descriptor)
        if (
            (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
            != (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns)
            or total != opened.st_size
        ):
            raise ValueError
        return digest.hexdigest()
    finally:
        os.close(descriptor)


try:
    evidence_hash = content_hash(sys.argv[1], 262144)
    context_hash = content_hash(sys.argv[2], 262144)
except (OSError, ValueError):
    raise SystemExit(1)

payload = [
    "dex-review-attestation-v1",
    os.environ["DX_REVIEW_ATTESTATION_PASS_BINDING"],
    os.environ["DX_REVIEW_ATTESTATION_RESULT"],
    os.environ["DX_REVIEW_ATTESTATION_PROFILE"],
    os.environ["DX_REVIEW_ATTESTATION_FINDINGS"],
    evidence_hash,
    context_hash,
]
canonical = json.dumps(payload, ensure_ascii=True, separators=(",", ":"))
print(hashlib.sha256(canonical.encode("ascii")).hexdigest())
PY
}

dx_review_evidence_summary() {
  local evidence_file="$1"
  [[ -f "$evidence_file" ]] || return 1
  python3 - "$evidence_file" <<'PY'
import json
import os
import sys

try:
    if os.path.getsize(sys.argv[1]) > 262144:
        raise ValueError
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        payload = json.load(handle)
    checks = payload["deterministic_checks"]
    verifier = payload["verifier"]
    coverage = payload["coverage"]
    findings = payload["verified_findings"]
    fixes = payload["fixes_applied"]
except (OSError, UnicodeError, json.JSONDecodeError, KeyError, TypeError, ValueError):
    raise SystemExit(1)

if not isinstance(checks, str) or not isinstance(verifier, str):
    raise SystemExit(1)
if not isinstance(coverage, list) or any(not isinstance(item, str) for item in coverage):
    raise SystemExit(1)
if isinstance(findings, bool) or not isinstance(findings, int):
    raise SystemExit(1)
if isinstance(fixes, bool) or not isinstance(fixes, int):
    raise SystemExit(1)
print(f"{checks}\t{verifier}\t{','.join(coverage)}\t{findings}\t{fixes}")
PY
}

dx_review_result_reason() {
  local result="${1:-}"
  dx_review_result_valid "$result" || return 1
  case "$result" in
    BLOCKED:*|CHURN:*|ESCALATE_THOROUGH:*) printf '%s\n' "${result#*:}" ;;
    ESCALATE:normal:*|ESCALATE:complex:*) printf '%s\n' "${result#*:*:}" ;;
    *) printf '%s\n' "none" ;;
  esac
}

dx_review_scope_descriptor() {
  local repo_dir="${1:-$PWD}" repo_root default_branch candidate candidate_oid merge_base upstream ahead
  local fallback_ref="" fallback_oid="" fallback_merge_base=""
  repo_root=$(git -C "$repo_dir" rev-parse --show-toplevel 2>/dev/null) || return 1
  default_branch=$(dx_default_branch "$repo_root") || return 1
  candidate="origin/${default_branch}"

  if git -C "$repo_root" rev-parse --verify --quiet "${candidate}^{commit}" >/dev/null 2>&1; then
    candidate_oid=$(git -C "$repo_root" rev-parse --verify "${candidate}^{commit}" 2>/dev/null) || return 1
    merge_base=$(git -C "$repo_root" merge-base "$candidate_oid" HEAD 2>/dev/null || true)
    if [[ -n "$merge_base" ]]; then
      fallback_ref="$candidate"
      fallback_oid="$candidate_oid"
      fallback_merge_base="$merge_base"
      if ! git -C "$repo_root" diff --quiet "$merge_base" HEAD -- 2>/dev/null; then
        printf 'changes\t%s\t%s\t%s\n' "$candidate" "$candidate_oid" "$merge_base"
        return 0
      fi
    fi
  fi

  upstream=$(git -C "$repo_root" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
  if [[ -n "$upstream" ]]; then
    candidate_oid=$(git -C "$repo_root" rev-parse --verify "${upstream}^{commit}" 2>/dev/null || true)
    merge_base=$(git -C "$repo_root" merge-base "$candidate_oid" HEAD 2>/dev/null || true)
    ahead=$(git -C "$repo_root" rev-list --count "${upstream}..HEAD" 2>/dev/null || true)
    if [[ -z "$fallback_merge_base" && -n "$candidate_oid" && -n "$merge_base" && "$ahead" =~ ^[0-9]+$ && "$ahead" -gt 0 ]]; then
      printf 'changes\t%s\t%s\t%s\n' "$upstream" "$candidate_oid" "$merge_base"
      return 0
    fi
    if [[ -z "$fallback_merge_base" && -n "$candidate_oid" && -n "$merge_base" ]]; then
      fallback_ref="$upstream"
      fallback_oid="$candidate_oid"
      fallback_merge_base="$merge_base"
    fi
  fi

  # A local-only feature branch may have neither a remote-tracking default
  # branch nor an upstream. Compare it with the local default branch before
  # falling back to a whole-codebase review.
  candidate="$default_branch"
  if git -C "$repo_root" rev-parse --verify --quiet "${candidate}^{commit}" >/dev/null 2>&1; then
    candidate_oid=$(git -C "$repo_root" rev-parse --verify "${candidate}^{commit}" 2>/dev/null) || return 1
    merge_base=$(git -C "$repo_root" merge-base "$candidate_oid" HEAD 2>/dev/null || true)
    if [[ -n "$merge_base" && -z "$fallback_merge_base" ]]; then
      fallback_ref="$candidate"
      fallback_oid="$candidate_oid"
      fallback_merge_base="$merge_base"
      if ! git -C "$repo_root" diff --quiet "$merge_base" HEAD -- 2>/dev/null; then
        printf 'changes\t%s\t%s\t%s\n' "$candidate" "$candidate_oid" "$merge_base"
        return 0
      fi
    fi
  fi

  if [[ -n "$fallback_merge_base" ]]; then
    printf 'none\t%s\t%s\t%s\n' "$fallback_ref" "$fallback_oid" "$fallback_merge_base"
    return 0
  fi
  printf '%s\n' $'none\t-\t-\t-'
}

# dx_review_scope_minimum_tier <repo_dir> — deterministic safety floor
dx_review_scope_minimum_tier() {
  local repo_dir="${1:-$PWD}" descriptor
  descriptor=$(dx_review_scope_descriptor "$repo_dir") || return 1
  DX_REVIEW_REPO_DIR="$repo_dir" DX_REVIEW_SCOPE_DESCRIPTOR="$descriptor" python3 - <<'PY'
import os
import re
import subprocess
from pathlib import Path

requested = Path(os.environ["DX_REVIEW_REPO_DIR"]).resolve()
probe = subprocess.run(
    ["git", "-C", str(requested), "rev-parse", "--show-toplevel"],
    check=False,
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
)
if probe.returncode != 0:
    raise SystemExit(1)
root = Path(os.fsdecode(probe.stdout.rstrip(b"\n"))).resolve()


def git(*args):
    result = subprocess.run(
        ["git", "-C", str(root), *args],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    if result.returncode not in (0, 1):
        raise SystemExit(1)
    return result.stdout


mode, _symbolic_ref, _comparison_oid, merge_base = os.environ["DX_REVIEW_SCOPE_DESCRIPTOR"].split("\t")
paths = set()
if mode == "changes":
    paths.update(item for item in git("diff", "--name-only", "-z", merge_base, "HEAD", "--").split(b"\0") if item)
paths.update(item for item in git("diff", "--cached", "--name-only", "-z", "--").split(b"\0") if item)
paths.update(item for item in git("diff", "--name-only", "-z", "--").split(b"\0") if item)
paths.update(item for item in git("ls-files", "--others", "--exclude-standard", "-z").split(b"\0") if item)

if not paths:
    print("complex\tbroad-impact")
    raise SystemExit(0)

decoded = [os.fsdecode(path).replace("\\", "/").lower() for path in paths]


def matches(pattern):
    return any(re.search(pattern, path) for path in decoded)


if matches(r"(^|/)(auth|security|permissions?|secrets?|payments?)(/|[._-])"):
    print("complex\tsecurity-sensitive")
elif matches(r"(^|/)(migrations?|schemas?)(/|[._-])|\.sql$"):
    print("complex\tdata-migration")
elif matches(r"(^|/)(hooks?|guards?|\.github/workflows|\.gitlab-ci)(/|$)|(^|/)(ci|pipeline)[._-]"):
    print("complex\tshell-hooks-ci")
elif matches(r"(^|/)(deploy|deployment|packaging|docker|helm|terraform)(/|[._-])|(^|/)(install|release)\.sh$"):
    print("complex\tdeployment-packaging")
elif matches(r"(^|/)(bin/|dx\.sh$|settings\.json$)|(^|/)(cli|config)(/|[._-])"):
    print("complex\tpublic-contract")
elif matches(r"^lib/(review|session|provider|worktree|events|run-spec|factory)\.sh$"):
    print("complex\tcross-module")
elif len(paths) >= 10 or len({path.split("/", 1)[0] for path in decoded}) >= 4:
    print("complex\tbroad-impact")
else:
    print("small\tlocalized-change,focused-verification")
PY
}

__dx_review_fingerprint() {
  local repo_dir="${1:-$PWD}" fingerprint_mode="${2:-scope}" descriptor=""
  if [[ "$fingerprint_mode" == "scope" ]]; then
    descriptor=$(dx_review_scope_descriptor "$repo_dir") || return 1
  elif [[ "$fingerprint_mode" != "working" ]]; then
    return 1
  fi
  DX_REVIEW_REPO_DIR="$repo_dir" \
  DX_REVIEW_FINGERPRINT_MODE="$fingerprint_mode" \
  DX_REVIEW_SCOPE_DESCRIPTOR="$descriptor" \
  python3 - <<'PY'
import hashlib
import os
import stat
import subprocess
from pathlib import Path

requested_root = Path(os.environ["DX_REVIEW_REPO_DIR"]).resolve()

root_probe = subprocess.run(
    ["git", "-C", str(requested_root), "rev-parse", "--show-toplevel"],
    check=False,
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
)
if root_probe.returncode != 0:
    raise SystemExit(1)
root = Path(os.fsdecode(root_probe.stdout.rstrip(b"\n"))).resolve()


def git(*args, check=True):
    completed = subprocess.run(
        ["git", "-C", str(root), *args],
        check=check,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    return completed.stdout


if os.environ["DX_REVIEW_FINGERPRINT_MODE"] == "scope":
    descriptor = os.environ["DX_REVIEW_SCOPE_DESCRIPTOR"].split("\t")
    if len(descriptor) != 4:
        raise SystemExit(1)
    _scope_mode, comparison_ref, _comparison_oid, merge_base = descriptor
    current_ref = os.fsdecode(
        git("symbolic-ref", "--quiet", "--short", "HEAD", check=False).strip()
    )
    comparison_tree = b""
    if merge_base != "-" and comparison_ref != current_ref:
        comparison_tree = git(
            "rev-parse", "--verify", f"{merge_base}^{{tree}}", check=False
        ).strip()
        if not comparison_tree:
            raise SystemExit(1)

    def path_set(*arguments):
        return {item for item in git(*arguments).split(b"\0") if item}

    cached_paths = path_set(
        "diff", "--cached", "--name-only", "--no-renames", "-z", "--"
    )
    worktree_paths = path_set(
        "diff", "--name-only", "--no-renames", "-z", "--"
    )
    untracked_paths = path_set("ls-files", "--others", "--exclude-standard", "-z")

    # The index already carries stable blob IDs for clean and staged files.
    # Re-hash only paths whose final worktree content differs from the index.
    # This keeps fingerprints independent of staging/commit transitions while
    # avoiding a full checkout read on every review state validation.
    index_entries = {}
    for record in git("ls-files", "--stage", "-z").split(b"\0"):
        if not record:
            continue
        metadata, separator, raw_path = record.partition(b"\t")
        fields = metadata.split()
        if not separator or len(fields) != 3:
            raise SystemExit(1)
        file_mode, object_id, stage = fields
        if stage == b"0":
            index_entries[raw_path] = (file_mode, object_id)

    if comparison_tree:
        paths = path_set(
            "diff", "--name-only", "--no-renames", "-z", merge_base, "HEAD", "--"
        )
        paths.update(cached_paths)
        paths.update(worktree_paths)
        paths.update(untracked_paths)
    else:
        paths = set(index_entries)
        paths.update(untracked_paths)

    digest = hashlib.sha256()
    digest.update(b"SCOPE_CONTENT_V3\0")
    if comparison_tree:
        digest.update(b"COMPARISON_TREE\0" + comparison_tree + b"\0")
    else:
        digest.update(b"WHOLE_CODEBASE\0")

    for raw_path in sorted(paths):
        path = root / os.fsdecode(raw_path)
        if raw_path in index_entries and raw_path not in worktree_paths:
            file_mode, object_id = index_entries[raw_path]
            digest.update(
                b"PATH\0"
                + len(raw_path).to_bytes(8, "big")
                + raw_path
                + b"\0MODE\0"
                + file_mode
                + b"\0GIT_OBJECT\0"
                + object_id
            )
            continue
        try:
            metadata = path.lstat()
        except FileNotFoundError:
            digest.update(
                b"PATH\0"
                + len(raw_path).to_bytes(8, "big")
                + raw_path
                + b"\0MISSING\0"
            )
            continue
        except OSError:
            raise SystemExit(1)

        if stat.S_ISLNK(metadata.st_mode):
            file_mode = b"120000"
        elif stat.S_ISREG(metadata.st_mode):
            file_mode = b"100755" if metadata.st_mode & 0o111 else b"100644"
        elif stat.S_ISDIR(metadata.st_mode):
            submodule_head = subprocess.run(
                ["git", "-C", str(path), "rev-parse", "--verify", "HEAD"],
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
            ).stdout.strip()
            submodule_status = subprocess.run(
                ["git", "-C", str(path), "status", "--porcelain=v1", "-z"],
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
            ).stdout
            digest.update(
                b"\0MODE\0" + b"160000" + b"\0HEAD\0"
                + submodule_head
                + b"\0STATUS\0"
                + submodule_status
            )
            continue
        else:
            raise SystemExit(1)
        object_id = git(
            "hash-object", "--path", os.fsdecode(raw_path), os.fsdecode(raw_path),
            check=False,
        ).strip()
        if not object_id:
            raise SystemExit(1)
        digest.update(
            b"PATH\0"
            + len(raw_path).to_bytes(8, "big")
            + raw_path
            + b"\0MODE\0"
            + file_mode
            + b"\0GIT_OBJECT\0"
            + object_id
        )

    partial_paths = sorted(cached_paths & worktree_paths)
    if partial_paths:
        decoded_paths = [os.fsdecode(item) for item in partial_paths]
        digest.update(
            b"PARTIAL_INDEX\0"
            + git("diff", "--binary", "--cached", "--no-renames", "--", *decoded_paths)
            + b"\0PARTIAL_WORKTREE\0"
            + git("diff", "--binary", "--no-renames", "--", *decoded_paths)
        )

    print(digest.hexdigest())
    raise SystemExit(0)

digest = hashlib.sha256()
head = git("rev-parse", "--verify", "HEAD", check=False).strip()
if head:
    digest.update(b"FINAL_WORKTREE\0" + git("diff", "--binary", "HEAD", "--"))
else:
    digest.update(b"UNBORN_CACHED\0" + git("diff", "--binary", "--cached", "--"))
    digest.update(b"UNBORN_WORKTREE\0" + git("diff", "--binary", "--"))

untracked = [item for item in git("ls-files", "--others", "--exclude-standard", "-z").split(b"\0") if item]
for raw_path in sorted(untracked):
    path = root / os.fsdecode(raw_path)
    object_digest = hashlib.sha256()
    try:
        metadata = path.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            git_mode = b"120000"
            object_digest.update(os.fsencode(os.readlink(path)))
        elif stat.S_ISREG(metadata.st_mode):
            git_mode = b"100755" if metadata.st_mode & 0o111 else b"100644"
            with path.open("rb") as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    object_digest.update(chunk)
        else:
            git_mode = b"OTHER"
            object_digest.update(b"SPECIAL")
    except OSError:
        git_mode = b"UNREADABLE"
        object_digest.update(b"UNREADABLE")
    digest.update(
        b"UNTRACKED\0"
        + len(raw_path).to_bytes(8, "big")
        + raw_path
        + b"\0MODE\0"
        + git_mode
        + b"\0CONTENT_SHA256\0"
        + object_digest.digest()
    )

print(digest.hexdigest())
PY
}

dx_review_scope_fingerprint() {
  __dx_review_fingerprint "${1:-$PWD}" scope
}

dx_review_working_fingerprint() {
  __dx_review_fingerprint "${1:-$PWD}" working
}

dx_review_write_atomic() {
  local target="$1" content="$2" tmp_file
  mkdir -p "$(dirname "$target")" || return 1
  tmp_file=$(mktemp "${target}.tmp.XXXXXX") || return 1
  # >| because mktemp already created the file: a plain > is refused under the
  # user's `setopt noclobber`, which dx.sh inherits from the interactive zsh.
  if ! chmod 600 "$tmp_file" || ! printf '%s\n' "$content" >| "$tmp_file" ||
     ! command mv -f "$tmp_file" "$target"; then
    command rm -f "$tmp_file" 2>/dev/null || true
    return 1
  fi
}

dx_review_selection_revocation_file() {
  [[ $# -eq 1 ]] || return 1
  printf '%s.revoked\n' "$(dx_review_selection_file "$1")"
}

# Return success only when a path cannot contain a trusted private record.
# Schema-invalid but otherwise trusted files still count as live here: callers
# use this helper while revoking authorization, so uncertainty must stay inert.
__dx_review_private_record_authorization_absent() {
  [[ $# -eq 2 ]] || return 1
  local record_file="$1" maximum="$2"
  [[ -e "$record_file" || -L "$record_file" ]] || return 0
  ! __dx_review_read_private_record "$record_file" "$maximum" \
    >/dev/null 2>&1
}

# Remove one trusted private record, falling back to a verified mode change
# when its directory cannot be updated. Unsafe inodes are already rejected by
# the reader and are left in place for explicit repair.
__dx_review_invalidate_private_record() {
  [[ $# -eq 1 ]] || return 1
  local record_file="$1"
  python3 - "$record_file" <<'PY'
import os
import stat
import sys

target = sys.argv[1]
try:
    before = os.lstat(target)
except FileNotFoundError:
    raise SystemExit(0)
except OSError:
    raise SystemExit(1)

if (
    not stat.S_ISREG(before.st_mode)
    or before.st_uid != os.geteuid()
    or stat.S_IMODE(before.st_mode) != 0o600
):
    raise SystemExit(0)

flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NONBLOCK", 0)
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
try:
    descriptor = os.open(target, flags)
except OSError:
    raise SystemExit(1)
try:
    opened = os.fstat(descriptor)
    if (
        not stat.S_ISREG(opened.st_mode)
        or opened.st_uid != os.geteuid()
        or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)
    ):
        raise SystemExit(1)
    try:
        os.unlink(target)
    except OSError:
        os.fchmod(descriptor, 0)
        invalidated = os.fstat(descriptor)
        if stat.S_IMODE(invalidated.st_mode) == 0o600:
            raise SystemExit(1)
finally:
    os.close(descriptor)
PY
}

dx_review_selection_authorization_absent() {
  [[ $# -eq 1 ]] || return 1
  local selection_file
  selection_file=$(dx_review_selection_file "$1") || return 1
  __dx_review_private_record_authorization_absent "$selection_file" 4096
}

dx_review_selection_authorization_revoked() {
  [[ $# -eq 1 ]] || return 1
  local revocation_file
  revocation_file=$(dx_review_selection_revocation_file "$1") || return 1
  if [[ -e "$revocation_file" || -L "$revocation_file" ]]; then
    return 0
  fi
  dx_review_selection_authorization_absent "$1"
}

dx_review_revoke_selection() {
  [[ $# -eq 1 ]] || return 1
  local session_id="$1" selection_file revocation_file
  selection_file=$(dx_review_selection_file "$session_id") || return 1
  revocation_file=$(dx_review_selection_revocation_file "$session_id") \
    || return 1
  dx_review_write_atomic "$revocation_file" revoked 2>/dev/null || true
  if [[ ! -e "$revocation_file" && ! -L "$revocation_file" ]]; then
    __dx_review_invalidate_private_record "$selection_file" \
      2>/dev/null || return 1
  fi
  dx_review_selection_authorization_revoked "$session_id"
}

dx_review_write_selection() {
  local session_id="$1" requested_tier="$2" source="$3" reason_codes="$4" repo_dir="${5:-$PWD}"
  local required_clean="${6:-}" tier tier_min fingerprint selection_file floor_record floor_tier floor_reason tier_rank floor_rank
  local expected_binding="${7:-}" expected_policy_binding="${8:-}" criteria_binding policy_record policy_binding override_binding
  local revocation_file
  [[ -n "$session_id" && "$source" =~ ^[a-z][a-z0-9_-]*$ ]] || return 1
  tier=$(dx_review_normalize_tier "$requested_tier") || return 1
  dx_review_selection_reason_codes_valid "$tier" "$source" "$reason_codes" || return 1
  if [[ "$source" != "environment" && "$source" != "wave-escalation" ]]; then
    floor_record=$(dx_review_scope_minimum_tier "$repo_dir") || return 1
    IFS=$'\t' read -r floor_tier floor_reason <<EOF
$floor_record
EOF
    : "$floor_reason"
    tier_rank=$(dx_review_tier_rank "$tier") || return 1
    floor_rank=$(dx_review_tier_rank "$floor_tier") || return 1
    [[ "$tier_rank" -ge "$floor_rank" ]] || return 1
  fi
  policy_record=$(dx_review_policy_for_tier "$repo_dir" "$tier" "$expected_policy_binding") || return 1
  IFS=$'\t' read -r tier_min policy_binding _ <<EOF
$policy_record
EOF
  [[ -n "$required_clean" ]] || required_clean="$tier_min"
  dx_review_is_positive_integer "$required_clean" || return 1
  if [[ $((10#$required_clean)) -lt $((10#$tier_min)) ]]; then
    override_binding=$(dx_override_binding "$session_id" review.clean-passes \
      "$required_clean" 3) || return 1
  else
    override_binding="-"
  fi
  fingerprint=$(dx_review_scope_fingerprint "$repo_dir") || return 1
  selection_file=$(dx_review_selection_file "$session_id") || return 1
  revocation_file=$(dx_review_selection_revocation_file "$session_id") \
    || return 1
  criteria_binding=$(dx_review_resolve_criteria_binding "$session_id" "$expected_binding") || return 1
  case "$source" in
    lifecycle-agent|lifecycle-assessor)
      [[ "$criteria_binding" != "standalone" ]] || return 1
      ;;
    standalone-assessor)
      [[ "$criteria_binding" == "standalone" ]] || return 1
      ;;
  esac
  dx_review_write_atomic "$selection_file" "5"$'\t'"${tier}"$'\t'"${source}"$'\t'"${reason_codes}"$'\t'"${required_clean}"$'\t'"${fingerprint}"$'\t'"${criteria_binding}"$'\t'"${policy_binding}"$'\t'"${override_binding}" \
    || return 1
  rm -f "$revocation_file" 2>/dev/null || return 1
  [[ ! -e "$revocation_file" && ! -L "$revocation_file" ]]
}

dx_review_read_selection() {
  local session_id="$1" repo_dir="${2:-$PWD}" expected_binding="${3:-}" expected_policy_binding="${4:-}" selection_file raw
  local version tier source reason_codes required_clean fingerprint criteria_binding policy_binding override_binding extra current_fingerprint tier_min
  local floor_record floor_tier floor_reason tier_rank floor_rank
  local current_binding policy_record current_policy_binding
  selection_file=$(dx_review_selection_file "$session_id") || return 1
  [[ ! -e "$(dx_review_selection_revocation_file "$session_id")" \
    && ! -L "$(dx_review_selection_revocation_file "$session_id")" ]] \
    || return 1
  raw=$(__dx_review_read_private_record "$selection_file" 4096) || return 1
  [[ "$raw" != *$'\n'* && "$raw" != *$'\r'* ]] || return 1
  IFS=$'\t' read -r version tier source reason_codes required_clean fingerprint criteria_binding policy_binding override_binding extra <<EOF
$raw
EOF
  [[ "$version" == "5" ]] || return 1
  [[ -z "$extra" ]] || return 1
  tier=$(dx_review_normalize_tier "$tier") || return 1
  [[ "$source" =~ ^[a-z][a-z0-9_-]*$ ]] || return 1
  dx_review_selection_reason_codes_valid "$tier" "$source" "$reason_codes" || return 1
  if [[ "$source" != "environment" && "$source" != "wave-escalation" ]]; then
    floor_record=$(dx_review_scope_minimum_tier "$repo_dir") || return 1
    IFS=$'\t' read -r floor_tier floor_reason <<EOF
$floor_record
EOF
    : "$floor_reason"
    tier_rank=$(dx_review_tier_rank "$tier") || return 1
    floor_rank=$(dx_review_tier_rank "$floor_tier") || return 1
    [[ "$tier_rank" -ge "$floor_rank" ]] || return 1
  fi
  policy_record=$(dx_review_policy_for_tier "$repo_dir" "$tier" "$expected_policy_binding") || return 1
  IFS=$'\t' read -r tier_min current_policy_binding _ <<EOF
$policy_record
EOF
  dx_review_policy_binding_valid "$policy_binding" || return 1
  [[ "$policy_binding" == "$current_policy_binding" ]] || return 1
  dx_review_is_positive_integer "$required_clean" || return 1
  if [[ $((10#$required_clean)) -lt $((10#$tier_min)) ]]; then
    [[ "$override_binding" =~ ^[a-f0-9]{64}$ ]] || return 1
    [[ "$override_binding" == "$(dx_override_binding "$session_id" \
      review.clean-passes "$required_clean" 3)" ]] || return 1
  else
    [[ "$override_binding" == "-" ]] || return 1
  fi
  [[ "$fingerprint" =~ ^[a-f0-9]{64}$ ]] || return 1
  current_fingerprint=$(dx_review_scope_fingerprint "$repo_dir") || return 1
  [[ "$current_fingerprint" == "$fingerprint" ]] || return 1
  dx_review_criteria_binding_valid "$criteria_binding" || return 1
  current_binding=$(dx_review_resolve_criteria_binding "$session_id" "$expected_binding") || return 1
  [[ "$current_binding" == "$criteria_binding" ]] || return 1
  case "$source" in
    lifecycle-agent|lifecycle-assessor)
      [[ "$criteria_binding" != "standalone" ]] || return 1
      ;;
    standalone-assessor)
      [[ "$criteria_binding" == "standalone" ]] || return 1
      ;;
  esac
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$tier" "$source" "$reason_codes" "$required_clean" "$fingerprint" "$criteria_binding" "$policy_binding"
}

dx_review_selection_valid() {
  dx_review_read_selection "$@" >/dev/null
}

dx_review_write_state() {
  local session_id="$1" requested_tier="$2" required_clean="$3" iteration="$4" clean_count="$5" repo_dir="${6:-$PWD}"
  local expected_binding="${7:-}" expected_policy_binding="${8:-}" tier tier_min fingerprint state_file criteria_binding
  local policy_record policy_binding override_binding
  tier=$(dx_review_normalize_tier "$requested_tier") || return 1
  dx_review_is_positive_integer "$required_clean" || return 1
  dx_review_is_nonnegative_integer "$iteration" || return 1
  dx_review_is_nonnegative_integer "$clean_count" || return 1
  policy_record=$(dx_review_policy_for_tier "$repo_dir" "$tier" "$expected_policy_binding") || return 1
  IFS=$'\t' read -r tier_min policy_binding _ <<EOF
$policy_record
EOF
  if [[ $((10#$required_clean)) -lt $((10#$tier_min)) ]]; then
    override_binding=$(dx_override_binding "$session_id" review.clean-passes \
      "$required_clean" 3) || return 1
  else
    override_binding="-"
  fi
  [[ $((10#$clean_count)) -lt $((10#$required_clean)) ]] || return 1
  [[ $((10#$clean_count)) -le $((10#$iteration)) ]] || return 1
  fingerprint=$(dx_review_scope_fingerprint "$repo_dir") || return 1
  criteria_binding=$(dx_review_resolve_criteria_binding "$session_id" "$expected_binding") || return 1
  state_file=$(dx_review_state_file "$session_id") || return 1
  dx_review_write_atomic "$state_file" "4"$'\t'"${tier}"$'\t'"${required_clean}"$'\t'"${iteration}"$'\t'"${clean_count}"$'\t'"${fingerprint}"$'\t'"${criteria_binding}"$'\t'"${policy_binding}"$'\t'"${override_binding}"
}

dx_review_read_state() {
  local session_id="$1" repo_dir="${2:-$PWD}" expected_binding="${3:-}" expected_policy_binding="${4:-}" state_file raw
  local version tier tier_min required_clean iteration clean_count fingerprint criteria_binding policy_binding override_binding extra current_fingerprint current_binding
  local policy_record current_policy_binding
  state_file=$(dx_review_state_file "$session_id") || return 1
  [[ -f "$state_file" ]] || return 1
  raw=$(cat "$state_file" 2>/dev/null) || return 1
  [[ "$raw" != *$'\n'* && "$raw" != *$'\r'* ]] || return 1
  IFS=$'\t' read -r version tier required_clean iteration clean_count fingerprint criteria_binding policy_binding override_binding extra <<EOF
$raw
EOF
  [[ "$version" == "4" ]] || return 1
  [[ -z "$extra" ]] || return 1
  tier=$(dx_review_normalize_tier "$tier") || return 1
  dx_review_is_positive_integer "$required_clean" || return 1
  dx_review_is_nonnegative_integer "$iteration" || return 1
  dx_review_is_nonnegative_integer "$clean_count" || return 1
  policy_record=$(dx_review_policy_for_tier "$repo_dir" "$tier" "$expected_policy_binding") || return 1
  IFS=$'\t' read -r tier_min current_policy_binding _ <<EOF
$policy_record
EOF
  dx_review_policy_binding_valid "$policy_binding" || return 1
  [[ "$policy_binding" == "$current_policy_binding" ]] || return 1
  if [[ $((10#$required_clean)) -lt $((10#$tier_min)) ]]; then
    [[ "$override_binding" =~ ^[a-f0-9]{64}$ ]] || return 1
    [[ "$override_binding" == "$(dx_override_binding "$session_id" \
      review.clean-passes "$required_clean" 3)" ]] || return 1
  else
    [[ "$override_binding" == "-" ]] || return 1
  fi
  [[ $((10#$clean_count)) -lt $((10#$required_clean)) ]] || return 1
  [[ $((10#$clean_count)) -le $((10#$iteration)) ]] || return 1
  [[ "$fingerprint" =~ ^[a-f0-9]{64}$ ]] || return 1
  current_fingerprint=$(dx_review_scope_fingerprint "$repo_dir") || return 1
  [[ "$current_fingerprint" == "$fingerprint" ]] || return 1
  dx_review_criteria_binding_valid "$criteria_binding" || return 1
  current_binding=$(dx_review_resolve_criteria_binding "$session_id" "$expected_binding") || return 1
  [[ "$current_binding" == "$criteria_binding" ]] || return 1
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$tier" "$required_clean" "$iteration" "$clean_count" "$fingerprint" "$criteria_binding" "$policy_binding"
}

# Private retained evidence for every clean row in the parent session ledger.
dx_review_proof_dir() {
  local session_id="$1"
  dx_session_id_valid "$session_id" || return 1
  printf '%s/%s.review-proofs\n' "$DX_LOOP_DIR" "$session_id"
}

__dx_review_remove_proof_path() {
  local target="$1"
  DX_REVIEW_PROOF_REMOVE_TARGET="$target" python3 - <<'PY'
import os
import shutil
import stat
from pathlib import Path

target = Path(os.environ["DX_REVIEW_PROOF_REMOVE_TARGET"])
try:
    metadata = target.lstat()
except FileNotFoundError:
    raise SystemExit(0)
except OSError:
    raise SystemExit(1)

try:
    if stat.S_ISDIR(metadata.st_mode):
        for root, directories, _ in os.walk(target, topdown=True, followlinks=False):
            os.chmod(root, 0o700, follow_symlinks=False)
            for name in directories:
                candidate = Path(root) / name
                if candidate.is_symlink():
                    candidate.unlink()
        shutil.rmtree(target)
    else:
        target.unlink()
except OSError:
    raise SystemExit(1)
PY
}

__dx_review_retain_proof() {
  local session_id="$1" iteration="$2" evidence_file="$3" context_file="$4" proof_dir
  proof_dir=$(dx_review_proof_dir "$session_id") || return 1
  mkdir -p "$DX_LOOP_DIR" || return 1
  DX_REVIEW_PROOF_ROOT="$proof_dir" \
  DX_REVIEW_PROOF_ITERATION="$iteration" \
  DX_REVIEW_PROOF_EVIDENCE_SOURCE="$evidence_file" \
  DX_REVIEW_PROOF_CONTEXT_SOURCE="$context_file" \
    python3 - <<'PY'
import os
import stat
from pathlib import Path

maximum = 262144
root = Path(os.environ["DX_REVIEW_PROOF_ROOT"])
iteration = os.environ["DX_REVIEW_PROOF_ITERATION"]
sources = {
    "evidence.json": Path(os.environ["DX_REVIEW_PROOF_EVIDENCE_SOURCE"]),
    "context.md": Path(os.environ["DX_REVIEW_PROOF_CONTEXT_SOURCE"]),
}


def remove_partial(path):
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        return
    if not stat.S_ISDIR(metadata.st_mode):
        path.unlink()
        return
    os.chmod(path, 0o700, follow_symlinks=False)
    for child in path.iterdir():
        child.unlink()
    path.rmdir()


def read_source(path):
    before = path.lstat()
    if (
        not stat.S_ISREG(before.st_mode)
        or not 1 <= before.st_size <= maximum
        or before.st_uid != os.geteuid()
        or stat.S_IMODE(before.st_mode) & 0o022
    ):
        raise ValueError
    descriptor = os.open(
        path,
        os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0),
    )
    try:
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)
        ):
            raise ValueError
        chunks = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(65536, maximum + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > maximum:
                raise ValueError
        after = os.fstat(descriptor)
        if (
            (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
            != (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns)
            or total != opened.st_size
        ):
            raise ValueError
        return b"".join(chunks)
    finally:
        os.close(descriptor)


try:
    parent_metadata = root.parent.lstat()
    if (
        not stat.S_ISDIR(parent_metadata.st_mode)
        or parent_metadata.st_uid != os.geteuid()
        or stat.S_IMODE(parent_metadata.st_mode) & 0o022
    ):
        raise ValueError
    try:
        root_metadata = root.lstat()
    except FileNotFoundError:
        root.mkdir(mode=0o700)
        root_metadata = root.lstat()
    if (
        not stat.S_ISDIR(root_metadata.st_mode)
        or root_metadata.st_uid != os.geteuid()
        or stat.S_IMODE(root_metadata.st_mode) != 0o700
    ):
        raise ValueError

    # Publish the proof atomically. Receipt validation requires each pass
    # directory to be mode 0500 and to contain exactly evidence.json and
    # context.md, and it also requires the proof root to contain exactly the
    # expected iterations. Building in place exposes a window in which a
    # concurrent validator — the Stop hook runs while the loop waits — sees a
    # 0700 directory or a half-written file set and rejects the receipt.
    # Staging outside the root and renaming in means a validator sees either
    # nothing or the finished directory.
    target = root / iteration
    staging = root.parent / ".{}.{}.staging.{}".format(root.name, iteration, os.getpid())
    remove_partial(staging)
    staging.mkdir(mode=0o700)
    try:
        for name, source in sources.items():
            content = read_source(source)
            destination = staging / name
            descriptor = os.open(
                destination,
                os.O_WRONLY
                | os.O_CREAT
                | os.O_EXCL
                | getattr(os, "O_NOFOLLOW", 0),
                0o600,
            )
            try:
                view = memoryview(content)
                while view:
                    written = os.write(descriptor, view)
                    if written <= 0:
                        raise OSError
                    view = view[written:]
                os.fsync(descriptor)
                os.fchmod(descriptor, 0o400)
            finally:
                os.close(descriptor)
        # Publish first, then seal. Renaming a directory needs write access
        # on the directory itself, so the 0500 chmod has to come after the
        # rename. The exposure left is two adjacent syscalls rather than the
        # whole write, and a validator that catches it sees complete contents.
        os.rename(staging, target)
        os.chmod(target, 0o500, follow_symlinks=False)
        root_descriptor = os.open(
            root,
            os.O_RDONLY
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0),
        )
        try:
            os.fsync(root_descriptor)
        finally:
            os.close(root_descriptor)
    except Exception:
        remove_partial(staging)
        raise
except (OSError, ValueError):
    raise SystemExit(1)
PY
}

__dx_review_remove_proof_pass() {
  local session_id="$1" iteration="$2" proof_dir
  proof_dir=$(dx_review_proof_dir "$session_id") || return 1
  __dx_review_remove_proof_path "$proof_dir/$iteration" || return 1
  command rmdir "$proof_dir" 2>/dev/null || true
}

__dx_review_ledger_append_atomic() {
  local ledger_file="$1"
  shift
  python3 - "$ledger_file" "$@" <<'PY'
import os
import stat
import sys
import tempfile
from pathlib import Path

ledger = Path(sys.argv[1])
fields = sys.argv[2:]
if len(fields) != 8 or any("\t" in value or "\n" in value or "\r" in value for value in fields):
    raise SystemExit(1)
row = ("4\t" + "\t".join(fields) + "\n").encode("ascii")


def read_existing():
    try:
        before = ledger.lstat()
    except FileNotFoundError:
        return b""
    if (
        not stat.S_ISREG(before.st_mode)
        or before.st_uid != os.geteuid()
        or stat.S_IMODE(before.st_mode) != 0o600
        or not 1 <= before.st_size <= 1048576
    ):
        raise ValueError
    descriptor = os.open(ledger, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            raise ValueError
        chunks = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(65536, 1048577 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > 1048576:
                raise ValueError
        content = b"".join(chunks)
        after = os.fstat(descriptor)
        if (
            total != opened.st_size
            or (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
            != (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns)
        ):
            raise ValueError
        return content
    finally:
        os.close(descriptor)


temporary = None
try:
    parent = ledger.parent
    parent_metadata = parent.lstat()
    if (
        not stat.S_ISDIR(parent_metadata.st_mode)
        or parent_metadata.st_uid != os.geteuid()
        or stat.S_IMODE(parent_metadata.st_mode) & 0o022
    ):
        raise ValueError
    existing = read_existing()
    lines = existing.decode("ascii").splitlines()
    if lines:
        parsed = [line.split("\t") for line in lines]
        if any(len(entry) != 9 or entry[0] != "4" for entry in parsed):
            raise ValueError
        if int(fields[0]) <= int(parsed[-1][1]):
            raise ValueError
        if any(entry[2] == fields[1] or entry[7] == fields[6] or entry[8] == fields[7] for entry in parsed):
            raise ValueError
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{ledger.name}.tmp-", dir=parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        content = existing + row
        view = memoryview(content)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise OSError
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.replace(temporary, ledger)
    temporary = None
    parent_descriptor = os.open(
        parent,
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        os.fsync(parent_descriptor)
    finally:
        os.close(parent_descriptor)
except (OSError, UnicodeError, ValueError):
    raise SystemExit(1)
finally:
    if temporary is not None:
        try:
            temporary.unlink()
        except OSError:
            pass
PY
}

dx_review_ledger_reset() {
  local session_id="$1" ledger_file proof_dir
  ledger_file=$(dx_review_ledger_file "$session_id") || return 1
  proof_dir=$(dx_review_proof_dir "$session_id") || return 1
  if [[ -e "$ledger_file" || -L "$ledger_file" ]]; then
    [[ ! -d "$ledger_file" || -L "$ledger_file" ]] || return 1
    command rm -f "$ledger_file" 2>/dev/null || return 1
  fi
  __dx_review_remove_proof_path "$proof_dir"
}

# Append clean credit only after retaining and revalidating its source artifacts.
dx_review_ledger_append() {
  [[ $# -eq 9 ]] || return 1
  local session_id="$1" iteration="$2" pass_id="$3" profile="$4" fingerprint="$5"
  local expected_binding="$6" policy_binding="$7" evidence_file="$8" context_file="$9"
  local criteria_binding criteria_file="" ledger_file proof_dir proof_pass_dir pass_binding attestation
  local ledger_record="" line_count=0 expected_count empty_findings
  dx_review_is_positive_integer "$iteration" || return 1
  dx_review_pass_id_valid "$pass_id" || return 1
  [[ "$profile" == "light" || "$profile" == "standard" || "$profile" == "thorough" ]] || return 1
  [[ "$fingerprint" =~ ^[a-f0-9]{64}$ ]] || return 1
  dx_review_policy_binding_valid "$policy_binding" || return 1
  criteria_binding=$(dx_review_resolve_criteria_binding "$session_id" "$expected_binding") || return 1
  if [[ "$criteria_binding" != "standalone" ]]; then
    criteria_file=$(dx_review_criteria_file "$session_id") || return 1
  fi
  pass_binding=$(dx_review_pass_binding "$pass_id" "$fingerprint" "$criteria_binding" "$policy_binding") || return 1
  dx_review_evidence_valid "$evidence_file" CLEAN "$profile" "$fingerprint" \
    "$criteria_binding" "$criteria_file" "$pass_id" "$policy_binding" "$context_file" || return 1

  ledger_file=$(dx_review_ledger_file "$session_id") || return 1
  proof_dir=$(dx_review_proof_dir "$session_id") || return 1
  proof_pass_dir="${proof_dir}/${iteration}"
  mkdir -p "$(dirname "$ledger_file")" || return 1
  if [[ -e "$ledger_file" || -L "$ledger_file" ]]; then
    [[ -f "$ledger_file" && -s "$ledger_file" && ! -L "$ledger_file" ]] || return 1
    ledger_record=$(__dx_review_read_private_record "$ledger_file" 1048576) || return 1
    line_count=$(printf '%s\n' "$ledger_record" | LC_ALL=C awk 'END { print NR }') || return 1
    dx_review_is_positive_integer "$line_count" || return 1
    dx_review_ledger_valid "$session_id" "$line_count" "$fingerprint" \
      "$criteria_binding" "$policy_binding" "$profile" || return 1
  else
    [[ ! -e "$proof_dir" && ! -L "$proof_dir" ]] || return 1
  fi

  if ! __dx_review_retain_proof "$session_id" "$iteration" "$evidence_file" "$context_file"; then
    rmdir "$proof_dir" 2>/dev/null || :
    return 1
  fi
  if ! dx_review_evidence_valid "$proof_pass_dir/evidence.json" CLEAN "$profile" "$fingerprint" \
      "$criteria_binding" "$criteria_file" "$pass_id" "$policy_binding" "$proof_pass_dir/context.md"; then
    __dx_review_remove_proof_pass "$session_id" "$iteration" 2>/dev/null || true
    return 1
  fi
  empty_findings=$(dx_review_empty_findings_hash) || {
    __dx_review_remove_proof_pass "$session_id" "$iteration" 2>/dev/null || true
    return 1
  }
  attestation=$(dx_review_pass_attestation "$proof_pass_dir/evidence.json" \
    "$proof_pass_dir/context.md" CLEAN "$profile" "$empty_findings" "$pass_binding") || {
    __dx_review_remove_proof_pass "$session_id" "$iteration" 2>/dev/null || true
    return 1
  }
  if ! __dx_review_ledger_append_atomic "$ledger_file" "$iteration" "$pass_id" "$profile" \
      "$fingerprint" "$criteria_binding" "$policy_binding" "$pass_binding" "$attestation"; then
    dx_review_ledger_reset "$session_id" 2>/dev/null || true
    return 1
  fi
  expected_count=$((10#$line_count + 1))
  if ! dx_review_ledger_valid "$session_id" "$expected_count" "$fingerprint" \
      "$criteria_binding" "$policy_binding" "$profile"; then
    dx_review_ledger_reset "$session_id" 2>/dev/null || true
    return 1
  fi
}

# Validate the ledger and exact proof set, then recompute every row attestation.
dx_review_ledger_valid() {
  [[ $# -eq 6 ]] || return 1
  local session_id="$1" expected_count="$2" expected_fingerprint="$3" expected_binding="$4"
  local policy_binding="$5" expected_profile="$6" ledger_file proof_dir criteria_binding criteria_file=""
  local records version iteration pass_id profile fingerprint binding recorded_policy pass_binding attestation
  local computed_attestation empty_findings
  dx_review_is_nonnegative_integer "$expected_count" || return 1
  [[ "$expected_fingerprint" =~ ^[a-f0-9]{64}$ ]] || return 1
  dx_review_policy_binding_valid "$policy_binding" || return 1
  [[ "$expected_profile" == "light" || "$expected_profile" == "standard" || "$expected_profile" == "thorough" ]] || return 1
  criteria_binding=$(dx_review_resolve_criteria_binding "$session_id" "$expected_binding") || return 1
  if [[ "$criteria_binding" != "standalone" ]]; then
    criteria_file=$(dx_review_criteria_file "$session_id") || return 1
  fi
  ledger_file=$(dx_review_ledger_file "$session_id") || return 1
  proof_dir=$(dx_review_proof_dir "$session_id") || return 1
  if [[ "$expected_count" == "0" ]]; then
    [[ ! -e "$ledger_file" && ! -L "$ledger_file" && ! -e "$proof_dir" && ! -L "$proof_dir" ]]
    return
  fi

  records=$(DX_REVIEW_LEDGER_REQUIRED="$expected_count" \
    DX_REVIEW_LEDGER_FINGERPRINT="$expected_fingerprint" \
    DX_REVIEW_LEDGER_CRITERIA_BINDING="$criteria_binding" \
    DX_REVIEW_LEDGER_POLICY_BINDING="$policy_binding" \
    DX_REVIEW_LEDGER_PROFILE="$expected_profile" \
    DX_REVIEW_PROOF_ROOT="$proof_dir" \
    python3 - "$ledger_file" <<'PY'
import hashlib
import json
import os
import re
import stat
import sys
from pathlib import Path

required = int(os.environ["DX_REVIEW_LEDGER_REQUIRED"])
fingerprint = os.environ["DX_REVIEW_LEDGER_FINGERPRINT"]
criteria_binding = os.environ["DX_REVIEW_LEDGER_CRITERIA_BINDING"]
policy_binding = os.environ["DX_REVIEW_LEDGER_POLICY_BINDING"]
profile = os.environ["DX_REVIEW_LEDGER_PROFILE"]
ledger = Path(sys.argv[1])
proof_root = Path(os.environ["DX_REVIEW_PROOF_ROOT"])


def read_private(path, maximum, mode):
    before = path.lstat()
    if (
        not stat.S_ISREG(before.st_mode)
        or before.st_uid != os.geteuid()
        or stat.S_IMODE(before.st_mode) != mode
        or not 1 <= before.st_size <= maximum
    ):
        raise ValueError
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            raise ValueError
        chunks = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(65536, maximum + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > maximum:
                raise ValueError
        content = b"".join(chunks)
        after = os.fstat(descriptor)
        if (
            total != opened.st_size
            or (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
            != (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns)
        ):
            raise ValueError
        return content
    finally:
        os.close(descriptor)


try:
    raw_ledger = read_private(ledger, 1048576, 0o600)
    if not raw_ledger.endswith(b"\n") or b"\r" in raw_ledger:
        raise ValueError
    lines = raw_ledger.decode("ascii").splitlines()
    root_metadata = proof_root.lstat()
    if (
        not stat.S_ISDIR(root_metadata.st_mode)
        or root_metadata.st_uid != os.geteuid()
        or stat.S_IMODE(root_metadata.st_mode) != 0o700
    ):
        raise ValueError
except (OSError, UnicodeError, ValueError):
    raise SystemExit(1)
if len(lines) != required:
    raise SystemExit(1)

previous_iteration = None
pass_ids = set()
pass_bindings = set()
attestations = set()
expected_directories = set()
for line in lines:
    fields = line.split("\t")
    if len(fields) != 9 or fields[0] != "4":
        raise SystemExit(1)
    (
        iteration_raw,
        pass_id,
        recorded_profile,
        recorded_fingerprint,
        recorded_binding,
        recorded_policy_binding,
        recorded_pass_binding,
        attestation,
    ) = fields[1:]
    if not re.fullmatch(r"[1-9][0-9]{0,17}", iteration_raw):
        raise SystemExit(1)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,179}", pass_id):
        raise SystemExit(1)
    if recorded_profile != profile:
        raise SystemExit(1)
    if recorded_fingerprint != fingerprint or recorded_binding != criteria_binding:
        raise SystemExit(1)
    if recorded_policy_binding != policy_binding:
        raise SystemExit(1)
    if not re.fullmatch(r"[a-f0-9]{64}", attestation):
        raise SystemExit(1)
    canonical = json.dumps(
        [
            "dex-review-pass-v1",
            pass_id,
            recorded_fingerprint,
            recorded_binding,
            recorded_policy_binding,
        ],
        ensure_ascii=True,
        separators=(",", ":"),
    )
    expected_pass_binding = hashlib.sha256(canonical.encode("ascii")).hexdigest()
    if recorded_pass_binding != expected_pass_binding:
        raise SystemExit(1)
    iteration = int(iteration_raw)
    if previous_iteration is not None and iteration <= previous_iteration:
        raise SystemExit(1)
    if pass_id in pass_ids or recorded_pass_binding in pass_bindings or attestation in attestations:
        raise SystemExit(1)

    pass_directory = proof_root / iteration_raw
    try:
        directory_metadata = pass_directory.lstat()
        if (
            not stat.S_ISDIR(directory_metadata.st_mode)
            or directory_metadata.st_uid != os.geteuid()
            or stat.S_IMODE(directory_metadata.st_mode) != 0o500
            or {entry.name for entry in pass_directory.iterdir()} != {"evidence.json", "context.md"}
        ):
            raise ValueError
        for name in ("evidence.json", "context.md"):
            read_private(pass_directory / name, 262144, 0o400)
    except (OSError, ValueError):
        raise SystemExit(1)

    previous_iteration = iteration
    pass_ids.add(pass_id)
    pass_bindings.add(recorded_pass_binding)
    attestations.add(attestation)
    expected_directories.add(iteration_raw)

try:
    if {entry.name for entry in proof_root.iterdir()} != expected_directories:
        raise ValueError
except (OSError, ValueError):
    raise SystemExit(1)
print("\n".join(lines))
PY
  ) || return 1

  empty_findings=$(dx_review_empty_findings_hash) || return 1
  while IFS=$'\t' read -r version iteration pass_id profile fingerprint binding \
      recorded_policy pass_binding attestation; do
    [[ "$version" == "4" && -n "$attestation" ]] || return 1
    dx_review_evidence_valid "$proof_dir/$iteration/evidence.json" CLEAN "$profile" \
      "$fingerprint" "$binding" "$criteria_file" "$pass_id" "$recorded_policy" \
      "$proof_dir/$iteration/context.md" || return 1
    computed_attestation=$(dx_review_pass_attestation "$proof_dir/$iteration/evidence.json" \
      "$proof_dir/$iteration/context.md" CLEAN "$profile" "$empty_findings" "$pass_binding") || return 1
    [[ "$computed_attestation" == "$attestation" ]] || return 1
  done <<EOF
$records
EOF
}

dx_review_ledger_hash() {
  local session_id="$1" ledger_file
  ledger_file=$(dx_review_ledger_file "$session_id") || return 1
  DX_PRIVATE_FILE_DIR="$DEX_DIR/scripts" python3 - "$ledger_file" <<'PY'
import hashlib
import os
import sys

sys.path.insert(0, os.environ["DX_PRIVATE_FILE_DIR"])
from private_file import PrivateFileError, read_private_file  # noqa: E402

try:
    content = read_private_file(sys.argv[1], 1048576)
except PrivateFileError:
    raise SystemExit(1)
print(hashlib.sha256(content).hexdigest())
PY
}

__dx_review_read_private_record() {
  local record_file="$1" maximum="$2"
  DX_PRIVATE_FILE_DIR="$DEX_DIR/scripts" python3 - "$record_file" "$maximum" <<'PY'
import os
import sys

sys.path.insert(0, os.environ["DX_PRIVATE_FILE_DIR"])
from private_file import PrivateFileError, read_private_file  # noqa: E402

try:
    content = read_private_file(sys.argv[1], int(sys.argv[2]), require_text_lines=True)
except PrivateFileError:
    raise SystemExit(1)
sys.stdout.buffer.write(content)
PY
}

dx_review_write_receipt() {
  [[ $# -eq 7 ]] || return 1
  local session_id="$1" requested_tier="$2" required_clean="$3" clean_count="$4" repo_dir="$5" expected_binding="$6"
  local policy_binding="$7" tier profile tier_min fingerprint receipt_file ledger_hash criteria_binding policy_record current_policy_binding override_binding
  tier=$(dx_review_normalize_tier "$requested_tier") || return 1
  profile=$(dx_review_tier_profile "$tier") || return 1
  dx_review_is_positive_integer "$required_clean" || return 1
  dx_review_is_positive_integer "$clean_count" || return 1
  policy_record=$(dx_review_policy_for_tier "$repo_dir" "$tier" "$policy_binding") || return 1
  IFS=$'\t' read -r tier_min current_policy_binding _ <<EOF
$policy_record
EOF
  if [[ $((10#$required_clean)) -lt $((10#$tier_min)) ]]; then
    override_binding=$(dx_override_binding "$session_id" review.clean-passes \
      "$required_clean" 3) || return 1
  else
    override_binding="-"
  fi
  [[ $((10#$clean_count)) -eq $((10#$required_clean)) ]] || return 1
  dx_review_policy_binding_valid "$policy_binding" || return 1
  fingerprint=$(dx_review_scope_fingerprint "$repo_dir") || return 1
  criteria_binding=$(dx_review_resolve_criteria_binding "$session_id" "$expected_binding") || return 1
  dx_review_ledger_valid "$session_id" "$required_clean" "$fingerprint" "$criteria_binding" \
    "$policy_binding" "$profile" || return 1
  ledger_hash=$(dx_review_ledger_hash "$session_id") || return 1
  [[ "$ledger_hash" =~ ^[a-f0-9]{64}$ ]] || return 1
  receipt_file=$(dx_review_receipt_file "$session_id") || return 1
  dx_review_write_atomic "$receipt_file" "6"$'\t'"${tier}"$'\t'"${profile}"$'\t'"${required_clean}"$'\t'"${clean_count}"$'\t'"${fingerprint}"$'\t'"${ledger_hash}"$'\t'"${criteria_binding}"$'\t'"${policy_binding}"$'\t'"${override_binding}"
}

dx_review_read_receipt() {
  [[ $# -eq 4 ]] || return 1
  local session_id="$1" repo_dir="$2" expected_binding="$3" expected_policy_binding="$4" receipt_file raw
  local version tier profile expected_profile tier_min required_clean clean_count fingerprint ledger_hash criteria_binding policy_binding override_binding extra
  local current_fingerprint current_ledger_hash current_binding policy_record current_policy_binding
  receipt_file=$(dx_review_receipt_file "$session_id") || return 1
  raw=$(__dx_review_read_private_record "$receipt_file" 4096) || return 1
  [[ "$raw" != *$'\n'* && "$raw" != *$'\r'* ]] || return 1
  IFS=$'\t' read -r version tier profile required_clean clean_count fingerprint ledger_hash criteria_binding policy_binding override_binding extra <<EOF
$raw
EOF
  [[ "$version" == "6" ]] || return 1
  [[ -z "$extra" ]] || return 1
  tier=$(dx_review_normalize_tier "$tier") || return 1
  expected_profile=$(dx_review_tier_profile "$tier") || return 1
  [[ "$profile" == "$expected_profile" ]] || return 1
  dx_review_is_positive_integer "$required_clean" || return 1
  dx_review_is_positive_integer "$clean_count" || return 1
  policy_record=$(dx_review_policy_for_tier "$repo_dir" "$tier" "$expected_policy_binding") || return 1
  IFS=$'\t' read -r tier_min current_policy_binding _ <<EOF
$policy_record
EOF
  if [[ $((10#$required_clean)) -lt $((10#$tier_min)) ]]; then
    [[ "$override_binding" =~ ^[a-f0-9]{64}$ ]] || return 1
    [[ "$override_binding" == "$(dx_override_binding "$session_id" \
      review.clean-passes "$required_clean" 3)" ]] || return 1
  else
    [[ "$override_binding" == "-" ]] || return 1
  fi
  [[ $((10#$clean_count)) -eq $((10#$required_clean)) ]] || return 1
  [[ "$fingerprint" =~ ^[a-f0-9]{64}$ ]] || return 1
  [[ "$ledger_hash" =~ ^[a-f0-9]{64}$ ]] || return 1
  dx_review_policy_binding_valid "$policy_binding" || return 1
  dx_review_policy_binding_valid "$expected_policy_binding" || return 1
  [[ "$policy_binding" == "$expected_policy_binding" && "$policy_binding" == "$current_policy_binding" ]] || return 1
  current_fingerprint=$(dx_review_scope_fingerprint "$repo_dir") || return 1
  [[ "$current_fingerprint" == "$fingerprint" ]] || return 1
  dx_review_criteria_binding_valid "$criteria_binding" || return 1
  current_binding=$(dx_review_resolve_criteria_binding "$session_id" "$expected_binding") || return 1
  [[ "$current_binding" == "$criteria_binding" ]] || return 1
  dx_review_ledger_valid "$session_id" "$required_clean" "$fingerprint" "$current_binding" \
    "$policy_binding" "$profile" || return 1
  current_ledger_hash=$(dx_review_ledger_hash "$session_id") || return 1
  [[ "$current_ledger_hash" == "$ledger_hash" ]] || return 1
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$tier" "$required_clean" "$clean_count" "$fingerprint" "$ledger_hash" "$criteria_binding" "$policy_binding"
}

dx_review_receipt_valid() {
  [[ $# -eq 4 ]] || return 1
  local session_id="$1" repo_dir="$2" expected_binding="$3" expected_policy_binding="$4" receipt selection
  local pause_context_rc=0 review_state_file
  local receipt_tier receipt_required receipt_clean receipt_fingerprint receipt_ledger_hash receipt_binding receipt_tier_min
  local receipt_policy_binding
  local selection_tier selection_source selection_reasons selection_required selection_fingerprint selection_binding selection_policy_binding
  [[ ! -e "$(dx_review_receipt_revocation_file "$session_id")" \
    && ! -L "$(dx_review_receipt_revocation_file "$session_id")" ]] || return 1
  dx_lifecycle_pause_context_state "$session_id" || pause_context_rc=$?
  [[ "$pause_context_rc" -eq 1 ]] || return 1
  review_state_file=$(dx_review_state_file "$session_id") || return 1
  [[ ! -e "$review_state_file" && ! -L "$review_state_file" ]] || return 1
  receipt=$(dx_review_read_receipt "$session_id" "$repo_dir" "$expected_binding" "$expected_policy_binding") || return 1
  selection=$(dx_review_read_selection "$session_id" "$repo_dir" "$expected_binding" "$expected_policy_binding") || return 1
  IFS=$'\t' read -r receipt_tier receipt_required receipt_clean receipt_fingerprint receipt_ledger_hash receipt_binding receipt_policy_binding <<EOF
$receipt
EOF
  IFS=$'\t' read -r selection_tier selection_source selection_reasons selection_required selection_fingerprint selection_binding selection_policy_binding <<EOF
$selection
EOF
  # Capture before splitting: sourced libs run without pipefail, so a `|| return`
  # after a pipeline would only see cut's status and an empty field would slip
  # into the arithmetic as zero.
  local receipt_policy_record
  receipt_policy_record=$(dx_review_policy_for_tier "$repo_dir" "$receipt_tier" "$expected_policy_binding") || return 1
  receipt_tier_min="${receipt_policy_record%%$'\t'*}"
  [[ "$receipt_tier_min" =~ ^[0-9]+$ ]] || return 1
  if [[ $((10#$receipt_required)) -lt $((10#$receipt_tier_min)) ]]; then
    dx_override_binding "$session_id" review.clean-passes \
      "$receipt_required" 3 >/dev/null || return 1
  fi
  [[ $((10#$receipt_clean)) -eq $((10#$receipt_required)) ]] || return 1
  [[ "$selection_policy_binding" == "$expected_policy_binding" ]] || return 1
  : "$selection_source" "$selection_reasons" "$receipt_ledger_hash"
  [[ "$receipt_tier" == "$selection_tier" && \
     "$receipt_required" == "$selection_required" && \
     "$receipt_fingerprint" == "$selection_fingerprint" && \
     "$receipt_binding" == "$selection_binding" && \
     "$receipt_policy_binding" == "$expected_policy_binding" ]]
}

# Print completed when the trusted tier target was met, or waived when an
# attributed review.clean-passes override authorized a lower target.
dx_review_receipt_outcome() {
  [[ $# -eq 4 ]] || return 1
  local session_id="$1" repo_dir="$2" expected_binding="$3"
  local expected_policy_binding="$4" receipt tier required_clean tier_min policy_record
  receipt=$(dx_review_read_receipt "$session_id" "$repo_dir" \
    "$expected_binding" "$expected_policy_binding") || return 1
  IFS=$'\t' read -r tier required_clean _ <<EOF
$receipt
EOF
  policy_record=$(dx_review_policy_for_tier "$repo_dir" "$tier" \
    "$expected_policy_binding") || return 1
  tier_min="${policy_record%%$'\t'*}"
  if [[ $((10#$required_clean)) -lt $((10#$tier_min)) ]]; then
    printf 'waived\n'
  else
    printf 'completed\n'
  fi
}

dx_review_receipt_revocation_file() {
  [[ $# -eq 1 ]] || return 1
  printf '%s.revoked\n' "$(dx_review_receipt_file "$1")"
}

# Return success only when the receipt path cannot contain a trusted private
# record. This is deliberately stricter than schema validation: review start
# must not clear its revocation marker while any old authorizing inode remains.
dx_review_receipt_authorization_absent() {
  [[ $# -eq 1 ]] || return 1
  local session_id="$1" receipt_file
  dx_session_id_valid "$session_id" || return 1
  receipt_file=$(dx_review_receipt_file "$session_id") || return 1
  __dx_review_private_record_authorization_absent "$receipt_file" 4096
}

# Revoke a parent review receipt even when its directory no longer permits
# unlinking. The reader accepts only current-user 0600 regular files, so a
# verified mode change is a durable fail-closed fallback until the receipt can
# be removed during repair.
dx_review_revoke_receipt() {
  [[ $# -eq 1 ]] || return 1
  local session_id="$1" receipt_file revocation_file revocation_written=0
  dx_session_id_valid "$session_id" || return 1
  receipt_file=$(dx_review_receipt_file "$session_id") || return 1
  revocation_file=$(dx_review_receipt_revocation_file "$session_id") || return 1
  dx_review_write_atomic "$revocation_file" revoked 2>/dev/null \
    && revocation_written=1
  if __dx_review_invalidate_private_record "$receipt_file" 2>/dev/null; then
    return 0
  fi
  [[ "$revocation_written" -eq 1 ]]
}

dx_review_read_findings_hash() {
  local findings_file="$1" raw
  dx_review_findings_hash_valid "$findings_file" || return 1
  raw=$(cat "$findings_file" 2>/dev/null) || return 1
  printf '%s\n' "$raw"
}

dx_review_empty_findings_hash() {
  printf '%s\n' "EMPTY" | dx_review_hash_findings
}

dx_review_hash_findings() {
  python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:16])'
}

dx_review_findings_churn_kind() {
  local findings_file="$1"
  [[ -f "$findings_file" ]] || return 1
  tail -n 4 "$findings_file" 2>/dev/null | awk '
    { hash[NR] = $0 }
    END {
      if (NR >= 3 && hash[NR] != "" && hash[NR] == hash[NR-1] && hash[NR] == hash[NR-2]) {
        print "repeated_fingerprint"
        exit 0
      }
      if (NR >= 4 && hash[NR] != "" && hash[NR] == hash[NR-2] && hash[NR-1] == hash[NR-3] && hash[NR] != hash[NR-1]) {
        print "alternating_fingerprints"
        exit 0
      }
      exit 1
    }
  '
}

dx_review_event_json() {
  python3 - "$@" <<'PY'
import json
import re
import sys

payload = {}
for raw in sys.argv[1:]:
    key, separator, value = raw.partition("=")
    if not separator or not re.fullmatch(r"[a-z][a-z0-9_]*(?:_(?:int|bool))?", key):
        raise SystemExit("invalid review telemetry field")
    if key.endswith("_int"):
        payload[key[:-4]] = int(value)
    elif key.endswith("_bool"):
        if value not in {"true", "false"}:
            raise SystemExit("invalid review telemetry boolean")
        payload[key[:-5]] = value == "true"
    else:
        payload[key] = value
print(json.dumps(payload, sort_keys=True, separators=(",", ":")))
PY
}
