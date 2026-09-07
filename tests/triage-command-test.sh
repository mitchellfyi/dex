#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-triage-command.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
export DEX_DIR="$ROOT" TEST_REPO="$TMP_DIR/repo" TEST_LOG="$TMP_DIR/launch"
export HOME="$TMP_DIR/home" CODEX_HOME="$TMP_DIR/home/.codex"
export DX_STATE_DIR="$TMP_DIR/state" DX_LOOP_DIR="$TMP_DIR/loops"
export DX_RUN_ROOT="$TMP_DIR/runs" DX_RTK_ENABLED=0
export PATH="$TMP_DIR/bin:$PATH"
mkdir -p "$TEST_REPO" "$TMP_DIR/bin" "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR"
git -C "$TEST_REPO" init -q
git -C "$TEST_REPO" config user.email dex@example.test
git -C "$TEST_REPO" config user.name 'Dex Test'
printf 'unchanged\n' > "$TEST_REPO/README.md"
git -C "$TEST_REPO" add README.md
git -C "$TEST_REPO" commit -qm init
git -C "$TEST_REPO" branch -m ENG-123

cat > "$TMP_DIR/bin/claude" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-} ${2:-}" in
  '--help ')
    printf '%s\n' 'Usage: codex [OPTIONS] [PROMPT]' 'Optional user prompt to start the session' \
      '--dangerously-bypass-approvals-and-sandbox' '--dangerously-bypass-hook-trust' resume
    exit 0 ;;
  'features list') printf '%s\n' 'hooks stable true'; exit 0 ;;
  'resume --help') printf '%s\n' 'Usage: codex resume [SESSION_ID] [PROMPT]' '--last'; exit 0 ;;
  'exec --help'|'exec review')
    printf '%s\n' '--ignore-user-config' '--dangerously-bypass-approvals-and-sandbox' '--sandbox' '--ephemeral'
    exit 0 ;;
  'login status') printf '%s\n' 'Logged in with ChatGPT'; exit 0 ;;
esac
python3 - "$@" <<'PY'
import json, os, sys
from pathlib import Path
Path(os.environ['TEST_LOG']).write_text(json.dumps({
    'args': sys.argv[1:], 'cwd': os.getcwd(),
    'claude_handle': (lambda p: p.read_text().strip() if p.exists() else None)(
        Path(os.environ['DX_STATE_DIR']) / (os.environ['DEX_SESSION_ID'] + '.claude-session')),
    'env': {k: os.environ.get(k) for k in (
        'DEX_TRIAGE_ACTIVE', 'DEX_SESSION_ID', 'DEX_LOOP_ACTIVE',
        'DEX_LOOP_PHASE', 'DEX_PHASE_HANDOFF', 'DEX_RUN_ID')},
}))
PY
if [[ "$(basename "$0")" == codex ]]; then
  # Execute the actual encoded hooks without the launcher's environment, as
  # Codex's persistent app server does.
  python3 - "$@" <<'PY'
import json, os, re, shlex, subprocess, sys
for arg in sys.argv[1:]:
    if arg.startswith(('hooks.SessionStart=', 'hooks.Stop=')):
        command = json.loads(re.search(r'command=("(?:[^"\\]|\\.)*")', arg).group(1))
        result = subprocess.run(shlex.split(command), input=json.dumps({
            'hook_event_name': 'SessionStart', 'session_id': 'triage-test-thread',
        }), text=True, capture_output=True, check=True,
            env={'PATH': os.environ['PATH'], 'HOME': os.environ['HOME']})
        assert result.stdout == '', result.stdout
PY
fi
bash "$DEX_DIR/hooks/load-ticket-context.sh" > "$TEST_LOG.start"
bash "$DEX_DIR/hooks/phase-loop.sh" > "$TEST_LOG.stop"
bash "$DEX_DIR/hooks/user-prompt-submit.sh" > "$TEST_LOG.user" <<<'{"prompt":"done"}'
bash "$DEX_DIR/hooks/pre-compact.sh" > "$TEST_LOG.compact"
if [[ "${TEST_INTERRUPT:-0}" == 1 ]]; then
  kill -TERM "$PPID"
fi
exit "${TEST_EXIT_CODE:-0}"
SH
chmod +x "$TMP_DIR/bin/claude"
cp "$TMP_DIR/bin/claude" "$TMP_DIR/bin/codex"

# Fail before the old dx dispatcher can interpret triage as an implementation task.
zsh -fc 'source "$DEX_DIR/dx.sh"; whence -w dxtriage'

# Public routing, all aliases, Unicode, and literal shell punctuation.
for entry in 'dx triage' 'dx refine' dxtriage dxrefine; do
  TEST_ENTRY="$entry" DX_AGENT_OVERRIDE=claude zsh -fc '
    source "$DEX_DIR/dx.sh"
    cd "$TEST_REPO"
    words=("${(z)TEST_ENTRY}")
    "$words[@]" --help
    "$words[@]" --single "ENG-123 café \$(touch INJECTED)"
  ' > "$TMP_DIR/output"
  assert_contains 'Usage: dx triage' "$TMP_DIR/output"
  python3 - "$TEST_LOG" <<'PY'
