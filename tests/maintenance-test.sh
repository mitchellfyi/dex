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
export PATH="$TMP_DIR/bin:$PATH"
mkdir -p "$TMP_DIR/bin"

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

assert_contains() {
  local needle="$1" file="$2"
  if ! grep -Fq "$needle" "$file"; then
    printf 'missing expected text: %s\n' "$needle" >&2
    printf 'output was:\n' >&2
    cat "$file" >&2
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

cat > "$TMP_DIR/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "repo" && "${2:-}" == "view" ]]; then
  printf '%s\n' "example/repo"
  exit 0
fi

if [[ "${1:-}" == "pr" && "${2:-}" == "edit" ]]; then
  printf '%s\n' "$*" >> "${GH_FAKE_CALLS:?}"
  exit 0
fi

if [[ "${1:-}" == "api" ]]; then
  case "${GH_FAKE_PR_CASE:-persisted}" in
    persisted)
      cat <<'JSON'
{"user":{"login":"author"},"requested_reviewers":[{"login":"reviewer"}],"requested_teams":[]}
JSON
      ;;
    missing)
      cat <<'JSON'
{"user":{"login":"author"},"requested_reviewers":[],"requested_teams":[]}
JSON
      ;;
    author)
      cat <<'JSON'
{"user":{"login":"reviewer"},"requested_reviewers":[],"requested_teams":[]}
JSON
      ;;
    copilot)
      cat <<'JSON'
{"user":{"login":"author"},"requested_reviewers":[{"login":"github-copilot"}],"requested_teams":[]}
JSON
      ;;
  esac
  exit 0
fi

printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
SH
chmod +x "$TMP_DIR/bin/gh"
export GH_FAKE_CALLS="$TMP_DIR/gh-calls.log"

GH_FAKE_PR_CASE=persisted dx_maintenance_request_reviewer 7 reviewer example/repo > "$TMP_DIR/reviewer-persisted.out" 2>&1
assert_contains "pr edit 7 --repo example/repo --add-reviewer reviewer" "$GH_FAKE_CALLS"

GH_FAKE_PR_CASE=missing dx_maintenance_request_reviewer 7 reviewer example/repo > "$TMP_DIR/reviewer-missing.out" 2>&1
assert_contains "no review request persisted" "$TMP_DIR/reviewer-missing.out"

GH_FAKE_PR_CASE=author dx_maintenance_request_reviewer 7 reviewer example/repo > "$TMP_DIR/reviewer-author.out" 2>&1
assert_contains "does not allow requesting the PR author" "$TMP_DIR/reviewer-author.out"

GH_FAKE_PR_CASE=copilot dx_maintenance_request_reviewer 7 Copilot example/repo > "$TMP_DIR/reviewer-copilot.out" 2>&1
assert_contains "pr edit 7 --repo example/repo --add-reviewer @copilot" "$GH_FAKE_CALLS"

printf 'maintenance tests passed\n'
