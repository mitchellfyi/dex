#!/usr/bin/env bash
set -euo pipefail
umask 022

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-init-uninit-ownership.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export CODEX_HOME="$TMP_DIR/codex-home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
export DX_TOOL_DIR="$TMP_DIR/tools"
export DX_RUN_ROOT="$TMP_DIR/runs"
export DX_RTK_ENABLED=0
export DEX_SKIP_TOOL_BOOTSTRAP=1
export DEXCODE_SYNC=0
export DEXCODE_CONTEXT_SYNC=0

mkdir -p "$HOME"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

new_repo() {
  local name="$1"
  local repo="$TMP_DIR/$name"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email dex@example.test
  git -C "$repo" config user.name "Dex Test"
  printf '%s\n' "$repo"
}

run_init() {
  local repo="$1" output="$2"
  (
    cd "$repo"
    bash "$ROOT/bin/init.sh" --skip-analysis --skip-config
  ) > "$output" 2>&1
}

run_init_bounded() {
  local repo="$1"
  python3 - "$repo" "$ROOT/bin/init.sh" <<'PY'
import subprocess
import sys

try:
    result = subprocess.run(
        ["bash", sys.argv[2], "--skip-analysis", "--skip-config"],
        cwd=sys.argv[1],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=5,
        check=False,
    )
except subprocess.TimeoutExpired as exc:
    if exc.stdout:
        sys.stdout.buffer.write(exc.stdout)
    raise SystemExit(124) from exc

sys.stdout.buffer.write(result.stdout)
raise SystemExit(result.returncode)
PY
}

run_uninit() {
  local repo="$1" output="$2"
  (
    cd "$repo"
    bash "$ROOT/bin/uninit.sh"
  ) > "$output" 2>&1
}


assert_absent() {
  [[ ! -e "$1" ]] || {
    printf 'expected path to be absent: %s\n' "$1" >&2
    exit 1
  }
}


file_mode() {
  dx_path_mode "$1"
}

# A configured hook directory remains untouched. Dex proxies each active hook
# while installed and restores the exact local configuration on uninit.
coexist_repo=$(new_repo coexist)
mkdir -p "$coexist_repo/.githooks" "$coexist_repo/.dex/rules" "$coexist_repo/.github"
cat > "$coexist_repo/.githooks/pre-commit" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
printf 'pre-commit\n' >> "$DEX_TEST_HOOK_LOG"
HOOK
cat > "$coexist_repo/.githooks/commit-msg" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
printf 'commit-msg:%s\n' "$(sed -n '1p' "$1")" >> "$DEX_TEST_HOOK_LOG"
HOOK
chmod +x "$coexist_repo/.githooks/pre-commit" "$coexist_repo/.githooks/commit-msg"
printf '# User Dex context\n' > "$coexist_repo/.dex/dex.md"
printf 'custom-cache/\n' > "$coexist_repo/.dex/.gitignore"
printf 'keep this rule\n' > "$coexist_repo/.dex/rules/user.md"
printf 'custom PR template\n' > "$coexist_repo/.github/pull_request_template.md"
git -C "$coexist_repo" config --local core.hooksPath .githooks
original_pre_commit=$(shasum -a 256 "$coexist_repo/.githooks/pre-commit" | awk '{print $1}')
original_commit_msg=$(shasum -a 256 "$coexist_repo/.githooks/commit-msg" | awk '{print $1}')

run_init "$coexist_repo" "$TMP_DIR/coexist-init-first.out"
run_init "$coexist_repo" "$TMP_DIR/coexist-init-second.out"
coexist_hook_dir=$(dx_attribution_hook_dir "$coexist_repo")
[[ "$(git -C "$coexist_repo" config --local --get core.hooksPath)" == "$coexist_hook_dir" ]] || assert_at $LINENO

printf 'content\n' > "$coexist_repo/file.txt"
git -C "$coexist_repo" add file.txt
DEX_TEST_HOOK_LOG="$TMP_DIR/hook.log" git -C "$coexist_repo" commit -q -m "feat: verify hook proxy"
[[ "$(grep -c '^pre-commit$' "$TMP_DIR/hook.log")" -eq 1 ]] || assert_at $LINENO
[[ "$(grep -c '^commit-msg:feat: verify hook proxy$' "$TMP_DIR/hook.log")" -eq 1 ]] || assert_at $LINENO
git -C "$coexist_repo" log -1 --pretty=%B > "$TMP_DIR/coexist-message.txt"
assert_contains "Co-Authored-By: Dex <noreply@dexcode.ai>" "$TMP_DIR/coexist-message.txt"

run_uninit "$coexist_repo" "$TMP_DIR/coexist-uninit.out"
[[ "$(git -C "$coexist_repo" config --local --get core.hooksPath)" == ".githooks" ]] || assert_at $LINENO
[[ "$(shasum -a 256 "$coexist_repo/.githooks/pre-commit" | awk '{print $1}')" == "$original_pre_commit" ]] || assert_at $LINENO
[[ "$(shasum -a 256 "$coexist_repo/.githooks/commit-msg" | awk '{print $1}')" == "$original_commit_msg" ]] || assert_at $LINENO
assert_absent "$coexist_hook_dir"
assert_file "$coexist_repo/.dex/dex.md"
assert_file "$coexist_repo/.dex/.gitignore"
assert_file "$coexist_repo/.dex/rules/user.md"
[[ "$(cat "$coexist_repo/.github/pull_request_template.md")" == "custom PR template" ]] || assert_at $LINENO
assert_absent "$coexist_repo/.dex/memory/index.md"

