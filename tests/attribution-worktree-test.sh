#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-attribution-worktree.XXXXXX")"

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
mkdir -p "$HOME"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

new_repo_with_worktree() {
  local name="$1"
  local repo="$TMP_DIR/$name-main"
  local linked="$TMP_DIR/$name-linked"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email dex@example.test
  git -C "$repo" config user.name "Dex Test"
  printf 'initial\n' > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -q -m "chore: initialize fixture"
  git -C "$repo" branch linked
  git -C "$repo" worktree add -q "$linked" linked
  printf '%s\t%s\n' "$repo" "$linked"
}

write_logging_hook() {
  local path="$1" label="$2"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<HOOK
#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' '$label' >> "\$DEX_TEST_HOOK_LOG"
HOOK
  chmod +x "$path"
}

commit_change() {
  local repo="$1" content="$2" message="$3" log="$4"
  printf '%s\n' "$content" >> "$repo/file.txt"
  git -C "$repo" add file.txt
  DEX_TEST_HOOK_LOG="$log" git -C "$repo" commit -q -m "$message"
}

# Local Git config is shared by linked worktrees, so Dex uses one stable proxy
# in the common Git directory. Relative original hook paths are resolved at hook
# runtime against whichever worktree is committing.
IFS=$'\t' read -r local_main local_linked < <(new_repo_with_worktree local-scope)
write_logging_hook "$local_main/.githooks/commit-msg" main-relative
write_logging_hook "$local_linked/.githooks/commit-msg" linked-relative
git -C "$local_main" config --local core.hooksPath .githooks
dx_install_repo_attribution "$local_main" > "$TMP_DIR/local-install.out"
local_proxy=$(dx_attribution_hook_dir "$local_main")
[[ "$(git -C "$local_main" config --local --get core.hooksPath)" == "$local_proxy" ]]
[[ "$(git -C "$local_linked" config --local --get core.hooksPath)" == "$local_proxy" ]]

# The shared proxy set must also discover hooks added only in a linked
# worktree after the main checkout was initialized.
write_logging_hook "$local_linked/.githooks/pre-commit" linked-only-pre-commit
commit_change "$local_linked" linked "feat: linked worktree change" "$TMP_DIR/local-hooks.log"
commit_change "$local_main" main "feat: main worktree change" "$TMP_DIR/local-hooks.log"
[[ "$(grep -c '^linked-only-pre-commit$' "$TMP_DIR/local-hooks.log")" -eq 1 ]]
[[ "$(grep -c '^linked-relative$' "$TMP_DIR/local-hooks.log")" -eq 1 ]]
[[ "$(grep -c '^main-relative$' "$TMP_DIR/local-hooks.log")" -eq 1 ]]

dx_uninstall_repo_attribution "$local_main" > "$TMP_DIR/local-uninstall.out"
[[ "$(git -C "$local_main" config --local --get core.hooksPath)" == ".githooks" ]]
[[ "$(git -C "$local_linked" config --local --get core.hooksPath)" == ".githooks" ]]
[[ ! -e "$local_proxy" ]]

# Worktree-scoped config needs independent receipts and restoration values. A
# linked worktree uninit must not remove or restore the main worktree's proxy.
IFS=$'\t' read -r scoped_main scoped_linked < <(new_repo_with_worktree worktree-scope)
git -C "$scoped_main" config extensions.worktreeConfig true
git -C "$scoped_main" config --worktree core.hooksPath .main-hooks
git -C "$scoped_linked" config --worktree core.hooksPath .linked-hooks
write_logging_hook "$scoped_main/.main-hooks/commit-msg" main-scoped
write_logging_hook "$scoped_linked/.linked-hooks/commit-msg" linked-scoped

dx_install_repo_attribution "$scoped_main" > "$TMP_DIR/scoped-main-install.out"
main_state=$(dx_attribution_state_file "$scoped_main")
main_proxy=$(dx_attribution_hook_dir "$scoped_main")
dx_install_repo_attribution "$scoped_linked" > "$TMP_DIR/scoped-linked-install.out"
linked_state=$(dx_attribution_state_file "$scoped_linked")
linked_proxy=$(dx_attribution_hook_dir "$scoped_linked")
[[ "$main_state" != "$linked_state" ]]
[[ "$main_proxy" != "$linked_proxy" ]]

