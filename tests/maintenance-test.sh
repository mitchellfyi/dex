#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-maintenance-test.XXXXXX")"

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

repo="$TMP_DIR/repo"
mkdir -p "$repo/.dex"
git -C "$TMP_DIR" init -b main repo >/dev/null
cat > "$repo/.dex/dex.md" <<'EOF'
# Test Dex Context

## Maintenance

| Setting | Value |
|---------|-------|
| enabled | true |
| default_mode | propose |
| schedule_mode | report |
| issue_mode | fix-scoped |
| auto_merge | true |
| auto_merge_method | squash |
EOF

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [[ "$expected" != "$actual" ]]; then
    printf 'assertion failed for %s: expected %s, got %s\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_eq "fix-scoped" "$(dx_maintenance_event_mode "$repo" issues "")" "issue event mode"
assert_eq "report" "$(dx_maintenance_event_mode "$repo" schedule "")" "schedule event mode"
assert_eq "propose" "$(dx_maintenance_event_mode "$repo" workflow_dispatch "")" "default event mode"
assert_eq "report" "$(dx_maintenance_event_mode "$repo" issues "report")" "explicit mode override"

(
  cd "$repo"
  assert_eq "fix-scoped" "$(bash "$ROOT/bin/maintain.sh" resolve-mode --event issues)" "CLI issue event mode"
  assert_eq "report" "$(bash "$ROOT/bin/maintain.sh" resolve-mode --event schedule)" "CLI schedule event mode"
  assert_eq "propose" "$(bash "$ROOT/bin/maintain.sh" resolve-mode --event workflow_dispatch)" "CLI default event mode"
  assert_eq "report" "$(bash "$ROOT/bin/maintain.sh" resolve-mode --event issues --explicit-mode report)" "CLI explicit mode override"
)

cat > "$repo/.dex/dex.md" <<'EOF'
# Test Dex Context

## Maintenance

| Setting | Value |
|---------|-------|
| default_mode | unexpected |
| issue_mode | also-unexpected |
EOF

assert_eq "report" "$(dx_maintenance_event_mode "$repo" issues "")" "invalid mode fallback"

printf 'maintenance tests passed\n'