# A later init may add required pointers or ignore entries around user content,
# but that merged file is no longer Dex-owned and must survive uninit.
modified_reinit_repo=$(new_repo modified-reinit)
run_init "$modified_reinit_repo" "$TMP_DIR/modified-reinit-first.out"
printf 'custom user instructions\n' > "$modified_reinit_repo/.dex/AGENTS.md"
printf 'custom Claude instructions\n' > "$modified_reinit_repo/.dex/CLAUDE.md"
printf 'custom-cache/\n' >> "$modified_reinit_repo/.dex/.gitignore"
chmod 0640 "$modified_reinit_repo/.dex/AGENTS.md"
run_init "$modified_reinit_repo" "$TMP_DIR/modified-reinit-second.out"
assert_contains "custom user instructions" "$modified_reinit_repo/.dex/AGENTS.md"
assert_contains "custom Claude instructions" "$modified_reinit_repo/.dex/CLAUDE.md"
assert_contains "custom-cache/" "$modified_reinit_repo/.dex/.gitignore"
[[ "$(file_mode "$modified_reinit_repo/.dex/AGENTS.md")" == "640" ]] || assert_at $LINENO
run_uninit "$modified_reinit_repo" "$TMP_DIR/modified-reinit-uninit.out"
assert_file "$modified_reinit_repo/.dex/AGENTS.md"
assert_file "$modified_reinit_repo/.dex/CLAUDE.md"
assert_file "$modified_reinit_repo/.dex/.gitignore"
assert_contains "custom user instructions" "$modified_reinit_repo/.dex/AGENTS.md"
assert_contains "custom Claude instructions" "$modified_reinit_repo/.dex/CLAUDE.md"
assert_contains "custom-cache/" "$modified_reinit_repo/.dex/.gitignore"

# Historical fixed temp-file names are ordinary user paths. Atomic init writes
# use unique siblings and leave these files untouched.
temp_name_repo=$(new_repo historical-temp-names)
mkdir -p "$temp_name_repo/.dex/memory"
printf 'valuable AGENTS scratch data\n' > "$temp_name_repo/.dex/AGENTS.md.tmp"
printf 'valuable CLAUDE scratch data\n' > "$temp_name_repo/.dex/CLAUDE.md.tmp"
printf 'valuable memory scratch data\n' > "$temp_name_repo/.dex/memory/index.md.tmp"
run_init "$temp_name_repo" "$TMP_DIR/temp-name-init.out"
[[ "$(file_mode "$temp_name_repo/.dex/dex.md")" == "644" ]] || assert_at $LINENO
[[ "$(file_mode "$temp_name_repo/.github/pull_request_template.md")" == "644" ]] || assert_at $LINENO
[[ "$(cat "$temp_name_repo/.dex/AGENTS.md.tmp")" == "valuable AGENTS scratch data" ]] || assert_at $LINENO
[[ "$(cat "$temp_name_repo/.dex/CLAUDE.md.tmp")" == "valuable CLAUDE scratch data" ]] || assert_at $LINENO
[[ "$(cat "$temp_name_repo/.dex/memory/index.md.tmp")" == "valuable memory scratch data" ]] || assert_at $LINENO
run_uninit "$temp_name_repo" "$TMP_DIR/temp-name-uninit.out"
assert_file "$temp_name_repo/.dex/AGENTS.md.tmp"
assert_file "$temp_name_repo/.dex/CLAUDE.md.tmp"
assert_file "$temp_name_repo/.dex/memory/index.md.tmp"

# Clean installs remove unchanged generated files. If a generated file is
# edited, uninit keeps it instead of guessing that the content is disposable.
owned_repo=$(new_repo owned)
run_init "$owned_repo" "$TMP_DIR/owned-init.out"
owned_hook_dir=$(dx_attribution_hook_dir "$owned_repo")
owned_project_state=$(dx_project_state_file "$owned_repo")
cp "$owned_repo/.dex/dex.md" "$TMP_DIR/owned-original-dex.md"
[[ "$(git -C "$owned_repo" config --local --get core.hooksPath)" == "$owned_hook_dir" ]] || assert_at $LINENO
printf '\nUser note.\n' >> "$owned_repo/.dex/dex.md"
printf '\nUser section.\n' >> "$owned_repo/.github/pull_request_template.md"
run_uninit "$owned_repo" "$TMP_DIR/owned-uninit.out"
if git -C "$owned_repo" config --local --get core.hooksPath >/dev/null 2>&1; then
  printf 'Dex core.hooksPath override was not removed\n' >&2
  exit 1
fi
assert_absent "$owned_hook_dir"
assert_file "$owned_repo/.dex/dex.md"
assert_file "$owned_repo/.github/pull_request_template.md"
assert_absent "$owned_project_state"
assert_contains "Preserving modified or user-owned file: .dex/dex.md" "$TMP_DIR/owned-uninit.out"
assert_contains "Preserving modified or user-owned file: .github/pull_request_template.md" \
  "$TMP_DIR/owned-uninit.out"
