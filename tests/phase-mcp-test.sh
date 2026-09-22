#!/usr/bin/env bash
# Browsers and MCP servers only when a phase needs them:
#   - the four phases that never open a browser launch with an empty MCP config
#   - the phases that do keep whatever the session inherited
#   - a browser MCP inside a session puts its profile under DX_SESSION_TMP
#   - outside a session the browser MCP command line is exactly what it was
#   - dx ui-capture install registers at user scope; --project and --local are explicit
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"

# Resolve the real node binary before anything replaces HOME, and from the
# account's own home rather than whatever HOME currently says: a version
# manager's shim (Volta) finds its toolchain under $HOME, and both this file
# and tests/run-all.sh hand it a hermetic one. The absolute path needs no HOME,
# so every node call below uses it.
REAL_HOME="$(python3 -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)' 2>/dev/null || true)"
NODE_BIN="$(HOME="${REAL_HOME:-$HOME}" node -e 'process.stdout.write(process.execPath)' 2>/dev/null || true)"
[[ -n "$NODE_BIN" && -x "$NODE_BIN" ]] || NODE_BIN=""

# Node normalizes the separators in every path it prints, so the temp root has
# to start out with single separators only — no trailing slash (macOS puts one
# on TMPDIR) and no doubled slash inside it (the test runner nests a TMPDIR
# under that one) — otherwise the assertions compare `T//dex-…` against `T/dex-…`.
# Symlinks are left alone: Node does not resolve them either.
TMP_BASE="$(printf '%s' "${TMPDIR:-/tmp}" | sed 's#//*#/#g')"
TMP_DIR="$(mktemp -d "${TMP_BASE%/}/dex-phase-mcp-test.XXXXXX")"
export HOME="$TMP_DIR/home"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
export DX_TOOL_DIR="$TMP_DIR/tools"
export DX_RUN_ROOT="$TMP_DIR/runs"
export DEXCODE_SYNC=0
export DEX_DIR="$ROOT"
mkdir -p "$HOME" "$DX_LOOP_DIR"