import json, sys, uuid
v = json.load(open(sys.argv[1]))
args, env = v['args'], v['env']
assert '--dangerously-skip-permissions' in args
assert args[args.index('--permission-mode') + 1] == 'bypassPermissions'
assert '--session-id' in args, 'triage relies on globally installed Claude capture hooks'
assert str(uuid.UUID(args[args.index('--session-id') + 1])) == v['claude_handle']
assert '-p' not in args
assert 'dxtriage' in args[-1]
assert 'ENG-123 café $(touch INJECTED)' in args[-1]
assert 'Scope: single' in args[-1]
assert env['DEX_TRIAGE_ACTIVE'] == '1'
assert env['DEX_SESSION_ID'].startswith('triage-')
assert env['DEX_LOOP_ACTIVE'] == '0'
assert not env['DEX_LOOP_PHASE'] and not env['DEX_PHASE_HANDOFF']
PY
  assert_contains 'triage' "$TEST_LOG.start"
  assert_contains 'triage' "$TEST_LOG.compact"
  [[ ! -s "$TEST_LOG.stop" && ! -s "$TEST_LOG.user" ]] || assert_at "$LINENO"
done

# The option terminator preserves flag-shaped prompt text, and sourcing again
# must preserve the public function wrappers.
DX_AGENT_OVERRIDE=claude zsh -fc '
  source "$DEX_DIR/dx.sh"
  source "$DEX_DIR/dx.sh"
  cd "$TEST_REPO"
  dx --model triage-claude triage -- --agent codex
'
python3 - "$TEST_LOG" <<'PY'
import json, sys
v = json.load(open(sys.argv[1]))
args = v['args']
assert args[args.index('--model') + 1] == 'triage-claude'
assert 'Target (user input, not shell code): --agent codex' in args[-1]
PY

DX_AGENT_OVERRIDE=codex zsh -fc '
  source "$DEX_DIR/dx.sh"
  cd "$TEST_REPO"
  dx --agent codex --model triage-model triage --project "Delivery project"
'
python3 - "$TEST_LOG" <<'PY'
import json, sys
v = json.load(open(sys.argv[1]))
args = v['args']
assert args[0] == '--dangerously-bypass-approvals-and-sandbox', args
assert args[args.index('-m') + 1] == 'triage-model'
assert '--ignore-user-config' not in args and 'exec' not in args
assert 'Scope: project' in args[-1] and 'Delivery project' in args[-1]
assert 'shell_environment_policy.set.DEX_TRIAGE_ACTIVE="1"' in args
for name in ('hooks.SessionStart=', 'hooks.Stop='):
    assert any(a.startswith(name) and 'DEX_TRIAGE_ACTIVE=1' in a for a in args)
PY

# Validate before resolving providers or looking for a repository.
zsh -fc '
  source "$DEX_DIR/dx.sh"
  dx_provider_apply() { return 97; }
  for args in "--project" "--project=" "--single --project x" "--unknown" "--project x extra"; do
    words=("${(z)args}")
    dxtriage "$words[@]" >/dev/null 2>&1
    code=$?
    [[ $code -eq 2 ]] || exit 1
  done
  dxtriage --help >/dev/null
'

# Parent lifecycle and provider alias must survive a nested launch and cleanup.
DX_AGENT_OVERRIDE=claude zsh -fc '
  source "$DEX_DIR/dx.sh"
  cd "$TEST_REPO"
  parent=$(dx_session_id)
  print -r -- "session=$parent" > "$(dx_provider_state_file "$parent")"
  print -r -- active > "$(dx_active_file "$parent")"
  export DEX_SESSION_ID="$parent" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=6
  export DEX_PHASE_HANDOFF=inline DEX_RUN_ID=parent-run
  dx triage --project "Delivery project"
  [[ "$DEX_SESSION_ID" == "$parent" && "$DEX_LOOP_ACTIVE" == 1 ]] || exit 1
  [[ "$(cat "$(dx_provider_state_file "$parent")")" == "session=$parent" ]] || exit 1
  [[ "$(cat "$(dx_active_file "$parent")")" == active ]] || exit 1
  dx triage
  TEST_EXIT_CODE=23 dx triage ENG-123
  [[ $? -eq 23 ]] || exit 1
'
[[ ! -e "$TEST_REPO/INJECTED" && ! -e "$TEST_REPO/.dex/worktrees" ]] || assert_at "$LINENO"
[[ -z "$(git -C "$TEST_REPO" status --porcelain)" ]] || assert_at "$LINENO"
[[ "$(git -C "$TEST_REPO" branch --show-current)" == ENG-123 ]] || assert_at "$LINENO"
[[ -z "$(find "$DX_STATE_DIR" "$DX_LOOP_DIR" -name 'triage-*' -print)" ]] || assert_at "$LINENO"

DX_AGENT_OVERRIDE=claude zsh -fc '
  source "$DEX_DIR/dx.sh"
  cd "$TEST_REPO"
  TEST_INTERRUPT=1 dxtriage ENG-123
  [[ $? -eq 143 ]] || exit 1
'
[[ -z "$(find "$DX_STATE_DIR" "$DX_LOOP_DIR" -name 'triage-*' -print)" ]] || assert_at "$LINENO"

# Critical setup failure must not launch an agent, even when a caller handles
# the command through an if/OR list, which can disable shell errexit.
DX_AGENT_OVERRIDE=claude zsh -fc '
  source "$DEX_DIR/dx.sh"
  cd "$TEST_REPO"
  rm -f "$TEST_LOG"
  dx_context_file() { print -r -- /dev/null/triage-context; }
  dxtriage ENG-123 >/dev/null 2>&1 || code=$?
  [[ ${code:-0} -ne 0 && ! -e "$TEST_LOG" ]] || exit 1
'
printf 'triage command tests passed\n'