cp "$TMP_DIR/owned-original-dex.md" "$owned_repo/.dex/dex.md"
run_uninit "$owned_repo" "$TMP_DIR/owned-second-uninit.out"
assert_file "$owned_repo/.dex/dex.md"

# Replacing the generated template's parent with a symlink must not let uninit
# delete an identical file outside the repository.
template_escape_repo=$(new_repo template-escape)
run_init "$template_escape_repo" "$TMP_DIR/template-escape-init.out"
template_escape_target="$TMP_DIR/template-escape-target"
mv "$template_escape_repo/.github" "$template_escape_target"
ln -s "$template_escape_target" "$template_escape_repo/.github"
run_uninit "$template_escape_repo" "$TMP_DIR/template-escape-uninit.out"
assert_file "$template_escape_target/pull_request_template.md"
[[ -L "$template_escape_repo/.github" ]] || assert_at $LINENO
assert_contains "Preserving modified or user-owned file: .github/pull_request_template.md" \
  "$TMP_DIR/template-escape-uninit.out"

# A marker identifies the file's purpose, not its ownership. Editing a proxy
# while leaving that marker intact must still make uninit preserve the file.
modified_hook_repo=$(new_repo modified-hook)
run_init "$modified_hook_repo" "$TMP_DIR/modified-hook-init.out"
modified_hook_dir=$(dx_attribution_hook_dir "$modified_hook_repo")
printf '\n# user-owned hook extension\n' >> "$modified_hook_dir/commit-msg"
run_uninit "$modified_hook_repo" "$TMP_DIR/modified-hook-uninit.out"
assert_file "$modified_hook_dir/commit-msg"
assert_contains "# Dex-managed hook proxy." "$modified_hook_dir/commit-msg"
assert_contains "# user-owned hook extension" "$modified_hook_dir/commit-msg"
assert_contains "Preserving modified hook:" "$TMP_DIR/modified-hook-uninit.out"
if git -C "$modified_hook_repo" config --local --get core.hooksPath >/dev/null 2>&1; then
  printf 'Dex core.hooksPath override was not removed for a modified proxy\n' >&2
  exit 1
fi

# Permission-only changes are modifications too. Exact content hashes do not
# authorize deleting a file or hook after its mode changes.
mode_repo=$(new_repo mode-only-modifications)
run_init "$mode_repo" "$TMP_DIR/mode-init.out"
mode_hook_dir=$(dx_attribution_hook_dir "$mode_repo")
chmod 0755 "$mode_repo/.dex/dex.md"
chmod 0600 "$mode_repo/.github/pull_request_template.md"
chmod 0700 "$mode_hook_dir/commit-msg"
run_uninit "$mode_repo" "$TMP_DIR/mode-uninit.out"
assert_file "$mode_repo/.dex/dex.md"
assert_file "$mode_repo/.github/pull_request_template.md"
assert_file "$mode_hook_dir/commit-msg"
[[ "$(file_mode "$mode_repo/.dex/dex.md")" == "755" ]] || assert_at $LINENO
[[ "$(file_mode "$mode_repo/.github/pull_request_template.md")" == "600" ]] || assert_at $LINENO
[[ "$(file_mode "$mode_hook_dir/commit-msg")" == "700" ]] || assert_at $LINENO
assert_contains "Preserving modified hook:" "$TMP_DIR/mode-uninit.out"
assert_contains "Preserving modified or user-owned file: .dex/dex.md" "$TMP_DIR/mode-uninit.out"
assert_contains "Preserving modified or user-owned file: .github/pull_request_template.md" \
  "$TMP_DIR/mode-uninit.out"

# Hook receipts never authorize traversal through a replaced proxy directory.
hook_escape_repo=$(new_repo hook-escape)
run_init "$hook_escape_repo" "$TMP_DIR/hook-escape-init.out"
hook_escape_dir=$(dx_attribution_hook_dir "$hook_escape_repo")
hook_escape_target="$TMP_DIR/hook-escape-target"
mv "$hook_escape_dir" "$hook_escape_target"
ln -s "$hook_escape_target" "$hook_escape_dir"
hook_escape_status=0
run_uninit "$hook_escape_repo" "$TMP_DIR/hook-escape-uninit.out" || hook_escape_status=$?
[[ "$hook_escape_status" -ne 0 ]] || assert_at $LINENO
assert_file "$hook_escape_target/commit-msg"
[[ -L "$hook_escape_dir" ]] || assert_at $LINENO
assert_contains "refusing to follow a symlinked hook proxy directory" "$TMP_DIR/hook-escape-uninit.out"
if git -C "$hook_escape_repo" config --local --get core.hooksPath >/dev/null 2>&1; then
  printf 'core.hooksPath remained on a rejected symlinked proxy\n' >&2
  exit 1
fi