cleanup() {
  chmod -R u+w "$TMP_DIR" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"

# --- the phase decides whether the launch carries MCP servers ----------------

mkdir -p "$TMP_DIR/provider-bin"
cat > "$TMP_DIR/provider-bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$DX_TEST_ARGV_FILE"
STUB
chmod +x "$TMP_DIR/provider-bin/claude"

# provider_fixture <argv-file> — a launch that records exactly what claude got.
provider_fixture() {
  export PATH="$TMP_DIR/provider-bin:$PATH"
  export DX_PROVIDER_APPLIED=1 DX_PROVIDER_ENGINE=claude DX_PROVIDER_PROFILE_RESOLVED=claude
  export DX_TEST_ARGV_FILE="$1"
  unset DEX_SESSION_ID DEX_LOOP_ACTIVE DEX_LOOP_PHASE DEX_LIFECYCLE_MINIMAL_MCP
  unset DEX_PHASE_HANDOFF
}

# mcp_config_path <argv-file> — the --mcp-config value the launch passed.
mcp_config_path() {
  grep -A1 -Fx -- '--mcp-config' "$1" | tail -1
}

# A launch that ends with its phase — Codex's direct handoff, a headless run,
# `dxplan`, `dxcomplete` — and the phase never opens a browser: Plan, Verify,
# PR, Complete.
for phase in 1 4 5 6; do
  argv_file="$TMP_DIR/phase-$phase.argv"
  (
    provider_fixture "$argv_file"
    export DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE="$phase"
    dx_provider_claude -p "task"
  )
  assert_contains "--strict-mcp-config" "$argv_file"
  assert_contains "--mcp-config" "$argv_file"
  config_file="$(mcp_config_path "$argv_file")"
  assert_eq "$DX_LOOP_DIR/empty-mcp.json" "$config_file" "phase $phase MCP config path"
  assert_file "$config_file"
  assert_eq '{"mcpServers":{}}' "$(cat "$config_file")" "phase $phase MCP config content"
  # Ahead of everything the caller passed, so the flags can never land between
  # an option and its value or after the prompt.
  assert_eq "--strict-mcp-config" "$(sed -n '1p' "$argv_file")" \
    "phase $phase leads with --strict-mcp-config"
  assert_eq "--mcp-config" "$(sed -n '2p' "$argv_file")" \
    "phase $phase passes --mcp-config second"
  assert_eq "$config_file" "$(sed -n '3p' "$argv_file")" \
    "phase $phase passes the config path third"
  assert_eq "-p" "$(sed -n '4p' "$argv_file")" "phase $phase leaves the caller's argv intact"
  # Nothing else was added, and the task prompt still arrived.
  assert_contains "task" "$argv_file"
  assert_eq "1" "$(grep -cx -- '--mcp-config' "$argv_file" | tr -d '[:space:]')" \
    "phase $phase passes one MCP config"
done

# An inline lifecycle runs several phases in one provider process, and the MCP
# configuration is fixed at launch. A Phase 1 launch there goes on to run
# Phase 2, so it keeps the browser; 4, 5 and 6 are followed only by each other.
(
  provider_fixture "$TMP_DIR/inline-1.argv"
  export DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=1 DEX_PHASE_HANDOFF=inline
  dx_provider_claude -p "task"
)
assert_not_contains "--strict-mcp-config" "$TMP_DIR/inline-1.argv"

for phase in 4 5 6; do
  argv_file="$TMP_DIR/inline-$phase.argv"
  (
    provider_fixture "$argv_file"
    export DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE="$phase" DEX_PHASE_HANDOFF=inline
    dx_provider_claude -p "task"
  )
  assert_contains "--strict-mcp-config" "$argv_file"
done

# A phase that does open a browser keeps the session's own MCP servers. Phase 2
# is where UI proof is captured; 0 and 3 are the other two that keep them.
for phase in 0 2 3; do
  argv_file="$TMP_DIR/keep-$phase.argv"
  (
    provider_fixture "$argv_file"
    export DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE="$phase"
    dx_provider_claude -p "task"
  )
  assert_not_contains "--strict-mcp-config" "$argv_file"
  assert_not_contains "--mcp-config" "$argv_file"
done

# Off by request, and off outside a lifecycle: a session-only or standalone
# launch never carries a phase, and an interactive claude never comes here.
(
  provider_fixture "$TMP_DIR/opt-out.argv"
  export DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=4 DEX_LIFECYCLE_MINIMAL_MCP=0
  dx_provider_claude -p "task"
)
assert_not_contains "--strict-mcp-config" "$TMP_DIR/opt-out.argv"

(
  provider_fixture "$TMP_DIR/no-lifecycle.argv"
  export DEX_LOOP_PHASE=4
  dx_provider_claude -p "task"
)
assert_not_contains "--strict-mcp-config" "$TMP_DIR/no-lifecycle.argv"

# A caller that stated its own MCP configuration keeps it — review waves and
# `dx context scope` both do, and a second config would fight theirs.
(
  provider_fixture "$TMP_DIR/caller.argv"
  export DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=4
  dx_provider_claude --strict-mcp-config --mcp-config "$TMP_DIR/caller-mcp.json" -p "task"
)
assert_eq "1" "$(grep -cx -- '--mcp-config' "$TMP_DIR/caller.argv" | tr -d '[:space:]')" \
  "an explicit caller config is not doubled"
assert_eq "$TMP_DIR/caller-mcp.json" "$(mcp_config_path "$TMP_DIR/caller.argv")" \
  "the caller's own config survives"

# Two launches from one shell: the flags belong to the call, not to the shell.
(
  provider_fixture "$TMP_DIR/twice.argv"
  export DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=4
  dx_provider_claude -p "first"
  : > "$TMP_DIR/twice.argv"
  dx_provider_claude -p "second"
)
assert_eq "1" "$(grep -cx -- '--strict-mcp-config' "$TMP_DIR/twice.argv" | tr -d '[:space:]')" \
  "a second launch does not accumulate flags"
assert_contains "second" "$TMP_DIR/twice.argv"

# --- browser profiles live and die with the session --------------------------

if [[ -n "$NODE_BIN" ]]; then
  mkdir -p "$TMP_DIR/browser-tools/ui-capture/node_modules/playwright"
  BROWSER_MODULE="$TMP_DIR/browser-tools/ui-capture/node_modules/playwright"
  : > "$BROWSER_MODULE/chromium"
  printf 'exports.chromium = { executablePath: () => %s };\n' \
    "\"$BROWSER_MODULE/chromium\"" > "$BROWSER_MODULE/index.js"

  SESSION_TMP="$TMP_DIR/session-tmp"
  mkdir -p "$SESSION_TMP"
  DX_TOOL_DIR="$TMP_DIR/browser-tools" DX_SESSION_TMP="$SESSION_TMP" \
    "$NODE_BIN" --input-type=commonjs - "$DEX_DIR/scripts/browser-mcp.cjs" <<'JS'
const assert = require('node:assert/strict');
const path = require('node:path');
const { command, playwright, profile, packages } = require(process.argv[2]);
const env = { DX_TOOL_DIR: process.env.DX_TOOL_DIR, DX_SESSION_TMP: process.env.DX_SESSION_TMP };
const executable = playwright(env).chromium.executablePath();
const headless = process.platform === 'linux' ? ['--headless'] : [];

// Without a session the command line is exactly what it has always been.
for (const name of ['playwright', 'chrome-devtools']) {
  const flag = name === 'playwright' ? '--executable-path' : '--executablePath';
  const bare = { DX_TOOL_DIR: env.DX_TOOL_DIR };
  assert.deepEqual(command(name, [], bare, profile(name, [], bare)),
    ['npx', '-y', packages[name], flag, executable, '--isolated', ...headless]);
}

// With one, each server is handed a profile directory under the session root.
// Both refuse a profile alongside --isolated, and only spell the flag
// differently: --user-data-dir for playwright, --userDataDir for chrome-devtools.
for (const [name, flag, profileFlag] of [
  ['playwright', '--executable-path', '--user-data-dir'],
  ['chrome-devtools', '--executablePath', '--userDataDir'],
]) {
  const session = profile(name, [], env);
  assert.equal(session, path.join(env.DX_SESSION_TMP, `browser-${name}`));
  const argv = command(name, [], env, session);
  assert.deepEqual(argv,
    ['npx', '-y', packages[name], flag, executable, `${profileFlag}=${session}`, ...headless]);
  assert.ok(!argv.includes('--isolated'));
}

// A caller that named its own profile is left alone, and nothing is minted.
assert.equal(profile('playwright', ['--user-data-dir', '/fake/custom'], env), '');
assert.equal(profile('chrome-devtools', ['--browserUrl=http://127.0.0.1:9222'], env), '');
JS

  PROFILE_RECORD="$SESSION_TMP/browser-profiles.txt"
  assert_file "$PROFILE_RECORD"
  assert_dir "$SESSION_TMP/browser-playwright"
  assert_dir "$SESSION_TMP/browser-chrome-devtools"
  assert_contains "$SESSION_TMP/browser-playwright" "$PROFILE_RECORD"
  assert_contains "$SESSION_TMP/browser-chrome-devtools" "$PROFILE_RECORD"
  assert_eq "2" "$(wc -l < "$PROFILE_RECORD" | tr -d '[:space:]')" \
    "each profile is recorded once"

  # The whole script, end to end: the server it starts is given the profile,
  # and re-running it does not record a second line. This runs $NODE_BIN, the
  # real binary resolved at the top, rather than a launcher shim, which would
  # prepend its own toolchain to the child's PATH and put the real npx ahead of
  # the stub below.
  mkdir -p "$TMP_DIR/npx-bin"
  cat > "$TMP_DIR/npx-bin/npx" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$DX_TEST_NPX_ARGV"
printf '%s\n' "${TMPDIR:-unset}" > "$DX_TEST_NPX_TMPDIR"
STUB
  chmod +x "$TMP_DIR/npx-bin/npx"

  for server in playwright chrome-devtools; do
    (
      export PATH="$TMP_DIR/npx-bin:$PATH"
      export DX_TOOL_DIR="$TMP_DIR/browser-tools" DX_SESSION_TMP="$SESSION_TMP"
      export DX_TEST_NPX_ARGV="$TMP_DIR/npx-$server.argv"
      export DX_TEST_NPX_TMPDIR="$TMP_DIR/npx-$server.tmpdir"
      "$NODE_BIN" "$DEX_DIR/scripts/browser-mcp.cjs" "$server"
    )
  done
  assert_contains "--user-data-dir=$SESSION_TMP/browser-playwright" "$TMP_DIR/npx-playwright.argv"
  assert_contains "--userDataDir=$SESSION_TMP/browser-chrome-devtools" "$TMP_DIR/npx-chrome-devtools.argv"
  assert_not_contains "--isolated" "$TMP_DIR/npx-chrome-devtools.argv"
  assert_eq "2" "$(wc -l < "$PROFILE_RECORD" | tr -d '[:space:]')" \
    "a second start reuses the recorded profile"
  # The server's own temporary directory is left alone: screenshots, traces and
  # screencasts are written under it, and a session temp root that the phase
  # reap deletes is the wrong place for UI proof.
  for server in playwright chrome-devtools; do
    assert_eq "${TMPDIR:-unset}" "$(cat "$TMP_DIR/npx-$server.tmpdir")" \
      "$server keeps the inherited temporary directory"
  done

  # Session end removes the temp root, and the profiles with it.
  rm -rf "${SESSION_TMP:?}"
  assert_no_file "$SESSION_TMP/browser-playwright"
else
  printf 'skip: node does not run under this test HOME; browser profile checks skipped\n'
fi

# --- dx ui-capture install registers where Dex can scope it ------------------

mkdir -p "$TMP_DIR/mcp-bin"
cat > "$TMP_DIR/mcp-bin/claude" <<'STUB'
#!/usr/bin/env bash
# The working directory matters: a project-scope add writes .mcp.json there.
printf '%s\n' "$*" >> "$DX_TEST_MCP_LOG"
printf '%s\n' "$PWD" >> "$DX_TEST_MCP_LOG.cwd"
[[ "${2:-}" != "get" ]]
STUB
chmod +x "$TMP_DIR/mcp-bin/claude"

mkdir -p "$TMP_DIR/repo/deep/nested" "$TMP_DIR/plain"
git -C "$TMP_DIR/repo" init --quiet >/dev/null 2>&1
REPO_TOP="$(cd "$TMP_DIR/repo" && pwd -P)"

install_claude_mcp() {
  # install_claude_mcp <log> <cwd> [scope-argument]
  local log="$1" workdir="$2" requested="${3:-}"
  : > "$log"
  : > "$log.cwd"
  (
    export PATH="$TMP_DIR/mcp-bin:$PATH"
    export DX_TEST_MCP_LOG="$log"
    unset DEX_UI_MCP_SCOPE
    cd "$workdir" || exit 1
    dx_install_claude_ui_mcp_servers "$requested"
  ) >/dev/null 2>"$log.err"
}

# User scope is the default: project scope would write an absolute Dex path
# into the repository's tracked .mcp.json, and a lifecycle worktree never sees
# that file. The minimal-MCP launch is what keeps browsers out of the phases
# that need none; the scope is not that lever.
install_claude_mcp "$TMP_DIR/mcp-default.log" "$TMP_DIR/repo"
assert_contains "mcp add --scope user playwright -- node" "$TMP_DIR/mcp-default.log"
assert_contains "mcp add --scope user chrome-devtools -- node" "$TMP_DIR/mcp-default.log"
assert_not_contains "--scope project" "$TMP_DIR/mcp-default.log"

install_claude_mcp "$TMP_DIR/mcp-project.log" "$TMP_DIR/repo" project
assert_contains "mcp add --scope project playwright -- node" "$TMP_DIR/mcp-project.log"
assert_contains "mcp add --scope project chrome-devtools -- node" "$TMP_DIR/mcp-project.log"
assert_not_contains "--scope user" "$TMP_DIR/mcp-project.log"

# A project-scope add writes .mcp.json into the working directory, so it has to
# run from the checkout root even when the caller is deep inside the tree.
install_claude_mcp "$TMP_DIR/mcp-subdir.log" "$TMP_DIR/repo/deep/nested" project
assert_contains "mcp add --scope project playwright -- node" "$TMP_DIR/mcp-subdir.log"
while IFS= read -r add_cwd; do
  [[ -n "$add_cwd" ]] || continue
  assert_eq "$REPO_TOP" "$(cd "$add_cwd" && pwd -P)" "the install runs from the checkout root"
done < "$TMP_DIR/mcp-subdir.log.cwd"
[[ -s "$TMP_DIR/mcp-subdir.log.cwd" ]] || assert_at $LINENO

# Project scope writes .mcp.json into the working directory, so a directory
# that is not a checkout falls back rather than leaving a stray file behind.
install_claude_mcp "$TMP_DIR/mcp-plain.log" "$TMP_DIR/plain" project
assert_contains "mcp add --scope user playwright -- node" "$TMP_DIR/mcp-plain.log"
assert_contains "user scope instead of project scope" "$TMP_DIR/mcp-plain.log.err"
assert_no_file "$TMP_DIR/plain/.mcp.json"

# The scope resolver on its own: the default, the environment, the argument
# that beats it, and a value it refuses.
SCOPE_RC=0
(
  cd "$TMP_DIR/repo" || exit 1
  unset DEX_UI_MCP_SCOPE
  assert_eq "user" "$(dx_ui_mcp_scope)" "default scope"
  assert_eq "project" "$(DEX_UI_MCP_SCOPE=project dx_ui_mcp_scope)" "environment scope"
  assert_eq "local" "$(DEX_UI_MCP_SCOPE=project dx_ui_mcp_scope local)" "argument beats the environment"
) || SCOPE_RC=$?
assert_eq "0" "$SCOPE_RC" "scope resolution"
if (cd "$TMP_DIR/repo" && dx_ui_mcp_scope nonsense >/dev/null 2>&1); then
  fail "an unknown MCP scope was accepted"
fi

# dx ui-capture install's option plumbing, without running an npm install or
# touching the Codex CLI this machine may actually have.
tooling_scope() {
  (
    dx_install_ui_capture_playwright() { return 0; }
    dx_install_codex_ui_mcp_servers() { return 0; }
    dx_install_claude_ui_mcp_servers() { printf '%s\n' "${1-unset}" > "$TMP_DIR/tooling-scope"; }
    dx_install_ui_capture_tooling "$@"
  )
  cat "$TMP_DIR/tooling-scope"
}
assert_eq "" "$(tooling_scope)" "no flag asks for no particular scope"
assert_eq "user" "$(tooling_scope --user)" "--user asks for user scope"
assert_eq "project" "$(tooling_scope --project)" "--project asks for project scope"
TOOLING_RC=0
(
  dx_install_ui_capture_playwright() { return 0; }
  dx_install_codex_ui_mcp_servers() { return 0; }
  dx_install_claude_ui_mcp_servers() { return 0; }
  dx_install_ui_capture_tooling --nonsense
) >/dev/null 2>&1 || TOOLING_RC=$?
assert_eq "2" "$TOOLING_RC" "an unknown install option is rejected"

# The CLI's own scope flags. Only the rejection paths are exercised here: the
# accepting path runs an npm install, which a hermetic test must not do.
CLI_RC=0
bash "$ROOT/bin/ui-capture.sh" install --user --project \
  > "$TMP_DIR/cli-conflict.out" 2>&1 || CLI_RC=$?
assert_eq "2" "$CLI_RC" "two scope flags are a contradiction"
assert_contains "cannot both be given" "$TMP_DIR/cli-conflict.out"

CLI_RC=0
bash "$ROOT/bin/ui-capture.sh" show --user \
  > "$TMP_DIR/cli-misplaced.out" 2>&1 || CLI_RC=$?
assert_eq "2" "$CLI_RC" "a scope flag outside install is rejected"
assert_contains "applies to 'dx ui-capture install' only" "$TMP_DIR/cli-misplaced.out"

CLI_RC=0
bash "$ROOT/bin/ui-capture.sh" --help > "$TMP_DIR/cli-help.out" 2>&1 || CLI_RC=$?
assert_eq "0" "$CLI_RC" "usage still prints"
assert_contains "dx ui-capture install [--user|--project|--local]" "$TMP_DIR/cli-help.out"

printf 'phase MCP and browser profile tests passed\n'
