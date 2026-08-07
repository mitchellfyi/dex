#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-cli-help-test.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

assert_contains() {
  local needle="$1" file="$2"
  grep -Fq "$needle" "$file" || {
    printf 'missing expected text: %s\n' "$needle" >&2
    printf 'output was:\n' >&2
    cat "$file" >&2
    exit 1
  }
}

assert_unchanged() {
  local before="$1" after="$2" label="$3"
  if ! diff -r "$before" "$after" > "$TMP_DIR/${label}.diff"; then
    printf '%s changed files before completing argument validation:\n' "$label" >&2
    cat "$TMP_DIR/${label}.diff" >&2
    exit 1
  fi
}

run_entrypoint_checks() {
  local name="$1" script="$2" expected_usage="$3"
  local case_dir="$TMP_DIR/$name"
  local test_home="$case_dir/home"
  local test_repo="$case_dir/repo"
  local home_snapshot="$case_dir/home.before"
  local repo_snapshot="$case_dir/repo.before"

  mkdir -p "$test_home/.claude" "$test_repo/.dex/rules"
  printf '%s\n' '{"userSetting":"keep"}' > "$test_home/.claude/settings.json"
  printf '%s\n' '# user shell config' > "$test_home/.zshrc"
  printf '%s\n' '# Dex test project' > "$test_repo/.dex/dex.md"
  printf '%s\n' 'keep this project file' > "$test_repo/.dex/rules/user-rule.md"
  git -C "$test_repo" init -q

  cp -R "$test_home" "$home_snapshot"
  cp -R "$test_repo" "$repo_snapshot"

  (
    cd "$test_repo"
    HOME="$test_home" \
      CODEX_HOME="$test_home/.codex" \
      DEX_DIR="$ROOT" \
      DX_RTK_ENABLED=0 \
      bash "$script" --help
  ) > "$case_dir/help.out" 2>&1
  assert_contains "$expected_usage" "$case_dir/help.out"
  assert_unchanged "$home_snapshot" "$test_home" "${name}-help-home"
  assert_unchanged "$repo_snapshot" "$test_repo" "${name}-help-repo"

  if (
    cd "$test_repo"
    HOME="$test_home" \
      CODEX_HOME="$test_home/.codex" \
      DEX_DIR="$ROOT" \
      DX_RTK_ENABLED=0 \
      bash "$script" --not-an-option
  ) > "$case_dir/unknown.out" 2>&1; then
    printf '%s accepted an unknown option\n' "$name" >&2
    exit 1
  fi
  assert_contains "Unknown ${name} option: --not-an-option" "$case_dir/unknown.out"
  assert_unchanged "$home_snapshot" "$test_home" "${name}-unknown-home"
  assert_unchanged "$repo_snapshot" "$test_repo" "${name}-unknown-repo"
}

run_entrypoint_checks install "$ROOT/bin/install.sh" "Usage: dx install"
run_entrypoint_checks uninstall "$ROOT/bin/uninstall.sh" "Usage: dx uninstall"
run_entrypoint_checks status "$ROOT/bin/status.sh" "Usage: dx status"
run_entrypoint_checks config "$ROOT/bin/config.sh" "Usage: dx config"
run_entrypoint_checks uninit "$ROOT/bin/uninit.sh" "Usage: dx uninit"

printf 'CLI help tests passed\n'
