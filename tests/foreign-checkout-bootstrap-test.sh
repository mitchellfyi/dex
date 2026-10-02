#!/usr/bin/env bash
set -euo pipefail

# A Dex checkout that is not the installed one (a worktree, an experiment arm,
# a vendored runtime) must not take the user's installation over. `dx run`
# auto-initialises a repository without .dex/, and init's tooling bootstrap
# used to rewrite every Dex hook in ~/.claude/settings.json to fall back to
# whichever checkout launched it.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-foreign-checkout-test.XXXXXX")"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export CODEX_HOME="$TMP_DIR/codex-home"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_RUN_ROOT="$TMP_DIR/runs"
export DX_RTK_ENABLED=0
export DEXCODE_SYNC=0
export DEXCODE_CONTEXT_SYNC=0
unset DEX_SKIP_TOOL_BOOTSTRAP DEX_WORKFLOW
# No claude, codex or node: if the bootstrap does run, it stays local.
mkdir -p "$HOME/.claude" "$TMP_DIR/bin"
export PATH="$TMP_DIR/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

SETTINGS="$HOME/.claude/settings.json"
INSTALLED="$TMP_DIR/installed-dex"
mkdir -p "$INSTALLED"
render_settings() { # <dex-dir>
  python3 "$ROOT/scripts/settings-json.py" render-template "$ROOT/settings.json" "$1" > "$SETTINGS"
}

# --- which checkout the hooks run ---
[[ -z "$(dx_installed_dex_dirs)" ]] || assert_at $LINENO
if dx_tooling_bootstrap_foreign_checkout >/dev/null; then
  assert_at $LINENO # no Dex hooks yet: a first install, not another checkout
fi
render_settings "$ROOT"
[[ "$(dx_installed_dex_dirs)" == "$ROOT" ]] || assert_at $LINENO
if dx_tooling_bootstrap_foreign_checkout >/dev/null; then
  assert_at $LINENO
fi
# The same checkout reached through a symlink is still this checkout.
ln -s "$ROOT" "$TMP_DIR/dex-link"
render_settings "$TMP_DIR/dex-link"
if dx_tooling_bootstrap_foreign_checkout >/dev/null; then
  assert_at $LINENO
fi
render_settings "$INSTALLED"
[[ "$(dx_installed_dex_dirs)" == "$INSTALLED" ]] || assert_at $LINENO
REASON=$(dx_tooling_bootstrap_foreign_checkout) || assert_at $LINENO
[[ "$REASON" == *"$INSTALLED"* && "$REASON" == *"dx install"* ]] || assert_at $LINENO

# --- init in a repository without .dex/ leaves the installation alone ---
REPO="$TMP_DIR/repo"
git init -q "$REPO"
git -C "$REPO" config user.email dex@example.test
git -C "$REPO" config user.name "Dex Test"
printf '%s\n' "fixture" > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m "test: initialize fixture"

BEFORE=$(cksum < "$SETTINGS")
(cd "$REPO" && bash "$ROOT/bin/init.sh" --skip-analysis --skip-config) > "$TMP_DIR/init.out" 2>&1 \
  || { cat "$TMP_DIR/init.out" >&2; assert_at $LINENO; }
[[ -f "$REPO/.dex/dex.md" ]] || assert_at $LINENO
[[ "$(cksum < "$SETTINGS")" == "$BEFORE" ]] || assert_at $LINENO
[[ ! -e "$HOME/.claude/skills" && ! -L "$HOME/.claude/skills" ]] || assert_at $LINENO
grep -Fq "not this checkout" "$TMP_DIR/init.out" || assert_at $LINENO
if grep -Fq "Claude/Codex tooling installed" "$TMP_DIR/init.out"; then
  assert_at $LINENO
fi

# --- so do the other repository-scoped callers (dx sync, dx tools) ---
dx_bootstrap_agent_tooling "$REPO" install > "$TMP_DIR/bootstrap.out" 2>&1 || assert_at $LINENO
[[ "$(cksum < "$SETTINGS")" == "$BEFORE" ]] || assert_at $LINENO
grep -Fq "not this checkout" "$TMP_DIR/bootstrap.out" || assert_at $LINENO

printf '%s\n' "foreign-checkout-bootstrap-test: ok"
