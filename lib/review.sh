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

dx_review_tier_clean_passes() {
  local tier
  tier=$(dx_review_normalize_tier "${1:-}") || return 1
  case "$tier" in
    small) printf '%s\n' "3" ;;
    normal) printf '%s\n' "6" ;;
    complex) printf '%s\n' "9" ;;
  esac
}

dx_review_tier_min_clean_passes() {
  local tier
  tier=$(dx_review_normalize_tier "${1:-}") || return 1
  case "$tier" in
    small) printf '%s\n' "3" ;;
    normal) printf '%s\n' "6" ;;
    complex) printf '%s\n' "9" ;;
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

dx_review_higher_tier() {
  local first second first_rank second_rank
  first=$(dx_review_normalize_tier "${1:-}") || return 1
  second=$(dx_review_normalize_tier "${2:-}") || return 1
  first_rank=$(dx_review_tier_rank "$first") || return 1
  second_rank=$(dx_review_tier_rank "$second") || return 1
  if [[ "$first_rank" -ge "$second_rank" ]]; then
    printf '%s\n' "$first"
  else
    printf '%s\n' "$second"
  fi
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
  local assessment_file="$1" parsed tier reason_codes
  [[ -f "$assessment_file" ]] || return 1
  parsed=$(python3 - "$assessment_file" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        payload = json.load(handle)
except (OSError, UnicodeError, json.JSONDecodeError):
    raise SystemExit(1)

if not isinstance(payload, dict) or set(payload) != {"tier", "reason_codes"}:
    raise SystemExit(1)
tier = payload["tier"]
reason_codes = payload["reason_codes"]
if not isinstance(tier, str) or not isinstance(reason_codes, str):
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

dx_review_criteria_binding_valid() {
  local binding="${1:-}"
  [[ "$binding" == "standalone" || "$binding" =~ ^[a-f0-9]{64}$ ]]
}

# Resolve an explicit criteria binding, or infer one for compatibility callers.
# A present-but-invalid criteria file is always an error.
dx_review_resolve_criteria_binding() {
  local session_id="$1" expected_binding="${2:-}" criteria_file current_hash
  criteria_file=$(dx_review_criteria_file "$session_id") || return 1
  if [[ -n "$expected_binding" ]]; then
    dx_review_criteria_binding_valid "$expected_binding" || return 1
    if [[ "$expected_binding" == "standalone" ]]; then
      [[ ! -e "$criteria_file" ]] || return 1
    else
      current_hash=$(dx_review_criteria_hash "$criteria_file") || return 1
      [[ "$current_hash" == "$expected_binding" ]] || return 1
    fi
    printf '%s\n' "$expected_binding"
    return 0
  fi
  if [[ -e "$criteria_file" ]]; then
    dx_review_criteria_hash "$criteria_file"
  else
    printf '%s\n' "standalone"
  fi
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

dx_review_evidence_valid() {
  local evidence_file="$1" result="$2" profile="$3" expected_fingerprint="$4"
  dx_review_result_valid "$result" || return 1
  [[ "$profile" == "light" || "$profile" == "standard" || "$profile" == "thorough" ]] || return 1
  [[ "$expected_fingerprint" =~ ^[a-f0-9]{64}$ ]] || return 1
  [[ -f "$evidence_file" ]] || return 1
  DX_REVIEW_EVIDENCE_RESULT="$result" \
  DX_REVIEW_EVIDENCE_PROFILE="$profile" \
  DX_REVIEW_EVIDENCE_FINGERPRINT="$expected_fingerprint" \
  python3 - "$evidence_file" <<'PY'
import json
import os
import re
import sys

try:
    if os.path.getsize(sys.argv[1]) > 65536:
        raise ValueError
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        payload = json.load(handle)
except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
    raise SystemExit(1)

required_keys = {
    "version",
    "scope_fingerprint",
    "deterministic_checks",
    "coverage",
    "verifier",
    "verified_findings",
    "fixes_applied",
}
if not isinstance(payload, dict) or set(payload) != required_keys:
    raise SystemExit(1)
if payload["version"] != 1:
    raise SystemExit(1)
if payload["scope_fingerprint"] != os.environ["DX_REVIEW_EVIDENCE_FINGERPRINT"]:
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
    required_coverage = all_domains if profile == "thorough" else core
    if not required_coverage.issubset(set(coverage)):
        raise SystemExit(1)
elif result.startswith("FINDINGS_FIXED:"):
    count = int(result.split(":", 1)[1])
    if payload["deterministic_checks"] != "pass" or payload["verifier"] != "pass":
        raise SystemExit(1)
    if payload["verified_findings"] != count or payload["fixes_applied"] != count:
        raise SystemExit(1)
    required_coverage = all_domains if profile == "thorough" else core
    if not required_coverage.issubset(set(coverage)):
        raise SystemExit(1)
elif result.startswith("FINDINGS:"):
    count = int(result.split(":", 1)[1])
    if payload["verified_findings"] != count or payload["fixes_applied"] > count:
        raise SystemExit(1)
elif result.startswith("ESCALATE:") or result.startswith("ESCALATE_THOROUGH:"):
    if payload["verifier"] != "pass" or payload["fixes_applied"] != 0:
        raise SystemExit(1)
PY
}

dx_review_evidence_hash() {
  local evidence_file="$1"
  [[ -f "$evidence_file" ]] || return 1
  python3 - "$evidence_file" <<'PY'
import hashlib
import sys

with open(sys.argv[1], "rb") as handle:
    print(hashlib.sha256(handle.read()).hexdigest()[:16])
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
    if os.path.getsize(sys.argv[1]) > 65536:
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

    cached_paths = {
        item
        for item in git(
            "diff", "--cached", "--name-only", "--no-renames", "-z", "--"
        ).split(b"\0")
        if item
    }
    worktree_paths = {
        item
        for item in git(
            "diff", "--name-only", "--no-renames", "-z", "--"
        ).split(b"\0")
        if item
    }
    untracked_paths = {
        item
        for item in git("ls-files", "--others", "--exclude-standard", "-z").split(b"\0")
        if item
    }

    if comparison_tree:
        paths = {
            item
            for item in git(
                "diff", "--name-only", "--no-renames", "-z", merge_base, "HEAD", "--"
            ).split(b"\0")
            if item
        }
        paths.update(cached_paths)
        paths.update(worktree_paths)
        paths.update(untracked_paths)
    else:
        paths = {
            item for item in git("ls-files", "-z").split(b"\0") if item
        }
        paths.update(untracked_paths)

    digest = hashlib.sha256()
    digest.update(b"SCOPE_CONTENT_V2\0")
    if comparison_tree:
        digest.update(b"COMPARISON_TREE\0" + comparison_tree + b"\0")
    else:
        digest.update(b"WHOLE_CODEBASE\0")

    for raw_path in sorted(paths):
        path = root / os.fsdecode(raw_path)
        try:
            metadata = path.lstat()
        except FileNotFoundError:
            if comparison_tree:
                digest.update(
                    b"PATH\0"
                    + len(raw_path).to_bytes(8, "big")
                    + raw_path
                    + b"\0MISSING\0"
                )
            continue
        except OSError:
            metadata = None

        digest.update(b"PATH\0" + len(raw_path).to_bytes(8, "big") + raw_path)
        if metadata is None:
            digest.update(b"\0MODE\0UNREADABLE\0")
        elif stat.S_ISLNK(metadata.st_mode):
            digest.update(b"\0MODE\0" + b"120000" + b"\0TARGET\0" + os.fsencode(os.readlink(path)))
        elif stat.S_ISREG(metadata.st_mode):
            mode = b"100755" if metadata.st_mode & 0o111 else b"100644"
            object_digest = hashlib.sha256()
            try:
                with path.open("rb") as handle:
                    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                        object_digest.update(chunk)
            except OSError:
                object_digest = None
            digest.update(b"\0MODE\0" + mode + b"\0CONTENT_SHA256\0")
            digest.update(object_digest.digest() if object_digest else b"UNREADABLE")
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
        else:
            digest.update(b"\0MODE\0SPECIAL\0")

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
  tmp_file="${target}.tmp.$$"
  if ! printf '%s\n' "$content" > "$tmp_file" || ! command mv -f "$tmp_file" "$target"; then
    command rm -f "$tmp_file" 2>/dev/null || true
    return 1
  fi
}

dx_review_write_selection() {
  local session_id="$1" requested_tier="$2" source="$3" reason_codes="$4" repo_dir="${5:-$PWD}"
  local required_clean="${6:-}" tier tier_min fingerprint selection_file floor_record floor_tier floor_reason tier_rank floor_rank
  local expected_binding="${7:-}" criteria_binding
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
  tier_min=$(dx_review_tier_min_clean_passes "$tier") || return 1
  [[ -n "$required_clean" ]] || required_clean="$tier_min"
  dx_review_is_positive_integer "$required_clean" || return 1
  [[ $((10#$required_clean)) -ge $((10#$tier_min)) ]] || return 1
  fingerprint=$(dx_review_scope_fingerprint "$repo_dir") || return 1
  selection_file=$(dx_review_selection_file "$session_id") || return 1
  criteria_binding=$(dx_review_resolve_criteria_binding "$session_id" "$expected_binding") || return 1
  case "$source" in
    lifecycle-agent|lifecycle-assessor)
      [[ "$criteria_binding" != "standalone" ]] || return 1
      ;;
    standalone-assessor)
      [[ "$criteria_binding" == "standalone" ]] || return 1
      ;;
  esac
  dx_review_write_atomic "$selection_file" "3"$'\t'"${tier}"$'\t'"${source}"$'\t'"${reason_codes}"$'\t'"${required_clean}"$'\t'"${fingerprint}"$'\t'"${criteria_binding}"
}

dx_review_read_selection() {
  local session_id="$1" repo_dir="${2:-$PWD}" expected_binding="${3:-}" selection_file raw
  local version tier source reason_codes required_clean fingerprint criteria_binding extra current_fingerprint tier_min
  local floor_record floor_tier floor_reason tier_rank floor_rank
  local current_binding
  selection_file=$(dx_review_selection_file "$session_id") || return 1
  [[ -f "$selection_file" ]] || return 1
  raw=$(cat "$selection_file" 2>/dev/null) || return 1
  [[ "$raw" != *$'\n'* && "$raw" != *$'\r'* ]] || return 1
  IFS=$'\t' read -r version tier source reason_codes required_clean fingerprint criteria_binding extra <<EOF
$raw
EOF
  if [[ "$version" == "1" ]]; then
    fingerprint="$required_clean"
    required_clean=""
    criteria_binding="standalone"
  elif [[ "$version" == "2" ]]; then
    criteria_binding="standalone"
  elif [[ "$version" != "3" ]]; then
    return 1
  fi
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
  tier_min=$(dx_review_tier_min_clean_passes "$tier") || return 1
  [[ -n "$required_clean" ]] || required_clean="$tier_min"
  dx_review_is_positive_integer "$required_clean" || return 1
  [[ $((10#$required_clean)) -ge $((10#$tier_min)) ]] || return 1
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
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$tier" "$source" "$reason_codes" "$required_clean" "$fingerprint" "$criteria_binding"
}

dx_review_selection_valid() {
  dx_review_read_selection "$@" >/dev/null
}

dx_review_write_state() {
  local session_id="$1" requested_tier="$2" required_clean="$3" iteration="$4" clean_count="$5" repo_dir="${6:-$PWD}"
  local tier tier_min fingerprint state_file
  tier=$(dx_review_normalize_tier "$requested_tier") || return 1
  dx_review_is_positive_integer "$required_clean" || return 1
  dx_review_is_nonnegative_integer "$iteration" || return 1
  dx_review_is_nonnegative_integer "$clean_count" || return 1
  tier_min=$(dx_review_tier_min_clean_passes "$tier") || return 1
  [[ $((10#$required_clean)) -ge $((10#$tier_min)) ]] || return 1
  [[ $((10#$clean_count)) -lt $((10#$required_clean)) ]] || return 1
  [[ $((10#$clean_count)) -le $((10#$iteration)) ]] || return 1
  fingerprint=$(dx_review_scope_fingerprint "$repo_dir") || return 1
  state_file=$(dx_review_state_file "$session_id") || return 1
  dx_review_write_atomic "$state_file" "1"$'\t'"${tier}"$'\t'"${required_clean}"$'\t'"${iteration}"$'\t'"${clean_count}"$'\t'"${fingerprint}"
}

dx_review_read_state() {
  local session_id="$1" repo_dir="${2:-$PWD}" state_file raw
  local version tier tier_min required_clean iteration clean_count fingerprint extra current_fingerprint
  state_file=$(dx_review_state_file "$session_id") || return 1
  [[ -f "$state_file" ]] || return 1
  raw=$(cat "$state_file" 2>/dev/null) || return 1
  [[ "$raw" != *$'\n'* && "$raw" != *$'\r'* ]] || return 1
  IFS=$'\t' read -r version tier required_clean iteration clean_count fingerprint extra <<EOF
$raw
EOF
  [[ "$version" == "1" && -z "$extra" ]] || return 1
  tier=$(dx_review_normalize_tier "$tier") || return 1
  dx_review_is_positive_integer "$required_clean" || return 1
  dx_review_is_nonnegative_integer "$iteration" || return 1
  dx_review_is_nonnegative_integer "$clean_count" || return 1
  tier_min=$(dx_review_tier_min_clean_passes "$tier") || return 1
  [[ $((10#$required_clean)) -ge $((10#$tier_min)) ]] || return 1
  [[ $((10#$clean_count)) -lt $((10#$required_clean)) ]] || return 1
  [[ $((10#$clean_count)) -le $((10#$iteration)) ]] || return 1
  [[ "$fingerprint" =~ ^[a-f0-9]{64}$ ]] || return 1
  current_fingerprint=$(dx_review_scope_fingerprint "$repo_dir") || return 1
  [[ "$current_fingerprint" == "$fingerprint" ]] || return 1
  printf '%s\t%s\t%s\t%s\t%s\n' "$tier" "$required_clean" "$iteration" "$clean_count" "$fingerprint"
}

dx_review_ledger_reset() {
  local session_id="$1" ledger_file
  ledger_file=$(dx_review_ledger_file "$session_id") || return 1
  command rm -f "$ledger_file" 2>/dev/null || return 1
}

dx_review_ledger_append() {
  local session_id="$1" iteration="$2" pass_id="$3" fingerprint="$4" evidence_hash="$5"
  local ledger_file tmp_file last_iteration=0 last_pass_id="" last_fingerprint="" last_hash="" version="" extra=""
  dx_review_is_positive_integer "$iteration" || return 1
  [[ "$pass_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,179}$ ]] || return 1
  [[ "$fingerprint" =~ ^[a-f0-9]{64}$ && "$evidence_hash" =~ ^[a-f0-9]{16}$ ]] || return 1
  ledger_file=$(dx_review_ledger_file "$session_id") || return 1
  mkdir -p "$(dirname "$ledger_file")" || return 1
  if [[ -f "$ledger_file" && -s "$ledger_file" ]]; then
    IFS=$'\t' read -r version last_iteration last_pass_id last_fingerprint last_hash extra <<EOF
$(tail -n 1 "$ledger_file" 2>/dev/null)
EOF
    [[ "$version" == "1" && -z "$extra" ]] || return 1
    dx_review_is_positive_integer "$last_iteration" || return 1
    [[ $((10#$iteration)) -eq $((10#$last_iteration + 1)) ]] || return 1
    [[ "$last_pass_id" != "$pass_id" && "$last_fingerprint" == "$fingerprint" && "$last_hash" =~ ^[a-f0-9]{16}$ ]] || return 1
  fi
  tmp_file="${ledger_file}.tmp.$$"
  if [[ -f "$ledger_file" ]] && ! command cp "$ledger_file" "$tmp_file"; then
    command rm -f "$tmp_file" 2>/dev/null || true
    return 1
  fi
  if ! printf '1\t%s\t%s\t%s\t%s\n' "$iteration" "$pass_id" "$fingerprint" "$evidence_hash" >> "$tmp_file" || \
     ! command mv -f "$tmp_file" "$ledger_file"; then
    command rm -f "$tmp_file" 2>/dev/null || true
    return 1
  fi
}

dx_review_ledger_valid() {
  local session_id="$1" expected_count="$2" expected_fingerprint="$3" ledger_file
  dx_review_is_nonnegative_integer "$expected_count" || return 1
  [[ "$expected_fingerprint" =~ ^[a-f0-9]{64}$ ]] || return 1
  ledger_file=$(dx_review_ledger_file "$session_id") || return 1
  if [[ "$expected_count" == "0" ]]; then
    [[ ! -s "$ledger_file" ]]
    return
  fi
  [[ -f "$ledger_file" ]] || return 1
  DX_REVIEW_LEDGER_REQUIRED="$expected_count" \
  DX_REVIEW_LEDGER_FINGERPRINT="$expected_fingerprint" \
  python3 - "$ledger_file" <<'PY'
import os
import re
import sys

required = int(os.environ["DX_REVIEW_LEDGER_REQUIRED"])
fingerprint = os.environ["DX_REVIEW_LEDGER_FINGERPRINT"]
try:
    with open(sys.argv[1], "r", encoding="ascii") as handle:
        lines = [line.rstrip("\n") for line in handle]
except (OSError, UnicodeError):
    raise SystemExit(1)
if len(lines) != required:
    raise SystemExit(1)

previous_iteration = None
pass_ids = set()
for line in lines:
    fields = line.split("\t")
    if len(fields) != 5 or fields[0] != "1":
        raise SystemExit(1)
    iteration_raw, pass_id, recorded_fingerprint, evidence_hash = fields[1:]
    if not re.fullmatch(r"[1-9][0-9]{0,17}", iteration_raw):
        raise SystemExit(1)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,179}", pass_id):
        raise SystemExit(1)
    if recorded_fingerprint != fingerprint or not re.fullmatch(r"[a-f0-9]{16}", evidence_hash):
        raise SystemExit(1)
    iteration = int(iteration_raw)
    if previous_iteration is not None and iteration != previous_iteration + 1:
        raise SystemExit(1)
    if pass_id in pass_ids:
        raise SystemExit(1)
    previous_iteration = iteration
    pass_ids.add(pass_id)
PY
}

dx_review_ledger_hash() {
  local session_id="$1" ledger_file
  ledger_file=$(dx_review_ledger_file "$session_id") || return 1
  [[ -f "$ledger_file" ]] || return 1
  python3 - "$ledger_file" <<'PY'
import hashlib
import sys

with open(sys.argv[1], "rb") as handle:
    print(hashlib.sha256(handle.read()).hexdigest())
PY
}

dx_review_write_receipt() {
  local session_id="$1" requested_tier="$2" required_clean="$3" clean_count="$4" repo_dir="${5:-$PWD}" expected_binding="${6:-}"
  local tier tier_min fingerprint receipt_file ledger_hash criteria_binding
  tier=$(dx_review_normalize_tier "$requested_tier") || return 1
  dx_review_is_positive_integer "$required_clean" || return 1
  dx_review_is_positive_integer "$clean_count" || return 1
  tier_min=$(dx_review_tier_min_clean_passes "$tier") || return 1
  [[ $((10#$required_clean)) -ge $((10#$tier_min)) ]] || return 1
  [[ $((10#$clean_count)) -eq $((10#$required_clean)) ]] || return 1
  fingerprint=$(dx_review_scope_fingerprint "$repo_dir") || return 1
  dx_review_ledger_valid "$session_id" "$required_clean" "$fingerprint" || return 1
  ledger_hash=$(dx_review_ledger_hash "$session_id") || return 1
  [[ "$ledger_hash" =~ ^[a-f0-9]{64}$ ]] || return 1
  criteria_binding=$(dx_review_resolve_criteria_binding "$session_id" "$expected_binding") || return 1
  receipt_file=$(dx_review_receipt_file "$session_id") || return 1
  dx_review_write_atomic "$receipt_file" "3"$'\t'"${tier}"$'\t'"${required_clean}"$'\t'"${clean_count}"$'\t'"${fingerprint}"$'\t'"${ledger_hash}"$'\t'"${criteria_binding}"
}

dx_review_read_receipt() {
  local session_id="$1" repo_dir="${2:-$PWD}" expected_binding="${3:-}" receipt_file raw
  local version tier tier_min required_clean clean_count fingerprint ledger_hash criteria_binding extra current_fingerprint current_ledger_hash current_binding
  receipt_file=$(dx_review_receipt_file "$session_id") || return 1
  [[ -f "$receipt_file" ]] || return 1
  raw=$(cat "$receipt_file" 2>/dev/null) || return 1
  [[ "$raw" != *$'\n'* && "$raw" != *$'\r'* ]] || return 1
  IFS=$'\t' read -r version tier required_clean clean_count fingerprint ledger_hash criteria_binding extra <<EOF
$raw
EOF
  if [[ "$version" == "2" ]]; then
    criteria_binding="standalone"
  elif [[ "$version" != "3" ]]; then
    return 1
  fi
  [[ -z "$extra" ]] || return 1
  tier=$(dx_review_normalize_tier "$tier") || return 1
  dx_review_is_positive_integer "$required_clean" || return 1
  dx_review_is_positive_integer "$clean_count" || return 1
  tier_min=$(dx_review_tier_min_clean_passes "$tier") || return 1
  [[ $((10#$required_clean)) -ge $((10#$tier_min)) ]] || return 1
  [[ $((10#$clean_count)) -eq $((10#$required_clean)) ]] || return 1
  [[ "$fingerprint" =~ ^[a-f0-9]{64}$ ]] || return 1
  [[ "$ledger_hash" =~ ^[a-f0-9]{64}$ ]] || return 1
  current_fingerprint=$(dx_review_scope_fingerprint "$repo_dir") || return 1
  [[ "$current_fingerprint" == "$fingerprint" ]] || return 1
  dx_review_ledger_valid "$session_id" "$required_clean" "$fingerprint" || return 1
  current_ledger_hash=$(dx_review_ledger_hash "$session_id") || return 1
  [[ "$current_ledger_hash" == "$ledger_hash" ]] || return 1
  dx_review_criteria_binding_valid "$criteria_binding" || return 1
  current_binding=$(dx_review_resolve_criteria_binding "$session_id" "$expected_binding") || return 1
  [[ "$current_binding" == "$criteria_binding" ]] || return 1
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$tier" "$required_clean" "$clean_count" "$fingerprint" "$ledger_hash" "$criteria_binding"
}

dx_review_receipt_valid() {
  local session_id="$1" repo_dir="${2:-$PWD}" expected_binding="${3:-}" receipt selection
  local receipt_tier receipt_required receipt_clean receipt_fingerprint receipt_ledger_hash receipt_binding receipt_tier_min
  local selection_tier selection_source selection_reasons selection_required selection_fingerprint selection_binding
  [[ ! -f "$(dx_paused_file "$session_id")" ]] || return 1
  [[ ! -f "$(dx_review_state_file "$session_id")" ]] || return 1
  receipt=$(dx_review_read_receipt "$session_id" "$repo_dir" "$expected_binding") || return 1
  selection=$(dx_review_read_selection "$session_id" "$repo_dir" "$expected_binding") || return 1
  IFS=$'\t' read -r receipt_tier receipt_required receipt_clean receipt_fingerprint receipt_ledger_hash receipt_binding <<EOF
$receipt
EOF
  IFS=$'\t' read -r selection_tier selection_source selection_reasons selection_required selection_fingerprint selection_binding <<EOF
$selection
EOF
  receipt_tier_min=$(dx_review_tier_min_clean_passes "$receipt_tier") || return 1
  [[ $((10#$receipt_required)) -ge $((10#$receipt_tier_min)) ]] || return 1
  [[ $((10#$receipt_clean)) -eq $((10#$receipt_required)) ]] || return 1
  : "$selection_source" "$selection_reasons" "$receipt_ledger_hash"
  [[ "$receipt_tier" == "$selection_tier" && \
     "$receipt_required" == "$selection_required" && \
     "$receipt_fingerprint" == "$selection_fingerprint" && \
     "$receipt_binding" == "$selection_binding" ]]
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
