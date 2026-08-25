# shellcheck shell=bash
# Resolve clean-pass policy from the committed default branch, with built-in
# defaults only when the repository has no commits.

__dx_review_policy_sha256_stdin() {
  python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
}

dx_review_policy_binding() {
  [[ $# -eq 3 ]] || return 1
  local small="$1" normal="$2" complex="$3" value
  for value in "$small" "$normal" "$complex"; do
    dx_review_is_positive_integer "$value" || return 1
    [[ $((10#$value)) -le 30 ]] || return 1
  done
  small=$((10#$small))
  normal=$((10#$normal))
  complex=$((10#$complex))
  [[ $small -le $normal && $normal -le $complex ]] || return 1
  printf 'review-policy-v1:small=%s,normal=%s,complex=%s' \
    "$small" "$normal" "$complex" | __dx_review_policy_sha256_stdin
}

dx_review_policy_tier_clean_passes() {
  [[ $# -eq 4 ]] || return 1
  local tier small="$2" normal="$3" complex="$4"
  tier=$(dx_review_normalize_tier "$1") || return 1
  dx_review_policy_binding "$small" "$normal" "$complex" >/dev/null || return 1
  case "$tier" in
    small) printf '%s\n' "$((10#$small))" ;;
    normal) printf '%s\n' "$((10#$normal))" ;;
    complex) printf '%s\n' "$((10#$complex))" ;;
  esac
}

dx_review_policy_provenance_valid() {
  [[ $# -eq 2 ]] || return 1
  local trusted_ref="$1" trusted_oid="$2"
  if [[ "$trusted_ref" == "built-in-defaults" || "$trusted_oid" == "unborn" ]]; then
    if [[ "$trusted_ref" == "built-in-defaults" && "$trusted_oid" == "unborn" ]]; then
      return 0
    fi
    return 1
  fi
  [[ -n "$trusted_ref" && "$trusted_ref" != *$'\t'* && \
     "$trusted_ref" != *$'\n'* && "$trusted_ref" != *$'\r'* ]] || return 1
  [[ "$trusted_oid" =~ ^[a-f0-9]{40,64}$ ]]
}

# dx_review_policy_resolve <repo>
# Print small, normal, complex, binding, trusted ref, and trusted commit as TSV.
dx_review_policy_resolve() {
  [[ $# -eq 1 ]] || return 1
  local repo="$1" default_branch trusted_ref="" trusted_oid="" config=""
  local head_oid="" any_oid=""
  local values small normal complex binding
  [[ -d "$repo" ]] || return 1
  default_branch=$(dx_default_branch "$repo") || return 1
  trusted_ref=$(dx_default_branch_base_ref "$repo" "$default_branch" no-fetch 2>/dev/null || true)
  if [[ -n "$trusted_ref" ]]; then
    trusted_oid=$(git -C "$repo" rev-parse --verify "${trusted_ref}^{commit}" 2>/dev/null || true)
  fi

  if [[ ! "$trusted_oid" =~ ^[a-f0-9]{40,64}$ ]]; then
    head_oid=$(git -C "$repo" rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)
    any_oid=$(git -C "$repo" rev-list --all --reflog --max-count=1 2>/dev/null) || return 1
    [[ -z "$head_oid" && -z "$any_oid" ]] || return 1
    trusted_ref="built-in-defaults"
    trusted_oid="unborn"
  fi

  if [[ "$trusted_oid" != "unborn" ]] && \
     git -C "$repo" cat-file -e "${trusted_oid}:.dex/dex.md" 2>/dev/null; then
    config=$(git -C "$repo" show "${trusted_oid}:.dex/dex.md" 2>/dev/null) || return 1
  fi
  values=$(DX_REVIEW_POLICY_DOCUMENT="$config" python3 - <<'PY'
import os
import re

document = os.environ["DX_REVIEW_POLICY_DOCUMENT"]
defaults = {"small_clean_passes": 1, "normal_clean_passes": 3, "complex_clean_passes": 6}
lines = document.splitlines()
headings = [index for index, line in enumerate(lines) if line.strip() == "## Review Policy"]
if not headings:
    print("1\t3\t6")
    raise SystemExit(0)
if len(headings) != 1:
    raise SystemExit(1)

section = []
for line in lines[headings[0] + 1:]:
    if re.match(r"^##\s+", line):
        break
    if line.strip():
        section.append(line.strip())
if len(section) != 5 or section[0] != "| Setting | Value |":
    raise SystemExit(1)
if not re.fullmatch(r"\|\s*-+\s*\|\s*-+\s*\|", section[1]):
    raise SystemExit(1)

values = {}
row_pattern = re.compile(
    r"^\|\s*(small_clean_passes|normal_clean_passes|complex_clean_passes)\s*\|\s*([0-9]+)\s*\|$"
)
for line in section[2:]:
    match = row_pattern.fullmatch(line)
    if not match or match.group(1) in values:
        raise SystemExit(1)
    raw = match.group(2)
    if len(raw) > 2 or raw.startswith("0"):
        raise SystemExit(1)
    values[match.group(1)] = int(raw)
if set(values) != set(defaults):
    raise SystemExit(1)
small = values["small_clean_passes"]
normal = values["normal_clean_passes"]
complex_value = values["complex_clean_passes"]
if not (1 <= small <= normal <= complex_value <= 30):
    raise SystemExit(1)
print(f"{small}\t{normal}\t{complex_value}")
PY
  ) || return 1
  IFS=$'\t' read -r small normal complex <<EOF
$values
EOF
  binding=$(dx_review_policy_binding "$small" "$normal" "$complex") || return 1
  dx_review_policy_provenance_valid "$trusted_ref" "$trusted_oid" || return 1
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$small" "$normal" "$complex" "$binding" "$trusted_ref" "$trusted_oid"
}

# dx_review_policy_for_tier <repo> <tier> [expected-binding]
# Print the tier requirement, binding, trusted ref, and trusted commit as TSV.
dx_review_policy_for_tier() {
  [[ $# -eq 2 || $# -eq 3 ]] || return 1
  local repo="$1" tier="$2" expected_binding="${3:-}"
  local record small normal complex binding trusted_ref trusted_oid required
  record=$(dx_review_policy_resolve "$repo") || return 1
  IFS=$'\t' read -r small normal complex binding trusted_ref trusted_oid <<EOF
$record
EOF
  if [[ -n "$expected_binding" ]]; then
    dx_review_policy_binding_valid "$expected_binding" || return 1
    [[ "$binding" == "$expected_binding" ]] || return 1
  fi
  required=$(dx_review_policy_tier_clean_passes "$tier" "$small" "$normal" "$complex") || return 1
  printf '%s\t%s\t%s\t%s\n' "$required" "$binding" "$trusted_ref" "$trusted_oid"
}
