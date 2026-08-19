#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-install-uninstall-test.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT


NO_JQ_BIN="$TMP_DIR/no-jq-bin"
mkdir -p "$NO_JQ_BIN"
for command_name in bash python3 mkdir mv rm grep find readlink basename; do
  command_path=$(command -v "$command_name")
  ln -s "$command_path" "$NO_JQ_BIN/$command_name"
done
[[ ! -e "$NO_JQ_BIN/jq" ]] || assert_at $LINENO

run_without_jq() {
  local test_home="$1"
  shift
  env \
    PATH="$NO_JQ_BIN" \
    HOME="$test_home" \
    CODEX_HOME="$test_home/.codex" \
    DEX_DIR="$ROOT" \
    DX_RTK_ENABLED=0 \
    "$NO_JQ_BIN/bash" "$@"
}

test_home="$TMP_DIR/home"
mkdir -p "$test_home/.claude"
printf '%s\n' '{"custom":true,"hooks":{"PreToolUse":[{"matcher":"Read","hooks":[{"type":"command","command":"/usr/local/bin/user-hook"}]}]},"worktree":{"symlinkDirectories":["custom-cache"],"userSetting":"kept"}}' > "$test_home/.claude/settings.json"
run_without_jq "$test_home" "$ROOT/bin/install-settings.sh" > "$TMP_DIR/install.out"

settings_file="$test_home/.claude/settings.json"
state_file="$test_home/.claude/.dex-install-state.json"
assert_file "$settings_file"
assert_file "$state_file"

printf '%s\n' '{"metadata":{"preserve":true},"worktree":{"managedSymlinkDirectories":["legacy-cache"]}}' > "$state_file"
run_without_jq "$test_home" "$ROOT/bin/install-settings.sh" > "$TMP_DIR/reinstall.out"

python3 - "$settings_file" "$state_file" "$ROOT/settings.json" <<'PY'
import json
import sys

settings_path, state_path, template_path = sys.argv[1:]
with open(settings_path, encoding="utf-8") as handle:
    settings = json.load(handle)
with open(state_path, encoding="utf-8") as handle:
    state = json.load(handle)
with open(template_path, encoding="utf-8") as handle:
    template = json.load(handle)


def hook_commands(document):
    commands = []
    for groups in document.get("hooks", {}).values():
        if not isinstance(groups, list):
            continue
        for group in groups:
            if not isinstance(group, dict):
                continue
            for hook in group.get("hooks", []):
                if isinstance(hook, dict):
                    commands.append(hook.get("command"))
    return commands


commands = hook_commands(settings)
template_commands = hook_commands(template)
dex_commands = [command for command in commands if isinstance(command, str) and "/hooks/" in command]
template_dirs = template["worktree"]["symlinkDirectories"]

assert commands.count("/usr/local/bin/user-hook") == 1, commands
assert len(dex_commands) == len(template_commands), dex_commands
assert len(dex_commands) == len(set(dex_commands)), dex_commands
assert settings["worktree"]["symlinkDirectories"] == ["custom-cache", *template_dirs], settings
assert settings["worktree"]["userSetting"] == "kept", settings
assert state["metadata"] == {"preserve": True}, state
assert state["worktree"]["managedSymlinkDirectories"] == ["legacy-cache", *template_dirs], state
PY

run_without_jq "$test_home" "$ROOT/bin/uninstall.sh" > "$TMP_DIR/uninstall.out"
assert_no_file "$state_file"

python3 - "$settings_file" "$ROOT" <<'PY'
import json
import sys

settings_path, dex_dir = sys.argv[1:]
with open(settings_path, encoding="utf-8") as handle:
    settings = json.load(handle)

commands = []
for groups in settings.get("hooks", {}).values():
    if not isinstance(groups, list):
        continue
    for group in groups:
        if not isinstance(group, dict):
            continue
        for hook in group.get("hooks", []):
            if isinstance(hook, dict):
                commands.append(hook.get("command"))

assert "/usr/local/bin/user-hook" in commands, commands
assert not any(isinstance(command, str) and f"{dex_dir}/hooks/" in command for command in commands), commands
assert settings.get("worktree", {}).get("symlinkDirectories") == ["custom-cache"], settings
assert settings.get("worktree", {}).get("userSetting") == "kept", settings
PY

broken_home="$TMP_DIR/broken-home"
mkdir -p "$broken_home"
run_without_jq "$broken_home" "$ROOT/bin/install-settings.sh" > "$TMP_DIR/broken-install.out"
broken_state="$broken_home/.claude/.dex-install-state.json"
printf '{invalid\n' > "$broken_state"

if run_without_jq "$broken_home" "$ROOT/bin/uninstall.sh" > "$TMP_DIR/broken-uninstall.out" 2>&1; then
  printf 'expected uninstall with invalid install state to fail\n' >&2
  exit 1
fi
assert_file "$broken_state"
grep -Fq "keeping $broken_state for a later uninstall attempt" "$TMP_DIR/broken-uninstall.out"

python3 - "$broken_home/.claude/settings.json" "$ROOT/settings.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    settings = json.load(handle)
with open(sys.argv[2], encoding="utf-8") as handle:
    template = json.load(handle)

assert settings["worktree"]["symlinkDirectories"] == template["worktree"]["symlinkDirectories"], settings
PY

printf 'install/uninstall tests passed\n'