# An unchanged clean install is removed completely, including both provenance
# records in the repository's Git directory.
clean_repo=$(new_repo clean)
run_init "$clean_repo" "$TMP_DIR/clean-init.out"
clean_git_dir=$(git -C "$clean_repo" rev-parse --path-format=absolute --absolute-git-dir)
clean_attribution_state=$(dx_attribution_state_file "$clean_repo")
clean_repo_key=$(cd "$clean_repo" && dx_session_repo_key)
mkdir -p "$DX_STATE_DIR" "$DX_LOOP_DIR"
printf '3\n' > "$DX_STATE_DIR/$clean_repo_key-inplace-task.phase"
printf 'workspace_mode=in-place\n' > "$DX_STATE_DIR/$clean_repo_key-inplace-task.meta"
printf '1\n' > "$DX_LOOP_DIR/$clean_repo_key-worktree-removed.state"
printf '1\n' > "$DX_LOOP_DIR/init-$clean_repo_key-123-456-789.state"
printf 'keep\n' > "$DX_STATE_DIR/repo-unrelated-123-branch-main.phase"
printf 'task-clean:%s:in-place\n' "$clean_repo" > "$DX_STATE_DIR/last-session"
run_uninit "$clean_repo" "$TMP_DIR/clean-uninit.out"
assert_absent "$clean_repo/.dex"
assert_absent "$clean_repo/.github"
assert_absent "$clean_git_dir/dex-project-state.json"
assert_absent "$clean_attribution_state"
assert_absent "$DX_STATE_DIR/$clean_repo_key-inplace-task.phase"
assert_absent "$DX_STATE_DIR/$clean_repo_key-inplace-task.meta"
assert_absent "$DX_LOOP_DIR/$clean_repo_key-worktree-removed.state"
assert_absent "$DX_LOOP_DIR/init-$clean_repo_key-123-456-789.state"
assert_absent "$DX_STATE_DIR/last-session"
assert_file "$DX_STATE_DIR/repo-unrelated-123-branch-main.phase"

# A hook-path change made after init belongs to the user and wins over the
# restoration record.
changed_repo=$(new_repo changed)
run_init "$changed_repo" "$TMP_DIR/changed-init.out"
git -C "$changed_repo" config --local core.hooksPath .new-hooks
run_uninit "$changed_repo" "$TMP_DIR/changed-uninit.out"
[[ "$(git -C "$changed_repo" config --local --get core.hooksPath)" == ".new-hooks" ]] || assert_at $LINENO
assert_contains "preserving its current value" "$TMP_DIR/changed-uninit.out"

# Repositories that use Git's worktree config keep the hook setting in the same
# scope, so a local override cannot silently mask or fail to replace it.
worktree_config_repo=$(new_repo worktree-config)
mkdir -p "$worktree_config_repo/.worktree-hooks"
git -C "$worktree_config_repo" config extensions.worktreeConfig true
git -C "$worktree_config_repo" config --worktree core.hooksPath .worktree-hooks
run_init "$worktree_config_repo" "$TMP_DIR/worktree-config-init.out"
worktree_config_hook_dir=$(dx_attribution_hook_dir "$worktree_config_repo")
[[ "$(git -C "$worktree_config_repo" config --worktree --get core.hooksPath)" == "$worktree_config_hook_dir" ]] || assert_at $LINENO
if git -C "$worktree_config_repo" config --local --get core.hooksPath >/dev/null 2>&1; then
  printf 'worktree hook config was incorrectly written to local scope\n' >&2
  exit 1
fi
run_uninit "$worktree_config_repo" "$TMP_DIR/worktree-config-uninit.out"
[[ "$(git -C "$worktree_config_repo" config --worktree --get core.hooksPath)" == ".worktree-hooks" ]] || assert_at $LINENO

# Local hook configuration is shared, while project files and templates belong
# to each checkout. Uninitializing one checkout keeps the shared proxy alive
# until the final initialized worktree is removed.
shared_repo=$(new_repo shared-local-worktrees)
printf 'initial\n' > "$shared_repo/file.txt"
git -C "$shared_repo" add file.txt
git -C "$shared_repo" commit -q -m "chore: initialize shared worktree fixture"
git -C "$shared_repo" branch shared-linked
git -C "$shared_repo" branch shared-linked-123-456-789
mkdir -p "$shared_repo/.dex/worktrees"
shared_linked="$shared_repo/.dex/worktrees/shared-linked"
shared_numeric_sibling="$shared_repo/.dex/worktrees/shared-linked-123-456-789"
git -C "$shared_repo" worktree add -q "$shared_linked" shared-linked
git -C "$shared_repo" worktree add -q "$shared_numeric_sibling" shared-linked-123-456-789
run_init "$shared_repo" "$TMP_DIR/shared-main-init.out"
run_init "$shared_linked" "$TMP_DIR/shared-linked-init.out"
shared_state=$(dx_attribution_state_file "$shared_repo")
shared_proxy=$(dx_attribution_hook_dir "$shared_repo")
shared_linked_project_state=$(dx_project_state_file "$shared_linked")
shared_main_session=$(cd "$shared_repo" && dx_session_id)
shared_linked_session=$(cd "$shared_linked" && dx_session_id)
shared_sibling_session=$(cd "$shared_repo" && dx_session_id shared-linked-fix)
shared_numeric_sibling_session=$(cd "$shared_numeric_sibling" && dx_session_id)
mkdir -p "$DX_STATE_DIR" "$DX_LOOP_DIR"
printf 'main\n' > "$DX_STATE_DIR/$shared_main_session.phase"
printf 'main\n' > "$DX_LOOP_DIR/$shared_main_session.state"
printf 'main\n' > "$DX_LOOP_DIR/refine-$shared_main_session-123-456-789.state"
printf 'linked\n' > "$DX_STATE_DIR/$shared_linked_session.phase"
printf 'linked\n' > "$DX_LOOP_DIR/$shared_linked_session.state"
printf 'linked\n' > "$DX_LOOP_DIR/$shared_linked_session-123-456-789.state"
printf 'sibling\n' > "$DX_STATE_DIR/$shared_sibling_session.phase"
printf 'numeric sibling\n' > "$DX_STATE_DIR/$shared_numeric_sibling_session.phase"
assert_file "$shared_repo/.github/pull_request_template.md"
assert_file "$shared_linked/.github/pull_request_template.md"