commit_change "$scoped_linked" linked "fix: linked scoped hook" "$TMP_DIR/scoped-hooks.log"
commit_change "$scoped_main" main "fix: main scoped hook" "$TMP_DIR/scoped-hooks.log"
[[ "$(grep -c '^linked-scoped$' "$TMP_DIR/scoped-hooks.log")" -eq 1 ]]
[[ "$(grep -c '^main-scoped$' "$TMP_DIR/scoped-hooks.log")" -eq 1 ]]

dx_uninstall_repo_attribution "$scoped_linked" > "$TMP_DIR/scoped-linked-uninstall.out"
[[ "$(git -C "$scoped_linked" config --worktree --get core.hooksPath)" == ".linked-hooks" ]]
[[ "$(git -C "$scoped_main" config --worktree --get core.hooksPath)" == "$main_proxy" ]]
[[ -f "$main_state" ]]
[[ -d "$main_proxy" ]]

dx_uninstall_repo_attribution "$scoped_main" > "$TMP_DIR/scoped-main-uninstall.out"
[[ "$(git -C "$scoped_main" config --worktree --get core.hooksPath)" == ".main-hooks" ]]
[[ ! -e "$main_state" ]]
[[ ! -e "$main_proxy" ]]

# Existing state determines uninstall ownership even if the user later unsets
# the worktree hook override. The linked uninstall must not select local state.
IFS=$'\t' read -r unset_main unset_linked < <(new_repo_with_worktree unset-scope)
mkdir -p "$unset_main/.local-hooks" "$unset_linked/.linked-hooks"
git -C "$unset_main" config --local core.hooksPath .local-hooks
dx_install_attribution_hook "$unset_main" > "$TMP_DIR/unset-local-install.out"
unset_local_state=$(dx_attribution_state_file "$unset_main")
unset_local_proxy=$(dx_attribution_hook_dir "$unset_main")

git -C "$unset_main" config extensions.worktreeConfig true
git -C "$unset_linked" config --worktree core.hooksPath .linked-hooks
dx_install_attribution_hook "$unset_linked" > "$TMP_DIR/unset-linked-install.out"
unset_worktree_state=$(dx_attribution_state_file "$unset_linked")
unset_worktree_proxy=$(dx_attribution_hook_dir "$unset_linked")
git -C "$unset_linked" config --worktree --unset-all core.hooksPath

[[ "$(dx_attribution_state_file "$unset_linked")" == "$unset_worktree_state" ]]
dx_uninstall_repo_attribution "$unset_linked" > "$TMP_DIR/unset-linked-uninstall.out"
[[ ! -e "$unset_worktree_state" ]]
[[ ! -e "$unset_worktree_proxy" ]]
[[ -f "$unset_local_state" ]]
[[ -d "$unset_local_proxy" ]]
[[ "$(git -C "$unset_linked" config --get core.hooksPath)" == "$unset_local_proxy" ]]

dx_uninstall_repo_attribution "$unset_main" > "$TMP_DIR/unset-local-uninstall.out"
[[ "$(git -C "$unset_main" config --local --get core.hooksPath)" == ".local-hooks" ]]

# A newer manual worktree override must not hide an older local Dex receipt
# from uninit. Removing that override later must not resurrect Dex's proxy.
IFS=$'\t' read -r masked_main masked_linked < <(new_repo_with_worktree masked-scope)
mkdir -p "$masked_main/.local-hooks" "$masked_linked/.manual-hooks"
git -C "$masked_main" config --local core.hooksPath .local-hooks
dx_install_attribution_hook "$masked_main" > "$TMP_DIR/masked-local-install.out"
masked_local_state=$(dx_attribution_state_file "$masked_main")
masked_local_proxy=$(dx_attribution_hook_dir "$masked_main")

git -C "$masked_main" config extensions.worktreeConfig true
git -C "$masked_linked" config --worktree core.hooksPath .manual-hooks
[[ "$(dx_attribution_state_file "$masked_linked")" == "$masked_local_state" ]]
dx_uninstall_repo_attribution "$masked_linked" > "$TMP_DIR/masked-uninstall.out"
[[ ! -e "$masked_local_state" ]]
[[ ! -e "$masked_local_proxy" ]]
[[ "$(git -C "$masked_linked" config --get core.hooksPath)" == ".manual-hooks" ]]
git -C "$masked_linked" config --worktree --unset-all core.hooksPath
[[ "$(git -C "$masked_linked" config --get core.hooksPath)" == ".local-hooks" ]]

printf 'attribution worktree tests passed\n'
