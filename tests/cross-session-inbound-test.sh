#!/usr/bin/env bash
# dex-test-lane: fast
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-cross-session-inbound-test.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
unset CLAUDE_CONFIG_DIR DX_PROVIDER_ENGINE DX_PROVIDER_APPLIED
mkdir -p "$HOME/.claude"

HELPER="$ROOT/scripts/settings-json.py"
SETTINGS="$HOME/.claude/settings.json"
STATE="$HOME/.claude/.dex-install-state.json"
PYTHON_DIR="$(dirname "$(command -v python3)")"

# The rejection cases below assert on the exit status, and the helper's own
# diagnostic would otherwise be the only output a passing run prints.
helper_quiet() {
  python3 "$HELPER" "$@" 2>/dev/null
}

# inbound-value reports what Claude Code reads from the user's own settings.
printf '%s\n' '{}' > "$SETTINGS"
assert_eq '' "$(python3 "$HELPER" inbound-value "$SETTINGS")" 'unset inbound value'
printf '%s\n' '{"crossSessionInbound":"hold"}' > "$SETTINGS"
assert_eq 'hold' "$(python3 "$HELPER" inbound-value "$SETTINGS")" 'hold inbound value'
rm -f "$SETTINGS"
assert_eq '' "$(python3 "$HELPER" inbound-value "$SETTINGS")" 'missing settings file'
printf '%s\n' '{not json' > "$SETTINGS"
assert_rejected 'malformed settings' helper_quiet inbound-value "$SETTINGS"
rm -f "$SETTINGS"

# The preference lives in Dex's install state beside the worktree entries it
# already records, so recording it never disturbs what uninstall reads.
assert_eq 'unset' "$(python3 "$HELPER" session-messaging "$STATE")" 'no state file'
printf '%s\n' '{"worktree":{"managedSymlinkDirectories":["/managed"]}}' > "$STATE"
assert_eq 'unset' "$(python3 "$HELPER" session-messaging "$STATE")" 'state without answer'
python3 "$HELPER" set-session-messaging "$STATE" on > "$TMP_DIR/on.json"
mv "$TMP_DIR/on.json" "$STATE"
assert_eq 'on' "$(python3 "$HELPER" session-messaging "$STATE")" 'recorded on'
assert_contains '"sessionMessaging": true' "$STATE"
assert_eq '["/managed"]' "$(python3 "$HELPER" state-dirs "$STATE")" 'worktree entries survive'
python3 "$HELPER" set-session-messaging "$STATE" off > "$TMP_DIR/off.json"
mv "$TMP_DIR/off.json" "$STATE"
assert_eq 'off' "$(python3 "$HELPER" session-messaging "$STATE")" 'recorded off'
assert_rejected 'unsupported state' helper_quiet set-session-messaging "$STATE" maybe
printf '%s\n' '{not json' > "$STATE"
assert_rejected 'malformed state' helper_quiet set-session-messaging "$STATE" on
assert_contains '{not json' "$STATE"
rm -f "$STATE"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

# What a launch passes: accept only when the user opted in and their own Claude
# settings do not already hold or refuse.
assert_eq '' "$(dx_session_messaging_launch_value)" 'no preference'
dx_set_session_messaging_preference on
assert_eq 'accept' "$(dx_session_messaging_launch_value)" 'preference on, no user value'
printf '%s\n' '{"crossSessionInbound":"accept"}' > "$SETTINGS"
assert_eq 'accept' "$(dx_session_messaging_launch_value)" 'preference on, user accept'
for held in hold refuse; do
  printf '{"crossSessionInbound":"%s"}\n' "$held" > "$SETTINGS"
  assert_eq '' "$(dx_session_messaging_launch_value)" "preference on, user $held"