run_uninit "$shared_linked" "$TMP_DIR/shared-linked-uninit.out"
assert_absent "$shared_linked/.github"
assert_absent "$shared_linked_project_state"
assert_file "$shared_repo/.github/pull_request_template.md"
assert_file "$shared_state"
assert_file "$shared_proxy/commit-msg"
assert_file "$DX_STATE_DIR/$shared_main_session.phase"
assert_file "$DX_LOOP_DIR/$shared_main_session.state"
assert_file "$DX_LOOP_DIR/refine-$shared_main_session-123-456-789.state"
assert_absent "$DX_STATE_DIR/$shared_linked_session.phase"
assert_absent "$DX_LOOP_DIR/$shared_linked_session.state"
# This unique-session shape is indistinguishable from the active numeric
# sibling's stable session ID, so checkout-local cleanup leaves it for the
# final repo-wide pass.
assert_file "$DX_LOOP_DIR/$shared_linked_session-123-456-789.state"
assert_file "$DX_STATE_DIR/$shared_sibling_session.phase"
assert_file "$DX_STATE_DIR/$shared_numeric_sibling_session.phase"
[[ "$(git -C "$shared_repo" config --local --get core.hooksPath)" == "$shared_proxy" ]] || assert_at $LINENO
assert_contains "Other initialized worktrees still use" "$TMP_DIR/shared-linked-uninit.out"

run_uninit "$shared_repo" "$TMP_DIR/shared-main-uninit.out"
assert_absent "$shared_repo/.github"
assert_absent "$shared_state"
assert_absent "$shared_proxy"
assert_absent "$DX_STATE_DIR/$shared_main_session.phase"
assert_absent "$DX_LOOP_DIR/$shared_main_session.state"
assert_absent "$DX_LOOP_DIR/refine-$shared_main_session-123-456-789.state"
assert_absent "$DX_LOOP_DIR/$shared_linked_session-123-456-789.state"
assert_absent "$DX_STATE_DIR/$shared_sibling_session.phase"
assert_absent "$DX_STATE_DIR/$shared_numeric_sibling_session.phase"
if git -C "$shared_repo" config --local --get core.hooksPath >/dev/null 2>&1; then
  printf 'shared hook override remained after the final uninit\n' >&2
  exit 1
fi

# Older installations did not record the previous hook path. Uninit leaves
# those files alone because it cannot prove which configuration to restore.
legacy_repo=$(new_repo legacy)
mkdir -p "$legacy_repo/.dex/git-hooks" "$legacy_repo/.github"
cat > "$legacy_repo/.dex/git-hooks/commit-msg" <<'HOOK'
#!/usr/bin/env bash
# Dex-managed commit-msg hook. Re-run 'dx init' or 'dx sync' to refresh.
exit 0
HOOK
chmod +x "$legacy_repo/.dex/git-hooks/commit-msg"
printf 'Generated by Dex\n' > "$legacy_repo/.github/pull_request_template.md"
git -C "$legacy_repo" config --local core.hooksPath .dex/git-hooks
run_uninit "$legacy_repo" "$TMP_DIR/legacy-uninit.out"
[[ "$(git -C "$legacy_repo" config --local --get core.hooksPath)" == ".dex/git-hooks" ]] || assert_at $LINENO
assert_file "$legacy_repo/.dex/git-hooks/commit-msg"
assert_file "$legacy_repo/.github/pull_request_template.md"
assert_contains "Legacy Dex hooks have no restoration record" "$TMP_DIR/legacy-uninit.out"
assert_contains "PR template has no ownership record" "$TMP_DIR/legacy-uninit.out"

# Init refuses to write project state through a symlink that leaves the repo.
symlink_repo=$(new_repo symlink)
mkdir -p "$TMP_DIR/outside-dex"
ln -s "$TMP_DIR/outside-dex" "$symlink_repo/.dex"
symlink_status=0
(
  cd "$symlink_repo"
  bash "$ROOT/bin/init.sh" --skip-analysis --skip-config
) > "$TMP_DIR/symlink-init.out" 2>&1 || symlink_status=$?
[[ "$symlink_status" -ne 0 ]] || assert_at $LINENO
assert_contains "Refusing to initialize through a symlinked .dex directory" "$TMP_DIR/symlink-init.out"
[[ -z "$(find "$TMP_DIR/outside-dex" -mindepth 1 -print -quit)" ]] || assert_at $LINENO

