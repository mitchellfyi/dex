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
mkdir -p "$HOME/.claude"

HELPER="$ROOT/scripts/settings-json.py"
SETTINGS="$HOME/.claude/settings.json"

# The rejection cases below assert on the exit status, and the helper's own
# diagnostic would otherwise be the only output a passing run prints.
helper_quiet() {
  python3 "$HELPER" "$@" 2>/dev/null
}

# inbound-accepted reports the current state, which seeds the prompt default.
printf '%s\n' '{}' > "$SETTINGS"
assert_rejected 'no value set' python3 "$HELPER" inbound-accepted "$SETTINGS"
printf '%s\n' '{"crossSessionInbound":"hold"}' > "$SETTINGS"
assert_rejected 'hold is not accepted' python3 "$HELPER" inbound-accepted "$SETTINGS"
rm -f "$SETTINGS"
assert_rejected 'missing settings file' python3 "$HELPER" inbound-accepted "$SETTINGS"

# Turning it on writes the value and leaves unrelated settings alone.
printf '%s\n' '{"theme":"auto"}' > "$SETTINGS"
python3 "$HELPER" set-inbound "$SETTINGS" on > "$TMP_DIR/on.json"
mv "$TMP_DIR/on.json" "$SETTINGS"
assert_contains '"crossSessionInbound": "accept"' "$SETTINGS"
assert_contains '"theme": "auto"' "$SETTINGS"
python3 "$HELPER" inbound-accepted "$SETTINGS"

# Turning it on again is idempotent, so repeated runs do not churn the file.
python3 "$HELPER" set-inbound "$SETTINGS" on > "$TMP_DIR/again.json"
assert_contains '"crossSessionInbound": "accept"' "$TMP_DIR/again.json"

# Turning it off clears only the value Dex writes.
python3 "$HELPER" set-inbound "$SETTINGS" off > "$TMP_DIR/off.json"
mv "$TMP_DIR/off.json" "$SETTINGS"
assert_not_contains 'crossSessionInbound' "$SETTINGS"
assert_contains '"theme": "auto"' "$SETTINGS"

# A deliberate hold or refuse already declines delivery and is left intact.
for held in hold refuse; do
  printf '{"crossSessionInbound":"%s"}\n' "$held" > "$SETTINGS"
  python3 "$HELPER" set-inbound "$SETTINGS" off > "$TMP_DIR/held.json"
  assert_contains "\"crossSessionInbound\": \"$held\"" "$TMP_DIR/held.json"
done

# Turning it on replaces a previous decline, so the prompt stays two-way.
printf '%s\n' '{"crossSessionInbound":"refuse"}' > "$SETTINGS"
python3 "$HELPER" set-inbound "$SETTINGS" on > "$TMP_DIR/flip.json"
assert_contains '"crossSessionInbound": "accept"' "$TMP_DIR/flip.json"

# A missing settings file is created rather than failing.
rm -f "$SETTINGS"
python3 "$HELPER" set-inbound "$SETTINGS" on > "$TMP_DIR/new.json"
assert_contains '"crossSessionInbound": "accept"' "$TMP_DIR/new.json"

# An unsupported state is rejected.
assert_rejected 'unsupported state' helper_quiet set-inbound "$SETTINGS" maybe

# Malformed settings are reported, never overwritten.
printf '%s\n' '{not json' > "$SETTINGS"
assert_rejected 'malformed settings' helper_quiet set-inbound "$SETTINGS" on
assert_contains '{not json' "$SETTINGS"

# The shell helpers drive the same paths.
rm -f "$SETTINGS"
# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"
assert_rejected 'unset via shell helper' dx_cross_session_messages_enabled
dx_set_cross_session_messages on
dx_cross_session_messages_enabled
dx_set_cross_session_messages off
assert_rejected 'cleared via shell helper' dx_cross_session_messages_enabled

# dx config must not ask when stdin is not a terminal, so piped callers keep
# their existing answer sequence.
rm -f "$SETTINGS"
mkdir -p "$TMP_DIR/repo/.dex"
git init -q "$TMP_DIR/repo"
git -C "$TMP_DIR/repo" config user.email test@example.com
git -C "$TMP_DIR/repo" config user.name Test
printf '%s\n' '# Dex project' > "$TMP_DIR/repo/.dex/dex.md"
(
  cd "$TMP_DIR/repo"
  printf '%s\n' 3 n n n n n n n '' \
    | PATH=/usr/bin:/bin bash "$ROOT/bin/config.sh"
) > "$TMP_DIR/config.out" 2>&1 || true
assert_not_contains 'Auto-accept messages' "$TMP_DIR/config.out"
assert_no_file "$SETTINGS"
assert_contains 'Integrations configured' "$TMP_DIR/config.out"

# A settings file this helper cannot write must warn without aborting the rest
# of dx config, which still has dex.md to write.
printf '%s\n' '{not json' > "$SETTINGS"
(
  cd "$TMP_DIR/repo"
  printf '%s\n' 3 n n n n n n n '' \
    | PATH=/usr/bin:/bin bash "$ROOT/bin/config.sh"
) > "$TMP_DIR/broken.out" 2>&1 || true
assert_contains 'Integrations configured' "$TMP_DIR/broken.out"

printf 'cross-session inbound tests passed\n'