done
rm -f "$SETTINGS"
mkdir -p "$TMP_DIR/alt"
printf '%s\n' '{"crossSessionInbound":"refuse"}' > "$TMP_DIR/alt/settings.json"
assert_eq '' "$(CLAUDE_CONFIG_DIR="$TMP_DIR/alt" dx_session_messaging_launch_value)" 'CLAUDE_CONFIG_DIR is honoured'
dx_set_session_messaging_preference off
assert_eq '' "$(dx_session_messaging_launch_value)" 'preference off'
printf '%s\n' '{not json' > "$STATE"
assert_eq '' "$(dx_session_messaging_launch_value)" 'malformed state passes nothing'
rm -f "$STATE"

# The --settings value carries the status line and, when enabled, the inbound
# setting; a script path with a quote survives both encodings.
dx_set_session_messaging_preference on
mkdir -p "$TMP_DIR/it's here"
launch_settings=$(dx_claude_launch_settings "$TMP_DIR/it's here/status-line.sh")
python3 - "$launch_settings" "$TMP_DIR/it's here/status-line.sh" <<'PY'
import json, shlex, sys
settings = json.loads(sys.argv[1])
assert settings["crossSessionInbound"] == "accept", settings
assert settings["statusLine"] == {"type": "command", "command": "bash " + shlex.quote(sys.argv[2])}, settings
PY
assert_eq '{"crossSessionInbound": "accept"}' "$(dx_claude_launch_settings)" 'inbound alone'
dx_set_session_messaging_preference off
assert_eq '' "$(dx_claude_launch_settings)" 'nothing to set prints nothing'
assert_eq '{"statusLine": {"type": "command", "command": "bash status.sh"}}' \
  "$(dx_claude_launch_settings status.sh)" 'status line alone'

# Claude sessions learn their name and what delivery to expect; Codex has no
# peer messaging and gets nothing.
export DX_PROVIDER_APPLIED=1 DX_PROVIDER_ENGINE=claude
dx_session_messaging_prompt 'ticket-42' > "$TMP_DIR/prompt-off.txt"
assert_contains 'named "ticket-42"' "$TMP_DIR/prompt-off.txt"
assert_contains 'ListAgents' "$TMP_DIR/prompt-off.txt"
assert_contains 'held for the user' "$TMP_DIR/prompt-off.txt"
assert_contains 'dx config --session-messaging on' "$TMP_DIR/prompt-off.txt"
dx_set_session_messaging_preference on
dx_session_messaging_prompt 'ticket-42' > "$TMP_DIR/prompt-on.txt"
assert_contains 'accepts messages' "$TMP_DIR/prompt-on.txt"
assert_not_contains 'held for the user' "$TMP_DIR/prompt-on.txt"
assert_eq '' "$(DX_PROVIDER_ENGINE=codex-plugin dx_session_messaging_prompt 'ticket-42')" 'codex prompt'
unset DX_PROVIDER_APPLIED DX_PROVIDER_ENGINE
rm -f "$STATE"

# The flag sets the preference without a repository or a terminal and skips
# the wizard.
(cd "$TMP_DIR" && bash "$ROOT/bin/config.sh" --session-messaging on) > "$TMP_DIR/flag-on.out" 2>&1
assert_contains 'without approval' "$TMP_DIR/flag-on.out"
assert_not_contains 'Integrations configured' "$TMP_DIR/flag-on.out"
assert_eq 'on' "$(dx_session_messaging_preference)" 'flag on'
(cd "$TMP_DIR" && bash "$ROOT/bin/config.sh" --session-messaging=off) > "$TMP_DIR/flag-off.out" 2>&1
assert_contains 'hold messages' "$TMP_DIR/flag-off.out"
assert_eq 'off' "$(dx_session_messaging_preference)" 'flag off'
assert_rejected 'bad flag value' bash "$ROOT/bin/config.sh" --session-messaging maybe 2>/dev/null
assert_rejected 'missing flag value' bash "$ROOT/bin/config.sh" --session-messaging 2>/dev/null
printf '%s\n' '{"crossSessionInbound":"refuse"}' > "$SETTINGS"
(cd "$TMP_DIR" && bash "$ROOT/bin/config.sh" --session-messaging on) > "$TMP_DIR/flag-refuse.out" 2>&1
assert_contains 'crossSessionInbound to refuse' "$TMP_DIR/flag-refuse.out"
rm -f "$SETTINGS" "$STATE"