nested_file_repo=$(new_repo nested-file-symlink)
mkdir -p "$nested_file_repo/.dex" "$TMP_DIR/nested-file-target"
ln -s "$TMP_DIR/nested-file-target/dex.md" "$nested_file_repo/.dex/dex.md"
nested_file_status=0
(
  cd "$nested_file_repo"
  bash "$ROOT/bin/init.sh" --skip-analysis --skip-config
) > "$TMP_DIR/nested-file-init.out" 2>&1 || nested_file_status=$?
[[ "$nested_file_status" -ne 0 ]] || assert_at $LINENO
assert_absent "$TMP_DIR/nested-file-target/dex.md"
assert_contains "while .dex contains a symlink" "$TMP_DIR/nested-file-init.out"

nested_dir_repo=$(new_repo nested-dir-symlink)
mkdir -p "$nested_dir_repo/.dex" "$TMP_DIR/nested-memory-target"
ln -s "$TMP_DIR/nested-memory-target" "$nested_dir_repo/.dex/memory"
nested_dir_status=0
(
  cd "$nested_dir_repo"
  bash "$ROOT/bin/init.sh" --skip-analysis --skip-config
) > "$TMP_DIR/nested-dir-init.out" 2>&1 || nested_dir_status=$?
[[ "$nested_dir_status" -ne 0 ]] || assert_at $LINENO
[[ -z "$(find "$TMP_DIR/nested-memory-target" -mindepth 1 -print -quit)" ]] || assert_at $LINENO
assert_contains "while .dex contains a symlink" "$TMP_DIR/nested-dir-init.out"

unmanaged_symlink_repo=$(new_repo unmanaged-worktree-symlink)
mkdir -p "$unmanaged_symlink_repo/.dex/worktrees/example" "$TMP_DIR/unmanaged-target"
ln -s "$TMP_DIR/unmanaged-target" "$unmanaged_symlink_repo/.dex/worktrees/example/source-link"
run_init "$unmanaged_symlink_repo" "$TMP_DIR/unmanaged-symlink-init.out"
assert_contains "Init complete for:" "$TMP_DIR/unmanaged-symlink-init.out"
[[ -L "$unmanaged_symlink_repo/.dex/worktrees/example/source-link" ]] || assert_at $LINENO

# Init rejects special filesystem objects instead of reading from or replacing
# them through its atomic-write helper.
fifo_repo=$(new_repo fifo-destination)
mkdir -p "$fifo_repo/.dex"
mkfifo "$fifo_repo/.dex/AGENTS.md"
fifo_status=0
run_init_bounded "$fifo_repo" > "$TMP_DIR/fifo-init.out" 2>&1 || fifo_status=$?
[[ "$fifo_status" -ne 0 ]] || assert_at $LINENO
[[ "$fifo_status" -ne 124 ]] || assert_at $LINENO
[[ -p "$fifo_repo/.dex/AGENTS.md" ]] || assert_at $LINENO
assert_contains "Refusing to replace a non-regular project file" "$TMP_DIR/fifo-init.out"

# A user-owned destination for the proxy is a hard conflict, not something init
# can adopt or overwrite.
collision_repo=$(new_repo collision)
collision_hook_dir=$(dx_attribution_hook_dir "$collision_repo")
mkdir -p "$collision_hook_dir"
printf '#!/usr/bin/env bash\nexit 0\n' > "$collision_hook_dir/commit-msg"
chmod +x "$collision_hook_dir/commit-msg"
collision_hash=$(shasum -a 256 "$collision_hook_dir/commit-msg" | awk '{print $1}')
collision_status=0
(
  cd "$collision_repo"
  bash "$ROOT/bin/init.sh" --skip-analysis --skip-config
) > "$TMP_DIR/collision-init.out" 2>&1 || collision_status=$?
[[ "$collision_status" -ne 0 ]] || assert_at $LINENO
[[ "$(shasum -a 256 "$collision_hook_dir/commit-msg" | awk '{print $1}')" == "$collision_hash" ]] || assert_at $LINENO
assert_contains "Refusing to replace the existing Dex hook proxy directory" "$TMP_DIR/collision-init.out"

# Local provenance is treated as untrusted input before cleanup paths or Git
# config scopes are used.
tampered_repo=$(new_repo tampered)
run_init "$tampered_repo" "$TMP_DIR/tampered-init.out"
tampered_state=$(dx_attribution_state_file "$tampered_repo")
sed 's/"config_scope": "local"/"config_scope": "global"/' \
  "$tampered_state" > "${tampered_state}.tmp"
mv "${tampered_state}.tmp" "$tampered_state"
tampered_status=0
run_uninit "$tampered_repo" "$TMP_DIR/tampered-uninit.out" || tampered_status=$?
[[ "$tampered_status" -ne 0 ]] || assert_at $LINENO
assert_contains "invalid attribution config scope" "$TMP_DIR/tampered-uninit.out"

# Fields used later by hook cleanup are validated before core.hooksPath changes.
tampered_receipt_repo=$(new_repo tampered-receipt)
run_init "$tampered_receipt_repo" "$TMP_DIR/tampered-receipt-init.out"
tampered_receipt_state=$(dx_attribution_state_file "$tampered_receipt_repo")
DEX_TEST_ATTRIBUTION_STATE="$tampered_receipt_state" python3 - <<'PY'
import json
import os
from pathlib import Path

