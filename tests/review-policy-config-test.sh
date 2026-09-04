#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-review-policy-config-test.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# shellcheck source=lib/git.sh
source "$ROOT/lib/git.sh"
# shellcheck source=lib/review.sh
source "$ROOT/lib/review.sh"
# shellcheck source=lib/review-policy.sh
source "$ROOT/lib/review-policy.sh"


assert_eq() {
  local expected="$1" actual="$2" label="$3"
  [[ "$expected" == "$actual" ]] || fail "$label: expected '$expected', got '$actual'"
}

assert_fixed_policy() {
  local repo="$1" label="$2"
  local record small normal complex binding trusted_ref trusted_version
  record=$(dx_review_policy_resolve "$repo")
  IFS=$'\t' read -r small normal complex binding trusted_ref trusted_version <<EOF
$record
EOF
  assert_eq "1" "$small" "$label small gate"
  assert_eq "2" "$normal" "$label normal gate"
  assert_eq "3" "$complex" "$label complex gate"
  assert_eq "$(dx_review_policy_binding 1 2 3)" "$binding" "$label binding"
  assert_eq "global-defaults" "$trusted_ref" "$label provenance"
  assert_eq "v2" "$trusted_version" "$label version"
}

write_policy() {
  local target="$1" small="$2" normal="$3" complex="$4"
  mkdir -p "$(dirname "$target")"
  {
    printf '%s\n\n' '# Project context'
    printf '%s\n' '## Review Policy'
    printf '%s\n' '| Setting | Value |'
    printf '%s\n' '|---------|-------|'
    printf '| small_clean_passes | %s |\n' "$small"
    printf '| normal_clean_passes | %s |\n' "$normal"
    printf '| complex_clean_passes | %s |\n' "$complex"
  } > "$target"
}

seed="$TMP_DIR/seed"
origin="$TMP_DIR/origin.git"
repo="$TMP_DIR/repo"
git init -q -b main "$seed"
git -C "$seed" config user.name "Dex Test"
git -C "$seed" config user.email "dex-test@example.com"
write_policy "$seed/.dex/dex.md" 2 5 8
git -C "$seed" add .dex/dex.md
git -C "$seed" commit -qm "test: configure review policy"
git clone -q --bare "$seed" "$origin"
git clone -q "$origin" "$repo"
git -C "$repo" config user.name "Dex Test"
git -C "$repo" config user.email "dex-test@example.com"
git -C "$repo" switch -qc feature

assert_fixed_policy "$repo" "custom repository table is ignored"
binding=$(dx_review_policy_binding 1 2 3)
assert_eq "1" "$(dx_review_policy_tier_clean_passes small 1 2 3)" "small policy lookup"
assert_eq "2" "$(dx_review_policy_tier_clean_passes standard 1 2 3)" "normal alias lookup"
assert_eq "3" "$(dx_review_policy_tier_clean_passes high-risk 1 2 3)" "complex alias lookup"
assert_eq "3" "$(dx_review_policy_tier_max_waves small)" "small wave budget"
assert_eq "6" "$(dx_review_policy_tier_max_waves standard)" "normal wave budget"
assert_eq "9" "$(dx_review_policy_tier_max_waves high-risk)" "complex wave budget"
assert_rejected "$LINENO" dx_review_policy_tier_max_waves unknown
IFS=$'\t' read -r tier_required tier_binding _ <<EOF
$(dx_review_policy_for_tier "$repo" normal)
EOF
assert_eq "2" "$tier_required" "trusted tier lookup"
assert_eq "$binding" "$tier_binding" "trusted tier binding"
assert_eq "2" "$(dx_review_policy_for_tier "$repo" normal "$binding" | cut -f1)" \
  "expected binding lookup"
if dx_review_policy_for_tier "$repo" normal "$(dx_review_policy_binding 1 3 6)" >/dev/null 2>&1; then
  fail "tier lookup accepted a different policy binding"
fi

write_policy "$repo/.dex/dex.md" 1 1 1
git -C "$repo" add .dex/dex.md
git -C "$repo" commit -qm "test: attempt to lower policy from feature"
assert_fixed_policy "$repo" "candidate policy is ignored"

missing="$TMP_DIR/missing"
git init -q -b main "$missing"
git -C "$missing" config user.name "Dex Test"
git -C "$missing" config user.email "dex-test@example.com"
printf '%s\n' '# Project context' > "$missing/README.md"
git -C "$missing" add README.md
git -C "$missing" commit -qm "test: omit review policy"
assert_eq $'1\t2\t3' "$(dx_review_policy_resolve "$missing" | cut -f1-3)" \
  "missing policy uses recommended defaults"

invalid="$TMP_DIR/invalid"
git clone -q "$origin" "$invalid"
git -C "$invalid" config user.name "Dex Test"
git -C "$invalid" config user.email "dex-test@example.com"
write_policy "$invalid/.dex/dex.md" 6 5 8
git -C "$invalid" add .dex/dex.md
git -C "$invalid" commit -qm "test: make default policy non-monotonic"
git -C "$invalid" update-ref refs/remotes/origin/main HEAD
assert_fixed_policy "$invalid" "invalid repository policy is ignored"

write_policy "$invalid/.dex/dex.md" 1 2 31
git -C "$invalid" add .dex/dex.md
git -C "$invalid" commit -qm "test: exceed review policy limit"
git -C "$invalid" update-ref refs/remotes/origin/main HEAD
assert_fixed_policy "$invalid" "out-of-range repository policy is ignored"

unborn="$TMP_DIR/unborn"
git init -q -b main "$unborn"
write_policy "$unborn/.dex/dex.md" 1 1 1
printf 'uncommitted\n' > "$unborn/app.txt"
IFS=$'\t' read -r unborn_small unborn_normal unborn_complex unborn_binding \
  unborn_ref unborn_oid <<EOF
$(dx_review_policy_resolve "$unborn")
EOF
assert_eq "1" "$unborn_small" "unborn built-in small gate"
assert_eq "2" "$unborn_normal" "unborn built-in normal gate"
assert_eq "3" "$unborn_complex" "unborn built-in complex gate"
assert_eq "$(dx_review_policy_binding 1 2 3)" "$unborn_binding" \
  "unborn built-in policy binding"
assert_eq "global-defaults" "$unborn_ref" "unborn policy provenance ref"
assert_eq "v2" "$unborn_oid" "unborn policy provenance version"
dx_review_policy_provenance_valid "$unborn_ref" "$unborn_oid"
if dx_review_policy_provenance_valid origin/main v2; then
  fail "mixed unborn policy provenance was accepted"
fi
if dx_review_policy_provenance_valid global-defaults v1; then
  fail "built-in policy sentinel accepted a commit OID"
fi

detached="$TMP_DIR/detached"
git init -q -b main "$detached"
git -C "$detached" config user.name "Dex Test"
git -C "$detached" config user.email "dex-test@example.com"
printf 'committed\n' > "$detached/app.txt"
git -C "$detached" add app.txt
git -C "$detached" commit -qm "test: create detached policy fixture"
git -C "$detached" switch -q --detach
git -C "$detached" branch -D main >/dev/null
assert_fixed_policy "$detached" "detached repository uses global policy"

printf 'review-policy-config-test passed\n'