mkdir -p "$TMP_DIR/repo/.dex"
git init -q "$TMP_DIR/repo"
git -C "$TMP_DIR/repo" config user.email test@example.com
git -C "$TMP_DIR/repo" config user.name Test
printf '%s\n' '# Dex project' > "$TMP_DIR/repo/.dex/dex.md"

# Without a terminal the wizard does not ask, so piped callers keep their
# existing answer sequence and nothing is recorded.
(
  cd "$TMP_DIR/repo"
  printf '%s\n' 3 n n n n n n n '' \
    | PATH="/usr/bin:/bin:$PYTHON_DIR" bash "$ROOT/bin/config.sh"
) > "$TMP_DIR/config.out" 2>&1 || true
assert_not_contains 'Deliver messages' "$TMP_DIR/config.out"
assert_not_contains 'Session messaging' "$TMP_DIR/config.out"
assert_no_file "$STATE"
assert_contains 'Integrations configured' "$TMP_DIR/config.out"

# With a terminal the wizard asks once, records the answer, and never edits
# the user's Claude settings.
printf '%s\n' '{"theme":"auto"}' > "$SETTINGS"
python3 - "$TMP_DIR/repo" "/usr/bin:/bin:$PYTHON_DIR" "$ROOT/bin/config.sh" > "$TMP_DIR/pty.out" <<'PY'
import os, pty, select, signal, sys
repo, path, script = sys.argv[1:4]
pid, fd = pty.fork()
if pid == 0:
    os.chdir(repo)
    os.environ["PATH"] = path
    os.execvp("bash", ["bash", script])
os.write(fd, b"3\nn\nn\nn\nn\nn\nn\ny\nn\n\n\x04")
output = b""
while True:
    ready, _, _ = select.select([fd], [], [], 60)
    if not ready:
        os.kill(pid, signal.SIGKILL)
        break
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    output += chunk
_, status = os.waitpid(pid, 0)
sys.stdout.buffer.write(output)
sys.exit(0 if os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0 else 1)
PY
assert_contains 'Deliver messages between your Dex sessions' "$TMP_DIR/pty.out"
assert_contains 'Session messaging: enabled' "$TMP_DIR/pty.out"
assert_eq 'on' "$(dx_session_messaging_preference)" 'wizard recorded on'
# Byte-for-byte: the file was never rewritten, not even reformatted.
assert_eq '{"theme":"auto"}' "$(cat "$SETTINGS")" 'user settings untouched'

# Once recorded the wizard reports the state instead of asking again, with or
# without a terminal.
(
  cd "$TMP_DIR/repo"
  printf '%s\n' 3 n n n n n n n '' \
    | PATH="/usr/bin:/bin:$PYTHON_DIR" bash "$ROOT/bin/config.sh"
) > "$TMP_DIR/again.out" 2>&1 || true
assert_not_contains 'Deliver messages' "$TMP_DIR/again.out"
assert_contains 'Session messaging: enabled' "$TMP_DIR/again.out"
assert_contains 'Integrations configured' "$TMP_DIR/again.out"

# A broken state file warns without aborting the rest of dx config.
printf '%s\n' '{not json' > "$STATE"
(
  cd "$TMP_DIR/repo"
  printf '%s\n' 3 n n n n n n n '' \
    | PATH="/usr/bin:/bin:$PYTHON_DIR" bash "$ROOT/bin/config.sh"
) > "$TMP_DIR/broken.out" 2>&1 || true
assert_contains 'Integrations configured' "$TMP_DIR/broken.out"

printf 'cross-session inbound tests passed\n'
