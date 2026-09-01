# shellcheck shell=bash
# Resolve Dex's fixed clean-pass policy. Repository policy tables were removed
# in v2 so every checkout receives the same 1/2/3 assurance floor.

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
  printf 'review-policy-v2:small=%s,normal=%s,complex=%s' \
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
  [[ "$trusted_ref" == "global-defaults" && "$trusted_oid" == "v2" ]]
}

# dx_review_policy_resolve <repo>
# Print small, normal, complex, binding, provenance, and policy version as TSV.
dx_review_policy_resolve() {
  [[ $# -eq 1 ]] || return 1
  local repo="$1" small=1 normal=2 complex=3 binding
  [[ -d "$repo" ]] || return 1
  binding=$(dx_review_policy_binding "$small" "$normal" "$complex") || return 1
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$small" "$normal" "$complex" "$binding" "global-defaults" "v2"
}

# dx_review_policy_for_tier <repo> <tier> [expected-binding]
# Print the tier requirement, binding, provenance, and policy version as TSV.
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
