#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-init-reliability-test.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export CODEX_HOME="$TMP_DIR/codex-home"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
export DX_TOOL_DIR="$TMP_DIR/tools"
export DX_RUN_ROOT="$TMP_DIR/runs"
export DX_PROVIDER_PROFILE="claude-subscription"
export DX_RTK_ENABLED=0
export DEX_SKIP_TOOL_BOOTSTRAP=1
export DEXCODE_SYNC=0
export DEXCODE_CONTEXT_SYNC=0

mkdir -p "$HOME" "$TMP_DIR/bin"
export PATH="$TMP_DIR/bin:/usr/bin:/bin:/usr/sbin:/sbin"

cat > "$TMP_DIR/bin/claude" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

case "${DEX_TEST_CLAUDE_MODE:-empty}" in
  fail)
    exit 42
    ;;
  empty)
    exit 0
    ;;
  success)
    cat > .dex/dex.md <<'DEXMD'
# Dex — Test Project

## Tech Stack
Bash

## Quality Gates
Run the shell tests.

## Project Structure
Shell scripts and tests.
DEXMD
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Analysis complete"}]}}'
    ;;
  *)
    printf 'unknown fake Claude mode: %s\n' "$DEX_TEST_CLAUDE_MODE" >&2
    exit 2
    ;;
esac
SH
chmod +x "$TMP_DIR/bin/claude"

new_repo() {
  local name="$1" repo
  repo="$TMP_DIR/$name"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email dex@example.test
  git -C "$repo" config user.name "Dex Test"
  printf '%s\n' "$repo"
}

run_init() {
  local repo="$1" mode="$2" output_file="$3"
  local status
  set +e
  (
    cd "$repo"
    DEX_TEST_CLAUDE_MODE="$mode" bash "$ROOT/bin/init.sh" --skip-config
  ) > "$output_file" 2>&1
  status=$?
  set -e
  printf '%s\n' "$status"
}

run_init_without_analysis() {
  local repo="$1" output_file="$2"
  (
    cd "$repo"
    bash "$ROOT/bin/init.sh" --skip-analysis --skip-config
  ) > "$output_file" 2>&1
}

assert_contains() {
  local expected="$1" file="$2"
  if ! grep -Fq "$expected" "$file"; then
    printf 'expected %s to contain %s\n' "$file" "$expected" >&2
    exit 1
  fi
}

assert_not_contains() {
  local unexpected="$1" file="$2"
  if grep -Fq "$unexpected" "$file"; then
    printf 'expected %s not to contain %s\n' "$file" "$unexpected" >&2
    exit 1
  fi
}

assert_run_status() {
  local output_file="$1" expected_status="$2"
  local run_id summary_file actual_status
  run_id=$(sed -n 's/^\[info\]  Run id: //p' "$output_file" | head -n 1)
  [[ -n "$run_id" ]] || {
    printf 'could not find run id in %s\n' "$output_file" >&2
    exit 1
  }
  summary_file="$DX_RUN_ROOT/$run_id/summary.json"
  [[ -f "$summary_file" ]] || {
    printf 'missing run summary: %s\n' "$summary_file" >&2
    exit 1
  }
  actual_status=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["status"])' "$summary_file")
  [[ "$actual_status" == "$expected_status" ]] || {
    printf 'expected run status %s, got %s\n' "$expected_status" "$actual_status" >&2
    exit 1
  }
}

gitignore_repo=$(new_repo gitignore-repo)
mkdir -p "$gitignore_repo/.dex"
printf 'custom-cache/' > "$gitignore_repo/.dex/.gitignore"
run_init_without_analysis "$gitignore_repo" "$TMP_DIR/gitignore-first.out"
run_init_without_analysis "$gitignore_repo" "$TMP_DIR/gitignore-second.out"
[[ "$(grep -c '^worktrees/$' "$gitignore_repo/.dex/.gitignore")" -eq 1 ]] || {
  printf 'worktrees/ was not added exactly once\n' >&2
  exit 1
}
[[ "$(sed -n '1p' "$gitignore_repo/.dex/.gitignore")" == "custom-cache/" ]] || {
  printf 'existing .dex/.gitignore content was not preserved\n' >&2
  exit 1
}
git -C "$gitignore_repo" check-ignore -q .dex/worktrees/example
assert_contains ".dex/.gitignore already ignores worktrees/" "$TMP_DIR/gitignore-second.out"

failure_repo=$(new_repo failure-repo)
failure_status=$(run_init "$failure_repo" fail "$TMP_DIR/failure.out")
[[ "$failure_status" -eq 42 ]] || {
  printf 'expected failed analysis to exit 42, got %s\n' "$failure_status" >&2
  exit 1
}
assert_contains "Codebase analysis exited with code 42." "$TMP_DIR/failure.out"
assert_contains "project-specific config is incomplete" "$TMP_DIR/failure.out"
assert_not_contains "Init complete for:" "$TMP_DIR/failure.out"
assert_not_contains "Claude analyzed the codebase" "$TMP_DIR/failure.out"
assert_run_status "$TMP_DIR/failure.out" "failed"

empty_repo=$(new_repo empty-repo)
empty_status=$(run_init "$empty_repo" empty "$TMP_DIR/empty.out")
[[ "$empty_status" -eq 1 ]] || {
  printf 'expected empty analysis to exit 1, got %s\n' "$empty_status" >&2
  exit 1
}
assert_contains "Codebase analysis exited without returning any provider output." "$TMP_DIR/empty.out"
assert_contains "project-specific config is incomplete" "$TMP_DIR/empty.out"
assert_not_contains "Init complete for:" "$TMP_DIR/empty.out"
assert_not_contains "Claude analyzed the codebase" "$TMP_DIR/empty.out"
assert_run_status "$TMP_DIR/empty.out" "failed"

success_repo=$(new_repo success-repo)
success_status=$(run_init "$success_repo" success "$TMP_DIR/success.out")
[[ "$success_status" -eq 0 ]] || {
  printf 'expected successful analysis to exit 0, got %s\n' "$success_status" >&2
  exit 1
}
assert_contains "Init complete for:" "$TMP_DIR/success.out"
assert_contains "Claude analyzed the codebase and generated project-specific config" "$TMP_DIR/success.out"
assert_run_status "$TMP_DIR/success.out" "completed"

printf 'init reliability tests passed\n'
