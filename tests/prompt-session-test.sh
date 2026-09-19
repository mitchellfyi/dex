#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"

python3 - "$ROOT" <<'PY'
import errno
import json
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import sys
import tempfile
import time

root = Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='dex-prompt-session-') as temporary:
    base = Path(temporary)
    repo, binaries = base / 'repo', base / 'bin'
    for directory in (repo / 'subdir', binaries, base / 'home', base / 'state', base / 'loops'):
        directory.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, HOME=str(base / 'home'), CODEX_HOME=str(base / 'home/.codex'),
               DEX_DIR=str(root), DX_STATE_DIR=str(base / 'state'), DX_LOOP_DIR=str(base / 'loops'),
               DX_RUN_ROOT=str(base / 'runs'), DX_RTK_ENABLED='0', TEST_LOG=str(base / 'launch.json'),
               PATH=str(binaries) + os.pathsep + os.environ['PATH'])
    for name in ('DX_AGENT', 'DX_AGENT_OVERRIDE', 'DX_MODEL', 'DX_MODEL_OVERRIDE',
                 'DX_EFFORT', 'DX_EFFORT_OVERRIDE', 'DX_PROVIDER_PROFILE', 'DEX_TRIAGE_ACTIVE'):
        env.pop(name, None)
    subprocess.run(['git', 'init', '-q', str(repo)], check=True, env=env)
    subprocess.run(['git', '-C', str(repo), 'checkout', '-qb', 'ENG-123'], check=True, env=env)
    (repo / 'README.md').write_text('untouched\n')
    (repo / 'subdir/user.txt').write_text('uncommitted user work\n')
    stub = r'''#!/usr/bin/env python3
import json, os, re, shlex, subprocess, sys
from pathlib import Path
args = sys.argv[1:]
name = Path(sys.argv[0]).name
if name == 'node':
    if args[0] == '-e':
        sys.exit(0)
    assert args[0].endswith('/scripts/ccr/cli.cjs') and args[1:3] == ['launch', '--'], args
    args = args[3:]
if args == ['--help']:
    print('Usage: codex [OPTIONS] [PROMPT]\nOptional user prompt to start the session\n--dangerously-bypass-approvals-and-sandbox\n--dangerously-bypass-hook-trust\nresume')
    sys.exit(0)
if args[:2] == ['features', 'list']:
    print('hooks stable true'); sys.exit(0)
if args[:2] == ['resume', '--help']:
    print('Usage: codex resume [SESSION_ID] [PROMPT]\n--last'); sys.exit(0)
if args[:2] in (['exec', '--help'], ['exec', 'review']):
    print('--ignore-user-config\n--dangerously-bypass-approvals-and-sandbox\n--sandbox\n--ephemeral'); sys.exit(0)
if args[:2] == ['login', 'status']:
    print('Logged in with ChatGPT'); sys.exit(0)
hook_outputs = {}
for hook in ('load-ticket-context', 'phase-loop', 'user-prompt-submit', 'session-end', 'pre-compact'):
    result = subprocess.run(['bash', os.environ['DEX_DIR'] + '/hooks/' + hook + '.sh'],
                            input='{"prompt":"done"}', text=True, capture_output=True, check=True)
    hook_outputs[hook] = result.stdout
if name == 'codex':
    for arg in args:
        if arg.startswith(('hooks.SessionStart=', 'hooks.Stop=')):
            command = json.loads(re.search(r'command=("(?:[^"\\]|\\.)*")', arg).group(1))
            result = subprocess.run(shlex.split(command), text=True, capture_output=True, check=True,
                input='{"hook_event_name":"SessionStart","session_id":"prompt-test-thread"}',
                env={'PATH': os.environ['PATH'], 'HOME': os.environ['HOME']})
            assert not result.stdout, result.stdout
Path(os.environ['TEST_LOG']).write_text(json.dumps({
    'binary': name, 'args': args, 'cwd': os.getcwd(), 'hooks': hook_outputs,
    'env': {key: os.environ.get(key) for key in ('DEX_SESSION_ID', 'DEX_SESSION_ONLY',
        'DEX_LOOP_ACTIVE', 'DEX_LOOP_PHASE', 'DEX_PHASE_HANDOFF', 'DEX_RUN_ID', 'DX_ROUTER_SESSION_ID')}
}))
sys.exit(int(os.environ.get('TEST_EXIT_CODE', '0')))
'''
    for name in ('claude', 'codex', 'node'):
        target = binaries / name
        target.write_text(stub)
        target.chmod(0o755)
    shell = 'source "$DEX_DIR/dx.sh"\n'
    boundary = '''
__dx_setup_worktree() { print -r -- "WORKFLOW:$1"; return 71; }
__dx_setup_in_place() { print -r -- "IN_PLACE:$1"; return 71; }
'''

    def invoke(args, extra=None, prefix=''):
        return subprocess.run(['zsh', '-fc', shell + prefix + '\ndx "$@"', 'prompt-test', *args],
            env=dict(env, **(extra or {})), cwd=repo / 'subdir', text=True, capture_output=True)

    def snapshot():
        return {str(p.relative_to(base)): p.read_bytes()
                for directory in ('repo', 'state', 'loops') for p in (base / directory).rglob('*') if p.is_file()}

    for command in ('route', 'model', 'context', 'control', 'sessions', 'run'):
        args = [command, 'status', '--session', 'fake-session', '--json']
        result = invoke(args, prefix='__dx_cli() { print -rl -- "$@"; }')
        assert result.returncode == 0 and result.stdout.splitlines() == args, (result.stdout, result.stderr)
        assert not (base / 'launch.json').exists(), 'management selector launched a chat'

    alias = subprocess.check_output(['zsh', '-fc', shell + 'dx_session_id'], env=env, cwd=repo, text=True).strip()
    (base / 'loops' / (alias + '.provider')).write_text('session=parent\nengine=claude\n')
    (base / 'loops/parent.active').write_text('active\n')
    (base / 'state/parent.phase').write_text('6\n')
    before = snapshot()
    prompt = 'explain café $(touch INJECTED) `touch ALSO_INJECTED`\nwithout changing files'
    for profile, binary in (('claude-subscription', 'claude'), ('codex-subscription', 'codex'), ('ccr-subscription', 'node')):
        result = invoke(['--session', '--model', 'test-model', prompt], dict(
            DX_PROVIDER_PROFILE=profile, DEX_SESSION_ID='parent', DEX_LOOP_ACTIVE='1',
            DEX_LOOP_PHASE='6', DEX_PHASE_HANDOFF='inline', DEX_RUN_ID='parent-run',
            DX_ROUTER_SESSION_ID='parent-route'))
        assert result.returncode == 0, result.stderr + result.stdout
        data = json.loads((base / 'launch.json').read_text())
        assert data['binary'] == binary and data['args'][-2:] == ['--', prompt], data
        assert Path(data['cwd']).resolve() == (repo / 'subdir').resolve(), data
        assert data['env']['DEX_SESSION_ONLY'] == '1' and data['env']['DEX_LOOP_ACTIVE'] == '0', data
        assert data['env']['DEX_SESSION_ID'].startswith('prompt-'), data
        assert all(not data['env'][k] for k in ('DEX_LOOP_PHASE', 'DEX_PHASE_HANDOFF', 'DEX_RUN_ID', 'DX_ROUTER_SESSION_ID')), data
        assert all(not data['hooks'][k] for k in ('phase-loop', 'user-prompt-submit', 'session-end')), data
        assert 'No ticket intake or lifecycle is active' in data['hooks']['load-ticket-context'], data
        if binary == 'codex':
            assert 'exec' not in data['args'] and '--ignore-user-config' not in data['args'], data
            assert 'shell_environment_policy.set.DEX_SESSION_ONLY="1"' in data['args'], data
        assert snapshot() == before, 'session changed checkout or parent state'

    for text in ('--model', '--resume', 'help'):
        result = invoke(['--session', '--', text], {'DX_PROVIDER_PROFILE': 'claude-subscription'})
        assert result.returncode == 0, result.stderr
        assert json.loads((base / 'launch.json').read_text())['args'][-1] == text
    assert invoke(['--session', 'plain prompt'], {'DX_PROVIDER_PROFILE': 'claude-subscription', 'TEST_EXIT_CODE': '23'}).returncode == 23
    assert snapshot() == before
    for args in (['plain prompt'], ['--session', '--workflow', 'plain prompt'], ['--session', '--worktree', 'plain prompt']):
        (base / 'launch.json').unlink(missing_ok=True)
        result = invoke(args)
        assert result.returncode == 2 and not (base / 'launch.json').exists(), (args, result.stdout, result.stderr)
    for args, output in ((['123'], 'WORKFLOW:123'), (['ENG-456'], 'WORKFLOW:ENG-456'),
                         (['--workflow', 'plain prompt'], 'WORKFLOW:plain prompt'),
                         (['--no-worktree', 'plain prompt'], 'IN_PLACE:plain prompt'),
                         (['--no-worktree', '--', '--resume'], 'IN_PLACE:--resume')):
        result = invoke(args, {'DX_PROVIDER_PROFILE': 'claude-subscription'}, boundary)
        assert result.returncode == 1 and output in result.stdout, (args, result.stdout, result.stderr)

    def choose(answer):
        master, slave = pty.openpty()
        process = subprocess.Popen(['zsh', '-fc', shell + boundary + '\ndx "plain prompt"'],
            env=dict(env, DX_PROVIDER_PROFILE='claude-subscription'), cwd=repo / 'subdir',
            stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
        os.close(slave)
        output, sent = b'', False
        deadline = time.monotonic() + 30
        try:
            while time.monotonic() < deadline:
                if select.select([master], [], [], .1)[0]:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError as error:
                        if error.errno == errno.EIO:
                            break
                        raise
                    if not chunk:
                        break
                    output += chunk
                    if b'Choice [1]' in output and not sent:
                        os.write(master, answer)
                        sent = True
                elif process.poll() is not None:
                    break
            assert sent, output.decode(errors='replace')
            return process.wait(timeout=5), output.decode(errors='replace')
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            os.close(master)

    for answer in (b'\n', b'invalid\n\n', b'1\n'):
        code, output = choose(answer)
        assert code == 0 and 'Session only: claude-subscription' in output and 'WORKFLOW:' not in output, output
    code, output = choose(b'2\n')
    assert code == 1 and 'WORKFLOW:plain prompt' in output, output
    for answer in (b'q\n', b'\x04'):
        code, output = choose(answer)
        assert code == 1 and 'Nothing started' in output and 'WORKFLOW:' not in output, output
    assert snapshot() == before
print('prompt session tests passed')
PY
