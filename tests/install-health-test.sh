#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-install-health-test.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export CODEX_HOME="$HOME/.codex"
export DEX_DIR="$ROOT"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_RTK_ENABLED=0
export DX_RUN_ROOT="$TMP_DIR/runs"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_TOOL_DIR="$TMP_DIR/tools"

mkdir -p "$HOME/.claude"
printf '%s\n' '{"userSetting":"keep","hooks":{"PreCompact":[{"matcher":"custom","hooks":[{"type":"command","command":"/usr/local/bin/user-pre-compact"}]}]},"worktree":{"symlinkDirectories":["custom-cache"],"userSetting":"keep"}}' > "$HOME/.claude/settings.json"

bash "$ROOT/bin/install-settings.sh" --quiet

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

dx_claude_settings_complete

python3 - "$HOME/.claude/settings.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    settings = json.load(handle)

for event, hook_name in (
    ("PreCompact", "pre-compact.sh"),
    ("SessionEnd", "session-end.sh"),
):
    retained = []
    for group in settings["hooks"][event]:
        commands = [
            hook.get("command", "")
            for hook in group.get("hooks", [])
            if isinstance(hook, dict)
        ]
        if not any(hook_name in command for command in commands):
            retained.append(group)
    if retained:
        settings["hooks"][event] = retained
    else:
        settings["hooks"].pop(event)

with open(path, "w", encoding="utf-8") as handle:
    json.dump(settings, handle, indent=2)
    handle.write("\n")
PY

if dx_claude_settings_complete; then
  printf 'missing required hooks were reported as complete\n' >&2
  exit 1
fi

STATUS_BIN="$TMP_DIR/status-bin"
mkdir -p "$STATUS_BIN"
for command_name in bash basename find git grep python3 readlink tr wc; do
  command_path=$(command -v "$command_name")
  ln -s "$command_path" "$STATUS_BIN/$command_name"
done

env PATH="$STATUS_BIN" bash "$ROOT/bin/status.sh" > "$TMP_DIR/status.out"
grep -Fq "Hooks:     INCOMPLETE" "$TMP_DIR/status.out"
grep -Fq "RTK:       disabled (DX_RTK_ENABLED=0)" "$TMP_DIR/status.out"

dx_check_claude_dex_links() { return 0; }
dx_check_codex_skill_links() { return 0; }
dx_check_ui_capture_tooling() { return 0; }
dx_check_rtk_tooling() { return 0; }
dx_check_openai_docs_mcp_servers() { return 0; }
dx_check_safe_official_claude_plugins() { return 0; }

if dx_bootstrap_agent_tooling "" "check" > "$TMP_DIR/doctor.out" 2>&1; then
  printf 'tooling doctor accepted incomplete Claude settings\n' >&2
  exit 1
fi
grep -Fq "Claude settings are incomplete" "$TMP_DIR/doctor.out"

dx_install_claude_dex_links() { return 0; }
dx_install_codex_skills() { return 0; }
dx_install_ui_capture_tooling() { return 0; }
dx_install_rtk_tooling() { return 0; }
dx_install_openai_docs_mcp_servers() { return 0; }
dx_install_safe_official_claude_plugins() { return 0; }

dx_bootstrap_agent_tooling "" "install" > "$TMP_DIR/repair.out"
dx_claude_settings_complete
env PATH="$STATUS_BIN" bash "$ROOT/bin/status.sh" > "$TMP_DIR/repaired-status.out"
grep -Fq "Hooks:     installed in ~/.claude/settings.json" "$TMP_DIR/repaired-status.out"

python3 - "$HOME/.claude/settings.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    settings = json.load(handle)

commands = []
for groups in settings.get("hooks", {}).values():
    if not isinstance(groups, list):
        continue
    for group in groups:
        if not isinstance(group, dict):
            continue
        commands.extend(
            hook.get("command")
            for hook in group.get("hooks", [])
            if isinstance(hook, dict)
        )

assert commands.count("/usr/local/bin/user-pre-compact") == 1, commands
assert sum("pre-compact.sh" in (command or "") for command in commands) == 1, commands
assert sum("session-end.sh" in (command or "") for command in commands) == 1, commands
assert settings["userSetting"] == "keep", settings
assert settings["worktree"]["userSetting"] == "keep", settings
assert settings["worktree"]["symlinkDirectories"][0] == "custom-cache", settings
PY

CONFLICT_BIN="$TMP_DIR/conflict-bin"
mkdir -p "$CONFLICT_BIN"
for command_name in bash basename chmod dirname find grep ln mkdir mv python3 readlink rm; do
  command_path=$(command -v "$command_name")
  ln -s "$command_path" "$CONFLICT_BIN/$command_name"
done

conflict_home="$TMP_DIR/conflict-home"
mkdir -p "$conflict_home/.claude"
printf '%s\n' 'user-owned skill path' > "$conflict_home/.claude/skills"
printf '%s\n' '# user shell config' > "$conflict_home/.zshrc"

if env \
  PATH="$CONFLICT_BIN" \
  HOME="$conflict_home" \
  CODEX_HOME="$conflict_home/.codex" \
  DEX_DIR="$ROOT" \
  DX_RTK_ENABLED=0 \
  DX_TOOL_DIR="$TMP_DIR/conflict-tools" \
  bash "$ROOT/bin/install.sh" > "$TMP_DIR/conflict.out" 2>&1; then
  printf 'global install succeeded with a conflicting Claude skills path\n' >&2
  exit 1
fi
grep -Fq "Failed to symlink ~/.claude/skills" "$TMP_DIR/conflict.out"
grep -Fq "Install incomplete" "$TMP_DIR/conflict.out"
if grep -Fq "Install complete." "$TMP_DIR/conflict.out"; then
  printf 'failed global install printed a completion message\n' >&2
  exit 1
fi

# Commenting the source line out is how people turn Dex off. Detection must not
# read that as "already installed" — install would then add nothing, status
# would report integration that is absent, and uninstall would claim a removal
# it did not make. A conditional source line must still count as present.
# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"
zshrc_probe="$TMP_DIR/zshrc-probe"
zshrc_case() {
  printf '%s\n' "$2" > "$zshrc_probe"
  if grep -qE "$DX_ZSHRC_SOURCE_ACTIVE_PATTERN" "$zshrc_probe" 2>/dev/null; then
    [[ "$3" == "yes" ]] || { printf 'zshrc detection: %s should not count as installed\n' "$1" >&2; exit 1; }
  else
    [[ "$3" == "no" ]] || { printf 'zshrc detection: %s should count as installed\n' "$1" >&2; exit 1; }
  fi
}
zshrc_case "a plain source line" 'source "$DEX_DIR/dx.sh"' yes
zshrc_case "the dot form" '. "$DEX_DIR/dx.sh"' yes
zshrc_case "a guarded source line" '[[ -f "$DEX_DIR/dx.sh" ]] && source "$DEX_DIR/dx.sh"' yes
zshrc_case "a legacy checkout path" 'source ~/work/dex-cli/dx.sh' yes
zshrc_case "a commented-out source line" '# source "$DEX_DIR/dx.sh"' no
zshrc_case "an indented comment" '   #source "$DEX_DIR/dx.sh"' no
zshrc_case "a comment mentioning dx.sh" '# Dex loads from dex/dx.sh nowadays' no

printf 'install health tests passed\n'