path = Path(os.environ["DEX_TEST_ATTRIBUTION_STATE"])
state = json.loads(path.read_text(encoding="utf-8"))
state["generated_hooks"] = {"../outside": "0" * 64}
path.write_text(json.dumps(state), encoding="utf-8")
PY
tampered_receipt_status=0
run_uninit "$tampered_receipt_repo" "$TMP_DIR/tampered-receipt-uninit.out" \
  || tampered_receipt_status=$?
[[ "$tampered_receipt_status" -ne 0 ]] || assert_at $LINENO
tampered_receipt_hook_dir=$(dx_attribution_hook_dir "$tampered_receipt_repo")
[[ "$(git -C "$tampered_receipt_repo" config --local --get core.hooksPath)" == "$tampered_receipt_hook_dir" ]] || assert_at $LINENO
assert_file "$tampered_receipt_hook_dir/commit-msg"
assert_contains "invalid generated hook name" "$TMP_DIR/tampered-receipt-uninit.out"

tampered_path_repo=$(new_repo tampered-installed-path)
run_init "$tampered_path_repo" "$TMP_DIR/tampered-path-init.out"
tampered_path_state=$(dx_attribution_state_file "$tampered_path_repo")
tampered_path_proxy=$(dx_attribution_hook_dir "$tampered_path_repo")
tampered_external_hooks="$TMP_DIR/tampered-external-hooks"
mkdir -p "$tampered_external_hooks"
cp "$tampered_path_proxy/commit-msg" "$tampered_external_hooks/commit-msg"
DEX_TEST_ATTRIBUTION_STATE="$tampered_path_state" \
DEX_TEST_EXTERNAL_HOOKS="$tampered_external_hooks" python3 - <<'PY'
import json
import os
from pathlib import Path

path = Path(os.environ["DEX_TEST_ATTRIBUTION_STATE"])
state = json.loads(path.read_text(encoding="utf-8"))
state["installed_hooks_path"] = os.environ["DEX_TEST_EXTERNAL_HOOKS"]
path.write_text(json.dumps(state), encoding="utf-8")
PY
tampered_path_status=0
run_uninit "$tampered_path_repo" "$TMP_DIR/tampered-path-uninit.out" || tampered_path_status=$?
[[ "$tampered_path_status" -ne 0 ]] || assert_at $LINENO
assert_file "$tampered_external_hooks/commit-msg"
[[ "$(git -C "$tampered_path_repo" config --local --get core.hooksPath)" == "$tampered_path_proxy" ]] || assert_at $LINENO
assert_contains "invalid installed hook path" "$TMP_DIR/tampered-path-uninit.out"

victim="$TMP_DIR/ownership-victim"
printf 'keep\n' > "$victim"
tampered_project_state="$TMP_DIR/tampered-project-state.json"
cat > "$tampered_project_state" <<'JSON'
{
  "managed": {
    "../ownership-victim": {
      "sha256": "not-used",
      "type": "file"
    }
  },
  "version": 1
}
JSON
if python3 "$ROOT/scripts/project-state.py" project-remove "$tampered_repo" "$tampered_project_state" \
  > "$TMP_DIR/tampered-project.out" 2>&1; then
  printf 'unsafe ownership path was accepted\n' >&2
  exit 1
fi
assert_file "$victim"
assert_contains "invalid project ownership state" "$TMP_DIR/tampered-project.out"

# Normalization must not turn a state key into an excluded worktree or legacy
# hook path after validation.
canonical_repo=$(new_repo canonical-ownership)
canonical_index=0
for canonical_relative in ".dex/./worktrees/victim" ".dex//git-hooks/victim"; do
  canonical_index=$((canonical_index + 1))
  case "$canonical_index" in
    1) canonical_file="$canonical_repo/.dex/worktrees/victim" ;;
    2) canonical_file="$canonical_repo/.dex/git-hooks/victim" ;;
  esac
  mkdir -p "$(dirname "$canonical_file")"
  printf 'keep-%s\n' "$canonical_index" > "$canonical_file"
  canonical_digest=$(shasum -a 256 "$canonical_file" | awk '{print $1}')
  canonical_state="$TMP_DIR/canonical-$canonical_index.json"
  cat > "$canonical_state" <<JSON
{
  "managed": {
    "$canonical_relative": {
      "sha256": "$canonical_digest",
      "type": "file"
    }
  },
  "version": 1
}
JSON
  if python3 "$ROOT/scripts/project-state.py" project-remove "$canonical_repo" "$canonical_state" \
    > "$TMP_DIR/canonical-$canonical_index.out" 2>&1; then
    printf 'non-canonical ownership path was accepted: %s\n' "$canonical_relative" >&2
    exit 1
  fi
  assert_file "$canonical_file"
  assert_contains "invalid project ownership state" "$TMP_DIR/canonical-$canonical_index.out"
done

# An interrupted init does not gain ownership of files that appear or change
# before a resumed attempt.
interrupted_repo=$(new_repo interrupted-ownership)
interrupted_state=$(dx_project_state_file "$interrupted_repo")
python3 "$ROOT/scripts/project-state.py" project-begin "$interrupted_repo" "$interrupted_state"
mkdir -p "$interrupted_repo/.dex"
printf '# Partial generated context\n' > "$interrupted_repo/.dex/dex.md"
printf '\nUser edit after interruption.\n' >> "$interrupted_repo/.dex/dex.md"
python3 "$ROOT/scripts/project-state.py" project-begin "$interrupted_repo" "$interrupted_state"
python3 "$ROOT/scripts/project-state.py" project-finalize "$interrupted_repo" "$interrupted_state"
python3 "$ROOT/scripts/project-state.py" project-remove "$interrupted_repo" "$interrupted_state" \
  > "$TMP_DIR/interrupted-remove.out"
assert_file "$interrupted_repo/.dex/dex.md"
assert_contains "User edit after interruption." "$interrupted_repo/.dex/dex.md"

# A failed Git config restoration must leave both receipts and proxies intact,
# so a later uninit can retry safely.
config_failure_repo=$(new_repo config-failure)
run_init "$config_failure_repo" "$TMP_DIR/config-failure-init.out"
config_failure_state=$(dx_attribution_state_file "$config_failure_repo")
config_failure_proxy=$(dx_attribution_hook_dir "$config_failure_repo")
real_git=$(command -v git)
mkdir -p "$TMP_DIR/fake-bin"
cat > "$TMP_DIR/fake-bin/git" <<'GIT'
#!/usr/bin/env bash
set -euo pipefail
case "${DEX_TEST_GIT_FAILURE_MODE:-}" in
  config-unset)
    case " $* " in
      *" config --local --unset-all core.hooksPath "*) exit 9 ;;
    esac
    ;;
  config-get)
    case " $* " in
      *" config --local --get core.hooksPath "*) exit 9 ;;
    esac
    ;;
  worktree-list)
    case " $* " in
      *" worktree list --porcelain "*) exit 9 ;;
    esac
    ;;
esac
exec "$DEX_TEST_REAL_GIT" "$@"
GIT
chmod +x "$TMP_DIR/fake-bin/git"
config_failure_status=0
(
  cd "$config_failure_repo"
  env PATH="$TMP_DIR/fake-bin:$PATH" \
    DEX_TEST_REAL_GIT="$real_git" \
    DEX_TEST_GIT_FAILURE_MODE=config-unset \
    bash "$ROOT/bin/uninit.sh"
) > "$TMP_DIR/config-failure-uninit.out" 2>&1 || config_failure_status=$?
[[ "$config_failure_status" -eq 9 ]] || assert_at $LINENO
[[ "$(git -C "$config_failure_repo" config --local --get core.hooksPath)" == "$config_failure_proxy" ]] || assert_at $LINENO
assert_file "$config_failure_state"
assert_file "$config_failure_proxy/commit-msg"

# A scoped config read error is not the same as an absent or changed value.
# Uninit must leave the live config, proxy, and receipt together for retry.
config_read_failure_repo=$(new_repo config-read-failure)
run_init "$config_read_failure_repo" "$TMP_DIR/config-read-failure-init.out"
config_read_failure_state=$(dx_attribution_state_file "$config_read_failure_repo")
config_read_failure_proxy=$(dx_attribution_hook_dir "$config_read_failure_repo")
config_read_failure_status=0
(
  cd "$config_read_failure_repo"
  env PATH="$TMP_DIR/fake-bin:$PATH" \
    DEX_TEST_REAL_GIT="$real_git" \
    DEX_TEST_GIT_FAILURE_MODE=config-get \
    bash "$ROOT/bin/uninit.sh"
) > "$TMP_DIR/config-read-failure-uninit.out" 2>&1 || config_read_failure_status=$?
[[ "$config_read_failure_status" -eq 9 ]] || assert_at $LINENO
[[ "$(git -C "$config_read_failure_repo" config --local --get core.hooksPath)" == "$config_read_failure_proxy" ]] || assert_at $LINENO
assert_file "$config_read_failure_state"
assert_file "$config_read_failure_proxy/commit-msg"

# Failure to enumerate worktrees cannot be interpreted as proof that no other
# initialized checkout exists. Abort before shared attribution is touched.
worktree_list_failure_repo=$(new_repo worktree-list-failure)
run_init "$worktree_list_failure_repo" "$TMP_DIR/worktree-list-failure-init.out"
worktree_list_failure_state=$(dx_attribution_state_file "$worktree_list_failure_repo")
worktree_list_failure_proxy=$(dx_attribution_hook_dir "$worktree_list_failure_repo")
worktree_list_failure_status=0
(
  cd "$worktree_list_failure_repo"
  env PATH="$TMP_DIR/fake-bin:$PATH" \
    DEX_TEST_REAL_GIT="$real_git" \
    DEX_TEST_GIT_FAILURE_MODE=worktree-list \
    bash "$ROOT/bin/uninit.sh"
) > "$TMP_DIR/worktree-list-failure-uninit.out" 2>&1 || worktree_list_failure_status=$?
[[ "$worktree_list_failure_status" -eq 9 ]] || assert_at $LINENO
[[ "$(git -C "$worktree_list_failure_repo" config --local --get core.hooksPath)" == "$worktree_list_failure_proxy" ]] || assert_at $LINENO
assert_file "$worktree_list_failure_state"
assert_file "$worktree_list_failure_proxy/commit-msg"

printf 'init/uninit ownership tests passed\n'
