#!/usr/bin/env python3
"""
Doyaken Guard Handler — evaluates markdown-based guard rules.

Reads Claude Code hook payload JSON from stdin. Also supports
CLAUDE_TOOL_USE_INPUT as a plain-text/manual-test fallback.

Reads guard files from:
  1. $DOYAKEN_DIR/hooks/guards/*.md  (built-in guards)
  2. .doyaken/guards/*.md            (project-specific guards)

Each guard is a markdown file with YAML frontmatter:

  ---
  name: guard-name
  enabled: true
  event: bash|file|commit
  pattern: regex-pattern  # or detector: built-in-detector
  action: warn|block
  ---

  Message body shown when triggered.

Exit codes:
  0 = no guard triggered (or warn only)
  2 = a blocking guard triggered

No external dependencies — stdlib only.
"""
import os
import re
import signal
import subprocess
import sys
import glob
import json
import shlex
import shutil


def parse_frontmatter(text):
    """Parse simple YAML frontmatter without PyYAML. Handles flat key: value pairs.

    Limitations: only supports single-line scalar values (strings, booleans).
    Does not support nested objects, arrays, multiline strings, or anchors.
    This is intentional — guard files use a flat schema. See docs/guards.md.
    """
    result = {}
    for line in text.strip().splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        # Handle "key: value" pairs
        match = re.match(r'^([a-zA-Z_][\w_-]*)\s*:\s*(.*)', line)
        if match:
            key = match.group(1)
            val = match.group(2).strip()
            quoted = False
            # Strip surrounding quotes (require at least 2 chars to avoid
            # corrupting a bare quote character like `key: "`)
            if len(val) >= 2 and (
                (val.startswith('"') and val.endswith('"')) or
                (val.startswith("'") and val.endswith("'"))
            ):
                quoted = True
                val = val[1:-1]
            # Parse booleans (supports YAML-style yes/no as well as true/false)
            if not quoted and val.lower() in ('true', 'yes'):
                val = True
            elif not quoted and val.lower() in ('false', 'no'):
                val = False
            result[key] = val
    return result


def parse_guard(filepath):
    """Parse a guard markdown file with YAML frontmatter."""
    try:
        with open(filepath, 'r') as f:
            content = f.read()
    except (OSError, IOError):
        print(f"[guard] skipped {filepath}: cannot read file", file=sys.stderr)
        return None

    if not content.startswith('---'):
        print(f"[guard] skipped {filepath}: missing frontmatter", file=sys.stderr)
        return None

    parts = content.split('---', 2)
    if len(parts) < 3:
        print(f"[guard] skipped {filepath}: malformed frontmatter", file=sys.stderr)
        return None

    try:
        meta = parse_frontmatter(parts[1])
    except Exception as e:
        print(f"[guard] skipped {filepath}: parse error: {e}", file=sys.stderr)
        return None

    if not meta or not meta.get('enabled', True):
        return None

    meta['message'] = parts[2].strip()
    meta['source'] = filepath
    return meta


def load_guards(event_type):
    """Load all enabled guards for a given event type."""
    guards = []
    doyaken_dir = os.environ.get('DOYAKEN_DIR') or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    # Built-in guards
    builtin_dir = os.path.join(doyaken_dir, 'hooks', 'guards')
    if os.path.isdir(builtin_dir):
        for f in sorted(glob.glob(os.path.join(builtin_dir, '*.md'))):
            g = parse_guard(f)
            if g:
                if not g.get('event'):
                    print(f"[guard] Warning: guard {f} missing 'event' field, skipping", file=sys.stderr)
                elif g['event'] in (event_type, 'all'):
                    guards.append(g)

    # Project-specific guards — resolve project root via git toplevel so guards
    # are found regardless of which subdirectory the tool runs from.
    try:
        project_root = subprocess.check_output(
            ['git', 'rev-parse', '--show-toplevel'],
            text=True, stderr=subprocess.DEVNULL
        ).strip()
    except Exception:
        project_root = os.getcwd()
    project_dir = os.path.join(project_root, '.doyaken', 'guards')
    if os.path.isdir(project_dir):
        for f in sorted(glob.glob(os.path.join(project_dir, '*.md'))):
            g = parse_guard(f)
            if g:
                if not g.get('event'):
                    print(f"[guard] Warning: guard {f} missing 'event' field, skipping", file=sys.stderr)
                elif g['event'] in (event_type, 'all'):
                    guards.append(g)

    return guards


def _timeout_handler(signum, frame):
    """SIGALRM handler for ReDoS protection. Defined at module level to avoid
    creating a new function object per guard iteration."""
    raise TimeoutError()


PROVIDER_BUILTIN_ENGINES = {
    'claude-subscription': 'claude',
    'codex-subscription': 'codex-plugin',
}
PROVIDER_ENGINES = {'claude', 'codex-plugin', 'anthropic-gateway'}


def read_provider_config(path):
    try:
        with open(path, 'r', encoding='utf-8') as f:
            data = json.load(f)
    except Exception:
        return {}
    return data if isinstance(data, dict) else {}


def git_toplevel():
    try:
        return subprocess.check_output(
            ['git', 'rev-parse', '--show-toplevel'],
            text=True, stderr=subprocess.DEVNULL
        ).strip()
    except Exception:
        return ''


def provider_repo_root():
    root = git_toplevel()
    if not root:
        return ''
    marker = os.sep + '.doyaken' + os.sep + 'worktrees' + os.sep
    if marker in root:
        root = root.split(marker, 1)[0]
    return root


def provider_repo_config_path():
    root = provider_repo_root()
    if not root:
        return ''
    return os.path.join(root, '.doyaken', 'providers.json')


def provider_global_config_path():
    return os.path.expanduser('~/.doyaken/providers.json')


def provider_repo_session_key():
    root = provider_repo_root() or os.getcwd()
    name = os.path.basename(root.rstrip(os.sep)) or 'repo'
    slug = re.sub(r'[^a-z0-9._-]+', '-', name.lower()).strip('-') or 'repo'
    session_hash = 'nohash'
    try:
        completed = subprocess.run(
            ['cksum'],
            input=root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if completed.returncode == 0:
            parts = completed.stdout.split()
            if parts:
                session_hash = parts[0]
    except Exception:
        pass
    return f'repo-{slug}-{session_hash}'


def provider_scoped_session_id(raw_id):
    return f'{provider_repo_session_key()}-{raw_id}'


def provider_profile_engine(path, profile, repo_scoped=False):
    if profile in PROVIDER_BUILTIN_ENGINES:
        return PROVIDER_BUILTIN_ENGINES[profile]
    data = read_provider_config(path)
    profiles = data.get('profiles', {})
    if not isinstance(profiles, dict):
        return ''
    profile_data = profiles.get(profile, {})
    if not isinstance(profile_data, dict):
        return ''
    engine = profile_data.get('engine', '')
    if engine not in PROVIDER_ENGINES:
        return ''
    if repo_scoped and engine == 'anthropic-gateway' and os.environ.get('DK_ALLOW_REPO_GATEWAY_PROVIDER', '') != '1':
        return ''
    return engine


def provider_default_engine(path, repo_scoped=False):
    data = read_provider_config(path)
    default_profile = data.get('default', '')
    if not isinstance(default_profile, str) or not default_profile:
        return ''
    return provider_profile_engine(path, default_profile, repo_scoped=repo_scoped)


def provider_session_id():
    session_id = os.environ.get('DOYAKEN_SESSION_ID', '')
    if session_id:
        return session_id
    root = git_toplevel()
    if root:
        marker = os.sep + '.doyaken' + os.sep + 'worktrees' + os.sep
        if marker in root:
            return provider_scoped_session_id(f"worktree-{os.path.basename(root)}")
    try:
        branch = subprocess.check_output(
            ['git', 'rev-parse', '--abbrev-ref', 'HEAD'],
            text=True, stderr=subprocess.DEVNULL
        ).strip()
    except Exception:
        branch = ''
    return provider_scoped_session_id(branch.replace('/', '-')) if branch else ''


def provider_session_engine():
    explicit_session_id = os.environ.get('DOYAKEN_SESSION_ID', '')
    session_id = provider_session_id()
    if not session_id:
        return ''
    loop_dir = os.environ.get('DK_LOOP_DIR') or os.path.expanduser('~/.claude/.doyaken-loops')
    state_file = os.path.join(loop_dir, f'{session_id}.provider')
    engine = ''
    state_session = ''
    try:
        with open(state_file, 'r', encoding='utf-8') as f:
            for line in f:
                value = line.strip()
                if value.startswith('engine='):
                    engine = value.split('=', 1)[1].strip()
                    continue
                if value.startswith('session='):
                    state_session = value.split('=', 1)[1].strip()
                    continue
                if not engine and '=' not in value:
                    engine = value
    except Exception:
        return ''
    if engine not in PROVIDER_ENGINES:
        return ''
    if explicit_session_id and state_session and state_session != explicit_session_id:
        return ''
    if not explicit_session_id and os.environ.get('DK_PROVIDER_ENGINE', ''):
        return ''
    return engine


def resolved_provider_engine():
    session_engine = provider_session_engine()
    if session_engine:
        return session_engine

    repo_config = provider_repo_config_path()
    global_config = provider_global_config_path()
    explicit_profile = os.environ.get('DK_PROVIDER_PROFILE', '')
    if explicit_profile:
        if explicit_profile in PROVIDER_BUILTIN_ENGINES:
            return PROVIDER_BUILTIN_ENGINES[explicit_profile]
        # Mirror dk_provider_apply: explicit custom profiles prefer global user
        # config, then repo-local config.
        global_engine = provider_profile_engine(global_config, explicit_profile)
        if global_engine:
            return global_engine
        repo_engine = provider_profile_engine(repo_config, explicit_profile, repo_scoped=True)
        if repo_engine:
            return repo_engine

    repo_default = provider_default_engine(repo_config, repo_scoped=True)
    if repo_default:
        return repo_default
    global_default = provider_default_engine(global_config)
    if global_default:
        return global_default
    return PROVIDER_BUILTIN_ENGINES['claude-subscription']


def resolved_guard_environment_value(env_var):
    if env_var == 'DK_PROVIDER_ENGINE':
        return resolved_provider_engine()
    return ''


def guard_environment_matches(guard):
    """Return whether optional env_var/env_value frontmatter matches.

    Guards without env_var always match. Guards with env_var and no env_value
    require the environment variable to be set to a non-empty value. Guards with
    both env_var and env_value require an exact string match.
    """
    env_var = guard.get('env_var')
    if not env_var:
        return True

    env_name = str(env_var)
    if env_name == 'DK_PROVIDER_ENGINE':
        actual = provider_session_engine() or os.environ.get(env_name, '') or resolved_guard_environment_value(env_name)
    else:
        actual = os.environ.get(env_name, '') or resolved_guard_environment_value(env_name)
    expected = guard.get('env_value')
    if expected is None or expected == '':
        return bool(actual)
    return actual == str(expected)


def shell_tokens(text):
    """Tokenize a shell fragment enough for command-position guard checks."""
    text = '\n'.join(line for line in text.splitlines() if not line.lstrip().startswith('#'))
    text = text.replace('\n', ' ; ')
    lexer = shlex.shlex(text, posix=True, punctuation_chars=';&|()<>')
    lexer.whitespace_split = True
    try:
        return normalize_shell_tokens(list(lexer))
    except ValueError:
        # Unbalanced quotes: fall back to whitespace splitting rather than
        # failing open for guards that can still match obvious raw commands.
        return normalize_shell_tokens(
            text.replace(';', ' ; ')
            .replace('|', ' | ')
            .replace('&', ' & ')
            .replace('<', ' < ')
            .replace('>', ' > ')
            .split()
        )


def normalize_shell_tokens(tokens):
    normalized = []
    punct = set(';&|(){}<>')
    multi = {'&&', '||', ';;', ';&', ';;&', '<<', '<<<', '>>', '<>', '<(', '>('}
    for token in tokens:
        if len(token) > 1 and set(token) <= punct and token not in multi:
            normalized.extend(token)
        else:
            normalized.append(token)
    return normalized


def extract_executable_backticks(text):
    """Return backtick command-substitution bodies outside single quotes."""
    fragments = []
    in_single = False
    in_double = False
    escaped = False
    index = 0
    while index < len(text):
        char = text[index]
        if escaped:
            escaped = False
            index += 1
            continue
        if char == '\\':
            escaped = True
            index += 1
            continue
        if char == "'" and not in_double:
            in_single = not in_single
            index += 1
            continue
        if char == '"' and not in_single:
            in_double = not in_double
            index += 1
            continue
        if char == '`' and not in_single:
            start = index + 1
            index = start
            escaped_inner = False
            while index < len(text):
                inner = text[index]
                if escaped_inner:
                    escaped_inner = False
                elif inner == '\\':
                    escaped_inner = True
                elif inner == '`':
                    fragments.append(text[start:index])
                    break
                index += 1
        index += 1
    return fragments


def extract_dollar_substitutions(text):
    """Return $(...) command-substitution bodies outside single quotes."""
    fragments = []
    in_single = False
    in_double = False
    escaped = False
    index = 0
    while index < len(text):
        char = text[index]
        if escaped:
            escaped = False
            index += 1
            continue
        if char == '\\':
            escaped = True
            index += 1
            continue
        if char == "'" and not in_double:
            in_single = not in_single
            index += 1
            continue
        if char == '"' and not in_single:
            in_double = not in_double
            index += 1
            continue
        if char == '$' and not in_single and index + 1 < len(text) and text[index + 1] == '(':
            start = index + 2
            index = start
            depth = 1
            inner_single = False
            inner_double = False
            inner_escaped = False
            while index < len(text):
                inner = text[index]
                if inner_escaped:
                    inner_escaped = False
                elif inner == '\\':
                    inner_escaped = True
                elif inner == "'" and not inner_double:
                    inner_single = not inner_single
                elif inner == '"' and not inner_single:
                    inner_double = not inner_double
                elif inner == '(' and not inner_single and not inner_double:
                    depth += 1
                elif inner == ')' and not inner_single and not inner_double:
                    depth -= 1
                    if depth == 0:
                        fragments.append(text[start:index])
                        break
                index += 1
        index += 1
    return fragments


HEREDOC_RE = re.compile(r"<<-?\s*('([^']+)'|\"([^\"]+)\"|\\?([A-Za-z_][A-Za-z0-9_]*))")


def strip_heredoc_bodies(text):
    """Remove heredoc bodies from shell text.

    Heredoc body lines are not command lines. For unquoted delimiters, shell
    command substitutions in the body still execute. If the heredoc receiver is
    a shell/eval command, the whole body is executable shell input too.
    """
    output = []
    substitutions = []
    executable_bodies = []
    pending = []

    for raw_line in text.splitlines(keepends=True):
        line_no_newline = raw_line.rstrip('\r\n')
        if pending:
            current = pending[0]
            delimiter, strip_tabs, quoted = current['delimiter'], current['strip_tabs'], current['quoted']
            comparable = line_no_newline.lstrip('\t') if strip_tabs else line_no_newline
            if comparable == delimiter:
                if current['receiver_shell']:
                    executable_bodies.append(''.join(current['body']))
                pending.pop(0)
                continue
            current['body'].append(raw_line)
            if not quoted:
                substitutions.extend(extract_executable_backticks(raw_line))
                substitutions.extend(extract_dollar_substitutions(raw_line))
            continue

        output.append(raw_line)
        receiver_shell = heredoc_receiver_is_shell(raw_line)
        for match in HEREDOC_RE.finditer(raw_line):
            operator = match.group(0)
            delimiter = match.group(2) or match.group(3) or match.group(4) or ''
            if not delimiter:
                continue
            strip_tabs = operator.startswith('<<-')
            quoted = bool(match.group(2) or match.group(3))
            pending.append({
                'delimiter': delimiter,
                'strip_tabs': strip_tabs,
                'quoted': quoted,
                'receiver_shell': receiver_shell,
                'body': [],
            })

    for current in pending:
        if current['receiver_shell']:
            executable_bodies.append(''.join(current['body']))

    return ''.join(output), substitutions, executable_bodies


def token_basename(token):
    cleaned = token.strip('`"\'')
    return os.path.basename(cleaned)


def codex_package_basename(token):
    """Normalize package runner specs such as codex@latest and @openai/codex@1."""
    base = token_basename(token)
    if '/' in base:
        base = base.rsplit('/', 1)[-1]
    if '@' in base and not base.startswith('@'):
        base = base.split('@', 1)[0]
    return base


def is_codex_package_token(token):
    return codex_package_basename(token) == 'codex'


def doyaken_root():
    return os.environ.get('DOYAKEN_DIR') or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def apply_literal_variables(value, variables=None):
    if not variables:
        return value
    for name, replacement in variables.items():
        escaped = re.escape(name)
        value = re.sub(r'\$\{' + escaped + r'\}', lambda _match: replacement, value)
        value = re.sub(r'\$\{' + escaped + r':-[^}]*\}', lambda _match: replacement, value)
        value = re.sub(r'\$' + escaped + r'(?=\W|$)', lambda _match: replacement, value)
    return value


def resolve_shell_path(path, variables=None, cwd=None):
    root = doyaken_root()
    path = apply_literal_variables(path, variables)
    path = re.sub(r'\$\{DOYAKEN_DIR:-[^}]*\}', root, path)
    path = path.replace('${DOYAKEN_DIR}', root).replace('$DOYAKEN_DIR', root)
    path = os.path.expanduser(os.path.expandvars(path))
    if '$' in path or '`' in path:
        return ''
    if os.path.isabs(path):
        return os.path.abspath(path)
    return os.path.abspath(os.path.join(cwd or os.getcwd(), path))


def is_doyaken_codex_wrapper(path, variables=None, cwd=None):
    resolved = resolve_shell_path(path, variables, cwd)
    if not resolved:
        return False
    expected = os.path.abspath(os.path.join(doyaken_root(), 'bin', 'dkcodex.sh'))
    return os.path.realpath(resolved) == os.path.realpath(expected)


def read_shell_file(path, variables=None, cwd=None):
    resolved = resolve_shell_path(path, variables, cwd)
    if not resolved or is_doyaken_codex_wrapper(path, variables, cwd):
        return ''
    try:
        with open(resolved, 'r', encoding='utf-8', errors='replace') as f:
            body = f.read(1024 * 1024)
            return '' if '\x00' in body else body
    except OSError:
        return ''


def shell_file_body_status(path, variables=None, cwd=None):
    if is_doyaken_codex_wrapper(path, variables, cwd):
        return '', 'wrapper'
    resolved = resolve_shell_path(path, variables, cwd)
    if not resolved:
        return '', 'unresolved'
    try:
        with open(resolved, 'r', encoding='utf-8', errors='replace') as f:
            body = f.read(1024 * 1024)
            if '\x00' in body:
                return '', 'binary'
            return body, 'readable'
    except OSError:
        return '', 'unreadable'


def downstream_pipeline_has_shell(tokens, pipe_index):
    index = pipe_index
    command_position = False
    while index < len(tokens):
        token = tokens[index]
        if token == '|':
            command_position = True
            index += 1
            continue
        if token in SHELL_SEPARATORS:
            return False
        if command_position:
            command_index = skip_wrapper_prefix(tokens, index)
            if command_index < len(tokens) and token_basename(tokens[command_index]) in SHELLS.union(EVAL_COMMANDS):
                return True
            while index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
                index += 1
            command_position = False
            continue
        index += 1
    return False


def heredoc_receiver_is_shell(line):
    tokens = shell_tokens(line)
    command_position = True
    index = 0
    while index < len(tokens):
        token = tokens[index]
        base = token_basename(token)
        if token in SHELL_SEPARATORS:
            command_position = True
            index += 1
            continue
        if base in SHELL_COMMAND_KEYWORDS:
            command_position = True
            index += 1
            continue
        if base in SHELL_END_KEYWORDS or base in {'for', 'select', 'case', 'in'}:
            command_position = False
            index += 1
            continue
        if command_position:
            command_index = skip_wrapper_prefix(tokens, index)
            segment_end = command_index
            while segment_end < len(tokens) and tokens[segment_end] not in SHELL_SEPARATORS:
                segment_end += 1
            has_heredoc = '<<' in tokens[command_index:segment_end]
            if has_heredoc and command_index < len(tokens):
                if token_basename(tokens[command_index]) in SHELLS.union(EVAL_COMMANDS):
                    return True
                if segment_end < len(tokens) and tokens[segment_end] == '|' and downstream_pipeline_has_shell(tokens, segment_end):
                    return True
            index = segment_end
            command_position = False
            continue
        command_position = False
        index += 1
    return False


def is_shell_assignment(token):
    return re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', token) is not None


def assignment_parts(token):
    match = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)=(.*)$', token)
    if not match:
        return None, None
    return match.group(1), match.group(2)


def assignment_end(tokens, index):
    if index >= len(tokens) or not is_shell_assignment(tokens[index]):
        return index
    value = assignment_parts(tokens[index])[1] or ''
    if '$(' in value:
        depth = value.count('$(') + value.count('(') - value.count(')')
        cursor = index + 1
        while cursor < len(tokens) and depth > 0:
            depth += tokens[cursor].count('(')
            depth -= tokens[cursor].count(')')
            cursor += 1
        return cursor
    if '`' in value and value.count('`') % 2 == 1:
        cursor = index + 1
        while cursor < len(tokens):
            if '`' in tokens[cursor]:
                return cursor + 1
            cursor += 1
        return cursor
    return index + 1


def collect_literal_variables(tokens):
    variables = {}
    command_position = True
    index = 0
    while index < len(tokens):
        token = tokens[index]
        base = token_basename(token)
        if token in SHELL_SEPARATORS:
            command_position = True
            index += 1
            continue
        if base in SHELL_COMMAND_KEYWORDS:
            command_position = True
            index += 1
            continue
        if base in SHELL_END_KEYWORDS or base in {'for', 'select', 'case', 'in'}:
            command_position = False
            index += 1
            continue
        if command_position and is_shell_assignment(token):
            name, value = assignment_parts(token)
            if name and value and value != '$' and '$(' not in value and '`' not in value:
                variables[name] = value
            index += 1
            continue
        command_position = False
        index += 1
    return variables


def variable_name_at(tokens, index):
    if index >= len(tokens):
        return None, index
    token = tokens[index]
    if token.startswith('$') and len(token) > 1:
        if token.startswith('${') and token.endswith('}'):
            return token[2:-1], index + 1
        return token[1:], index + 1
    if token == '$' and index + 3 < len(tokens) and tokens[index + 1] == '{' and tokens[index + 3] == '}':
        return tokens[index + 2], index + 4
    return None, index


def command_token_has_embedded_substitution(tokens, index):
    if index >= len(tokens):
        return False
    token = tokens[index]
    if '$(' in token or '`' in token:
        return True
    return (
        token == '$'
        and index + 2 < len(tokens)
        and tokens[index + 1] == '('
        and tokens[index + 2] not in SHELL_SEPARATORS
    )


SHELL_SEPARATORS = {';', ';;', ';&', ';;&', '&', '&&', '|', '||', '(', ')', '{', '}', '{}'}
SHELL_REDIRECTS = {'<', '<<', '<<<', '>', '>>', '<>'}
SHELL_COMMAND_KEYWORDS = {'if', 'then', 'elif', 'else', 'while', 'until', 'do', '!', '{'}
SHELL_END_KEYWORDS = {'fi', 'done', 'esac', '}'}

SHELLS = {'bash', 'sh', 'zsh', 'dash', 'ksh'}
WRAPPER_COMMANDS = {'command', 'builtin'}
EVAL_COMMANDS = {'eval'}
SOURCE_COMMANDS = {'source', '.'}
CODEX_HELPER_COMMANDS = {'dk_provider_codex', '__dk_provider_codex_raw'}
DIRECT_CODEX_RUNNERS = {'npx', 'bunx', 'uvx'}
PACKAGE_MANAGER_RUNNERS = {
    'npm': {'exec', 'x'},
    'pnpm': {'dlx', 'exec', 'x'},
    'yarn': {'dlx', 'exec'},
}
SUDO_OPTION_ARGS = {
    '-A', '-a', '-b', '-C', '-c', '-D', '-g', '-h', '-p', '-R', '-r', '-T', '-t', '-U', '-u',
    '--askpass', '--background', '--chdir', '--close-from', '--group', '--host',
    '--prompt', '--role', '--type', '--user',
}
TIME_OPTION_ARGS = {'-f', '--format', '-o', '--output'}
TIME_FLAGS = {'-p', '-l', '-a', '--append', '-v', '--verbose', '--quiet'}
ENV_OPTION_ARGS = {'-u', '--unset', '-C', '--chdir', '-S', '--split-string'}
CODEX_OPTION_ARGS = {
    '-c', '--config', '-i', '--image', '-m', '--model', '--local-provider',
    '-p', '--profile', '-s', '--sandbox', '-C', '--cd', '--add-dir',
    '-a', '--ask-for-approval', '--remote', '--remote-auth-token-env',
    '--enable', '--disable',
}
CODEX_ALLOWED_TOP_LEVEL = {
    '-h', '--help', '-V', '--version', 'help', 'plugin',
    'mcp', 'mcp-server', 'completion', 'debug', 'features',
}
CODEX_HELP_TOKENS = {'help', '-h', '--help'}
RUNNER_VALUE_OPTIONS = {
    '-c', '--call', '-p', '--package', '--cache', '--userconfig',
    '--registry', '--scope', '--workspace',
}
RUNNER_SHELL_VALUE_OPTIONS = {'-c', '--call'}
NICE_VALUE_OPTIONS = {'-n', '--adjustment'}
TIMEOUT_VALUE_OPTIONS = {'-k', '--kill-after', '-s', '--signal'}
XARGS_VALUE_OPTIONS = {
    '-a', '--arg-file', '-d', '--delimiter', '-E', '--eof', '-I', '--replace',
    '-L', '--max-lines', '-n', '--max-args', '-P', '--max-procs',
    '-s', '--max-chars',
}
XARGS_REPLACEMENT_OPTIONS = {'-I', '--replace'}
UNKNOWN_SHELL_STDIN = object()
SHELL_SCRIPT_VALUE_OPTIONS = {'--init-file', '--rcfile', '-O', '-D'}
SHELL_VARIABLE_WORD_RE = re.compile(r'^\s*(?:\$\{[A-Za-z_][A-Za-z0-9_]*\}|\$[A-Za-z_][A-Za-z0-9_]*)\s*$')
SHELL_LEADING_VARIABLE_RE = re.compile(r'^\s*(?:\$\{[A-Za-z_][A-Za-z0-9_]*\}|\$[A-Za-z_][A-Za-z0-9_]*)(?:\s|$)')
SHELL_VARIABLE_REF_RE = re.compile(r'\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))')
PYTHON_INLINE_OPTIONS = {'-c'}
PYTHON_VALUE_OPTIONS = {'-c', '-m', '-W', '-X', '--check-hash-based-pycs'}
NODE_INLINE_OPTIONS = {'-e', '--eval', '-p', '--print'}
NODE_VALUE_OPTIONS = {
    '-e', '--eval', '-p', '--print', '-r', '--require',
    '--loader', '--import', '--experimental-loader',
}
CODE_EXECUTION_RE = re.compile(
    r'\b(?:subprocess|Popen|os\.(?:system|exec\w*|spawn\w*)|'
    r'exec(?:FileSync|File|Sync)?\s*\(|exec\s*(?:["\']|%w|\bqw\b)|'
    r'spawn(?:Sync)?\s*\(|system\s*(?:\(|["\']|%w|\bqw\b)'
    r'|child_process|ProcessBuilder|Deno\.Command|Bun\.spawn'
    r')'
)
PRINTF_SPECIFIERS = set('bcdiouxXfeEgGs')


def decode_shell_backslash_escapes(value, stop_at_c=False):
    output = []
    index = 0
    while index < len(value):
        char = value[index]
        if char != '\\':
            output.append(char)
            index += 1
            continue
        index += 1
        if index >= len(value):
            output.append('\\')
            break
        escaped = value[index]
        index += 1
        if stop_at_c and escaped == 'c':
            break
        mapping = {
            'a': '\a', 'b': '\b', 'e': '\033', 'E': '\033', 'f': '\f',
            'n': '\n', 'r': '\r', 't': '\t', 'v': '\v', '\\': '\\',
            "'": "'", '"': '"', '?': '?',
        }
        if escaped in mapping:
            output.append(mapping[escaped])
            continue
        if escaped in '01234567':
            digits = [escaped]
            while index < len(value) and len(digits) < 3 and value[index] in '01234567':
                digits.append(value[index])
                index += 1
            output.append(chr(int(''.join(digits), 8)))
            continue
        if escaped == 'x':
            digits = []
            while index < len(value) and len(digits) < 2 and value[index] in '0123456789abcdefABCDEF':
                digits.append(value[index])
                index += 1
            output.append(chr(int(''.join(digits), 16)) if digits else 'x')
            continue
        if escaped in {'u', 'U'}:
            width = 4 if escaped == 'u' else 8
            digits = []
            while index < len(value) and len(digits) < width and value[index] in '0123456789abcdefABCDEF':
                digits.append(value[index])
                index += 1
            output.append(chr(int(''.join(digits), 16)) if len(digits) == width else escaped + ''.join(digits))
            continue
        output.append(escaped)
    return ''.join(output)


def decode_ansi_c_token(value):
    if value.startswith('$') and len(value) > 1 and '\\' in value[1:]:
        return decode_shell_backslash_escapes(value[1:])
    return value


def expand_executable_script(script, variables=None):
    expanded = apply_literal_variables(script, variables)
    expanded = decode_ansi_c_token(expanded)
    if SHELL_LEADING_VARIABLE_RE.match(expanded):
        return UNKNOWN_SHELL_STDIN
    return expanded


def expand_literal_output_token(token, variables=None):
    expanded = apply_literal_variables(token, variables)
    expanded = decode_ansi_c_token(expanded)
    if SHELL_VARIABLE_WORD_RE.match(expanded):
        return UNKNOWN_SHELL_STDIN
    return expanded


def expand_shell_command_token(token, variables=None):
    if '$(' in token or '`' in token:
        return UNKNOWN_SHELL_STDIN
    expanded = apply_literal_variables(token, variables)
    if SHELL_VARIABLE_REF_RE.search(expanded):
        return UNKNOWN_SHELL_STDIN
    expanded = decode_ansi_c_token(expanded)
    if re.search(r'\{[^{}\s]+\}', expanded):
        expanded = re.sub(r'\{([^{},\s]+),\}', r'\1', expanded)
        expanded = re.sub(r'\{,([^{},\s]+)\}', r'\1', expanded)
        expanded = re.sub(r'\{([^{}\s]+)\}', r'\1', expanded)
    return expanded


def interpreter_kind(command_name):
    lowered = command_name.lower()
    if lowered in {'python', 'python2', 'python3', 'pypy', 'pypy3'}:
        return 'python'
    if re.match(r'^(?:python[23]?|pypy3?)(?:\.\d+)?$', lowered):
        return 'python'
    if lowered in {'node', 'nodejs'}:
        return 'node'
    if lowered in {'ruby', 'jruby'} or re.match(r'^(?:ruby|jruby)(?:\d+(?:\.\d+)*)?$', lowered):
        return 'ruby'
    if lowered in {'perl', 'perl5'} or re.match(r'^perl\d+(?:\.\d+)*$', lowered):
        return 'perl'
    return ''


def shebang_interpreter_kind(script_body):
    first_line = script_body.splitlines()[0] if script_body else ''
    if not first_line.startswith('#!'):
        return ''
    parts = shell_tokens(first_line[2:])
    if not parts:
        return ''
    name = token_basename(parts[0])
    if name == 'env':
        index = 1
        while index < len(parts):
            token = parts[index]
            if token == '-S':
                index += 1
                continue
            if token.startswith('-') and token != '-':
                index += 1
                continue
            name = token_basename(token)
            break
    return interpreter_kind(name)


def quoted_string_fragments(text):
    fragments = []
    index = 0
    while index < len(text):
        quote = text[index]
        if quote not in {'"', "'", '`'}:
            index += 1
            continue
        triple = quote in {'"', "'"} and text[index:index + 3] == quote * 3
        start = index + (3 if triple else 1)
        cursor = start
        escaped = False
        while cursor < len(text):
            if escaped:
                escaped = False
                cursor += 1
                continue
            char = text[cursor]
            if char == '\\':
                escaped = True
                cursor += 1
                continue
            if triple:
                if text[cursor:cursor + 3] == quote * 3:
                    fragments.append(text[start:cursor])
                    cursor += 3
                    break
            elif char == quote:
                fragments.append(text[start:cursor])
                cursor += 1
                break
            cursor += 1
        index = max(cursor, index + 1)
    return fragments


def code_without_string_literals(text):
    output = []
    index = 0
    while index < len(text):
        quote = text[index]
        if quote not in {'"', "'", '`'}:
            output.append(quote)
            index += 1
            continue
        triple = quote in {'"', "'"} and text[index:index + 3] == quote * 3
        cursor = index + (3 if triple else 1)
        escaped = False
        while cursor < len(text):
            char = text[cursor]
            if escaped:
                escaped = False
                cursor += 1
                continue
            if char == '\\':
                escaped = True
                cursor += 1
                continue
            if triple and text[cursor:cursor + 3] == quote * 3:
                cursor += 3
                break
            if not triple and char == quote:
                cursor += 1
                break
            cursor += 1
        output.append(' ')
        index = cursor
    return ''.join(output)


def joined_string_fragments(text):
    fragments = []
    strings = []
    for match in re.finditer(r'''(?s)(["'])(.*?)(?<!\\)\1''', text):
        strings.append({'start': match.start(), 'end': match.end(), 'value': match.group(2)})
    index = 0
    while index < len(strings) - 1:
        values = [strings[index]['value']]
        cursor = index
        while cursor + 1 < len(strings):
            between = text[strings[cursor]['end']:strings[cursor + 1]['start']]
            if not re.fullmatch(r'\s*\+\s*', between):
                break
            values.append(strings[cursor + 1]['value'])
            cursor += 1
        if len(values) > 1:
            fragments.append(''.join(values))
            index = cursor + 1
        else:
            index += 1
    return fragments


def adjacent_string_fragments(text):
    fragments = []
    strings = []
    for match in re.finditer(r'''(?s)(["'])(.*?)(?<!\\)\1''', text):
        strings.append({'start': match.start(), 'end': match.end(), 'value': match.group(2)})
    index = 0
    while index < len(strings) - 1:
        values = [strings[index]['value']]
        cursor = index
        while cursor + 1 < len(strings):
            between = text[strings[cursor]['end']:strings[cursor + 1]['start']]
            if not re.fullmatch(r'\s+', between):
                break
            values.append(strings[cursor + 1]['value'])
            cursor += 1
        if len(values) > 1:
            fragments.append(''.join(values))
            index = cursor + 1
        else:
            index += 1
    return fragments


def word_array_fragments(text):
    fragments = []
    for match in re.finditer(r'\bq?w\s*\(([^)]*)\)|%w\s*([\[\(\{<])([^]\)}>]*)(?:[\]\)\}>])', text):
        body = match.group(1) if match.group(1) is not None else match.group(3)
        if body and body.strip():
            fragments.append(body.strip())
    return fragments


def ruby_perl_exec_fragments(text):
    fragments = []
    for match in re.finditer(r'`([^`]*)`|%x\s*([\[\(\{<])([^]\)}>]*)(?:[\]\)\}>])|\bqx\s*\(([^)]*)\)', text):
        body = match.group(1) or match.group(3) or match.group(4)
        if body and body.strip():
            fragments.append(body.strip())
    return fragments


def code_execution_fragments(code):
    code_without_strings = code_without_string_literals(code)
    exec_operator_fragments = ruby_perl_exec_fragments(code)
    if (
        not CODE_EXECUTION_RE.search(code_without_strings)
        and not re.search(r'\b(?:system|exec)\s*(?:["\']|%w|\bqw\b)', code)
        and not exec_operator_fragments
    ):
        return []
    fragments = [
        fragment for fragment in (
            quoted_string_fragments(code)
            + joined_string_fragments(code)
            + adjacent_string_fragments(code)
            + word_array_fragments(code)
            + exec_operator_fragments
        )
        if fragment.strip()
    ]
    executable_fragments = [
        fragment for fragment in fragments
        if len(fragments) == 1 or re.search(r'[\s;&|()]', fragment)
    ]
    if len(fragments) > 1:
        executable_fragments.append(' '.join(shlex.quote(fragment) for fragment in fragments))
        for start in range(1, len(fragments)):
            executable_fragments.append(' '.join(shlex.quote(fragment) for fragment in fragments[start:]))
    return executable_fragments


def code_has_raw_codex_delegation(code, kind, depth=0, cwd=None):
    if code is UNKNOWN_SHELL_STDIN:
        return True
    if depth > 24:
        return True
    if not code or not code.strip():
        return False
    for fragment in code_execution_fragments(code):
        if has_raw_codex_delegation(fragment, depth + 1, cwd):
            return True
    return False


def executable_script_has_raw_codex(script_body, depth=0, cwd=None, kind=''):
    if script_body is UNKNOWN_SHELL_STDIN:
        return True
    if not script_body:
        return False
    if has_raw_codex_delegation(script_body, depth + 1, cwd):
        return True
    script_kind = kind or shebang_interpreter_kind(script_body)
    if script_kind and code_has_raw_codex_delegation(script_body, script_kind, depth + 1, cwd):
        return True
    return False


def scan_dollar_substitution_word(text, start):
    output = ['$(']
    index = start + 2
    depth = 1
    in_single = False
    in_double = False
    escaped = False
    while index < len(text):
        char = text[index]
        if escaped:
            output.append(char)
            escaped = False
            index += 1
            continue
        if char == '\\':
            output.append(char)
            escaped = True
            index += 1
            continue
        if char == "'" and not in_double:
            output.append(char)
            in_single = not in_single
            index += 1
            continue
        if char == '"' and not in_single:
            output.append(char)
            in_double = not in_double
            index += 1
            continue
        if char == '$' and not in_single and index + 1 < len(text) and text[index + 1] == '(':
            output.append('$(')
            depth += 1
            index += 2
            continue
        if char == '(' and not in_single and not in_double:
            depth += 1
        elif char == ')' and not in_single and not in_double:
            depth -= 1
            if depth == 0:
                output.append(char)
                return ''.join(output), index + 1
        output.append(char)
        index += 1
    return ''.join(output), index


def scan_backtick_word(text, start):
    output = ['`']
    index = start + 1
    escaped = False
    while index < len(text):
        char = text[index]
        output.append(char)
        if escaped:
            escaped = False
        elif char == '\\':
            escaped = True
        elif char == '`':
            return ''.join(output), index + 1
        index += 1
    return ''.join(output), index


def shell_word_tokens(text):
    """Tokenize shell words while preserving nested substitutions in one word."""
    text = '\n'.join(line for line in text.splitlines() if not line.lstrip().startswith('#'))
    text = text.replace('\n', ' ; ')
    tokens = []
    word = []
    in_single = False
    in_double = False
    escaped = False
    index = 0
    punctuation = set(';&|()<>')
    while index < len(text):
        char = text[index]
        if escaped:
            word.append(char)
            escaped = False
            index += 1
            continue
        if char == '\\' and not in_single:
            escaped = True
            index += 1
            continue
        if char == "'" and not in_double:
            in_single = not in_single
            index += 1
            continue
        if char == '"' and not in_single:
            in_double = not in_double
            index += 1
            continue
        if char == '$' and not in_single and index + 1 < len(text) and text[index + 1] == '(':
            substitution, index = scan_dollar_substitution_word(text, index)
            word.append(substitution)
            continue
        if char == '`' and not in_single:
            substitution, index = scan_backtick_word(text, index)
            word.append(substitution)
            continue
        if not in_single and not in_double and char.isspace():
            if word:
                tokens.append(''.join(word))
                word = []
            index += 1
            continue
        if not in_single and not in_double and char in punctuation:
            if word:
                tokens.append(''.join(word))
                word = []
            start = index
            while index < len(text) and text[index] in punctuation:
                index += 1
            tokens.append(text[start:index])
            continue
        word.append(char)
        index += 1
    if word:
        tokens.append(''.join(word))
    return normalize_shell_tokens(tokens)


def token_takes_value(token, value_options):
    if token in value_options:
        return True
    if '=' in token and token.split('=', 1)[0] in value_options:
        return False
    # Short option with an attached value, e.g. -mo4-mini.
    return len(token) == 2 and token in value_options


def short_option_has_attached_value(token, options):
    return len(token) > 2 and token[:2] in options


def skip_codex_options(tokens, index):
    while index < len(tokens):
        token = tokens[index]
        if token in SHELL_SEPARATORS:
            break
        if token == '--':
            index += 1
            break
        if not token.startswith('-') or token == '-':
            break
        if token in CODEX_HELP_TOKENS or token in {'-V', '--version'}:
            break
        needs_value = token in CODEX_OPTION_ARGS or token_takes_value(token, CODEX_OPTION_ARGS)
        index += 1
        if needs_value and index < len(tokens):
            index += 1
    return index


def skip_runner_options(tokens, index):
    while index < len(tokens):
        token = tokens[index]
        if token in SHELL_SEPARATORS:
            break
        if token == '--':
            index += 1
            break
        if not token.startswith('-') or token == '-':
            break
        needs_value = token in RUNNER_VALUE_OPTIONS or token_takes_value(token, RUNNER_VALUE_OPTIONS)
        index += 1
        if needs_value and index < len(tokens):
            index += 1
    return index


def runner_codex_index(tokens, command_index):
    command_base = token_basename(tokens[command_index])
    if command_base in DIRECT_CODEX_RUNNERS:
        index = skip_runner_options(tokens, command_index + 1)
        if index < len(tokens) and is_codex_package_token(tokens[index]):
            return index
        return None

    subcommands = PACKAGE_MANAGER_RUNNERS.get(command_base)
    if not subcommands:
        return None

    index = skip_runner_options(tokens, command_index + 1)
    if index >= len(tokens) or tokens[index] in SHELL_SEPARATORS:
        return None
    if token_basename(tokens[index]) not in subcommands:
        return None

    index = skip_runner_options(tokens, index + 1)
    if index < len(tokens) and is_codex_package_token(tokens[index]):
        return index
    return None


def runner_command_end(tokens, command_index):
    index = command_index + 1
    while index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
        index += 1
    return index


def is_supported_runner_command(tokens, command_index, command_end):
    command_base = token_basename(tokens[command_index])
    if command_base in DIRECT_CODEX_RUNNERS:
        return True
    subcommands = PACKAGE_MANAGER_RUNNERS.get(command_base)
    if not subcommands:
        return False
    index = skip_runner_options(tokens, command_index + 1)
    return index < command_end and token_basename(tokens[index]) in subcommands


def runner_shell_payloads(tokens, command_index, variables=None):
    command_end = runner_command_end(tokens, command_index)
    if not is_supported_runner_command(tokens, command_index, command_end):
        return []

    payloads = []
    index = command_index + 1
    while index < command_end:
        token = tokens[index]
        if token == '--':
            break
        if token in RUNNER_SHELL_VALUE_OPTIONS:
            if index + 1 < command_end:
                payloads.append(expand_executable_script(tokens[index + 1], variables))
                index += 2
                continue
            payloads.append(UNKNOWN_SHELL_STDIN)
            index += 1
            continue
        if token.startswith('--call='):
            payloads.append(expand_executable_script(token.split('=', 1)[1], variables))
        index += 1
    return payloads


def env_split_payload(tokens, command_index, variables=None):
    if token_basename(tokens[command_index]) != 'env':
        return ''
    index = command_index + 1
    while index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
        token = tokens[index]
        if token == '--':
            index += 1
            break
        if is_shell_assignment(token):
            index += 1
            continue
        if token == '-S' or token == '--split-string':
            if index + 1 < len(tokens) and tokens[index + 1] not in SHELL_SEPARATORS:
                return expand_executable_script(tokens[index + 1], variables)
            return UNKNOWN_SHELL_STDIN
        if token.startswith('--split-string='):
            return expand_executable_script(token.split('=', 1)[1], variables)
        if token.startswith('-'):
            needs_value = token in ENV_OPTION_ARGS or token_takes_value(token, ENV_OPTION_ARGS)
            index += 1
            if needs_value and index < len(tokens):
                index += 1
            continue
        break
    return ''


def shell_quote_tokens(tokens):
    return ' '.join(shlex.quote(token) for token in tokens)


def collect_aliases(tokens, variables=None):
    aliases = {}
    command_position = True
    index = 0
    while index < len(tokens):
        token = tokens[index]
        base = token_basename(token)
        if token in SHELL_SEPARATORS:
            command_position = True
            index += 1
            continue
        if base in SHELL_COMMAND_KEYWORDS:
            command_position = True
            index += 1
            continue
        if command_position:
            command_index = skip_wrapper_prefix(tokens, index)
            if command_index < len(tokens) and token_basename(tokens[command_index]) == 'alias':
                cursor = command_index + 1
                while cursor < len(tokens) and tokens[cursor] not in SHELL_SEPARATORS:
                    name, value = assignment_parts(tokens[cursor])
                    if name and value:
                        aliases[name] = expand_executable_script(value, variables)
                    cursor += 1
                index = cursor
                command_position = False
                continue
            while index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
                index += 1
            command_position = False
            continue
        command_position = False
        index += 1
    return aliases


def shell_functions(tokens):
    functions = {}
    index = 0
    while index < len(tokens):
        name = ''
        open_index = None
        if tokens[index] == 'function' and index + 2 < len(tokens):
            name = tokens[index + 1]
            open_index = index + 2 if tokens[index + 2] == '{' else None
        elif index + 3 < len(tokens) and tokens[index + 1:index + 4] == ['(', ')', '{']:
            name = tokens[index]
            open_index = index + 3
        if name and open_index is not None:
            depth = 1
            cursor = open_index + 1
            body = []
            while cursor < len(tokens):
                if tokens[cursor] == '{':
                    depth += 1
                    body.append(tokens[cursor])
                elif tokens[cursor] == '}':
                    depth -= 1
                    if depth == 0:
                        functions[name] = body
                        index = cursor + 1
                        break
                    body.append(tokens[cursor])
                else:
                    body.append(tokens[cursor])
                cursor += 1
        index += 1
    return functions


def function_definition_end(tokens, index):
    open_index = None
    if index < len(tokens) and tokens[index] == 'function' and index + 2 < len(tokens):
        open_index = index + 2 if tokens[index + 2] == '{' else None
    elif index + 3 < len(tokens) and tokens[index + 1:index + 4] == ['(', ')', '{']:
        open_index = index + 3
    if open_index is None:
        return None
    depth = 1
    cursor = open_index + 1
    while cursor < len(tokens):
        if tokens[cursor] == '{':
            depth += 1
        elif tokens[cursor] == '}':
            depth -= 1
            if depth == 0:
                return cursor
        cursor += 1
    return None


def xargs_command_start(tokens, command_index):
    index = command_index + 1
    replacement = None
    while index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
        token = tokens[index]
        if token == '--':
            index += 1
            break
        if short_option_has_attached_value(token, {'-I'}):
            replacement = token[2:]
            index += 1
            continue
        if token.startswith('--replace='):
            replacement = token.split('=', 1)[1] or '{}'
            index += 1
            continue
        if token in XARGS_REPLACEMENT_OPTIONS:
            if index + 1 < len(tokens):
                if tokens[index + 1:index + 3] == ['{', '}']:
                    replacement = '{}'
                    index += 3
                else:
                    replacement = tokens[index + 1]
                    index += 2
            else:
                index += 1
            continue
        if short_option_has_attached_value(token, {'-a', '-d', '-E', '-L', '-n', '-P', '-s'}):
            index += 1
            continue
        if token.startswith('-'):
            needs_value = token in XARGS_VALUE_OPTIONS or token_takes_value(token, XARGS_VALUE_OPTIONS)
            index += 1
            if needs_value and index < len(tokens):
                index += 1
            continue
        break
    return index, replacement


def replace_xargs_placeholders(command_tokens, replacement, stdin_text):
    if not replacement:
        return command_tokens
    if stdin_text is UNKNOWN_SHELL_STDIN:
        return UNKNOWN_SHELL_STDIN
    value = stdin_text.strip().splitlines()[0] if stdin_text.strip() else ''
    if not value:
        return command_tokens
    replaced = []
    index = 0
    while index < len(command_tokens):
        if replacement == '{}' and command_tokens[index:index + 2] == ['{', '}']:
            replaced.extend(shell_tokens(value))
            index += 2
            continue
        token = command_tokens[index]
        if token == replacement:
            replaced.extend(shell_tokens(value))
        elif replacement in token:
            replaced.append(token.replace(replacement, value))
        else:
            replaced.append(token)
        index += 1
    return replaced


def xargs_command_is_blocked(tokens, command_index, command_start, variables=None, cwd=None, depth=0):
    if token_basename(tokens[command_index]) != 'xargs':
        return False
    command_arg_start, replacement = xargs_command_start(tokens, command_index)
    xargs_separators = SHELL_SEPARATORS - {'{', '}'}
    if command_arg_start >= len(tokens) or tokens[command_arg_start] in xargs_separators:
        return False
    command_end = command_arg_start
    while command_end < len(tokens) and tokens[command_end] not in xargs_separators:
        command_end += 1
    command_tokens = tokens[command_arg_start:command_end]
    stdin_text = None
    if replacement:
        stdin_text = shell_stdin_literal(tokens, command_index, command_start, variables, cwd)
        command_tokens = replace_xargs_placeholders(command_tokens, replacement, stdin_text)
        if command_tokens is UNKNOWN_SHELL_STDIN:
            return True
    else:
        stdin_text = shell_stdin_literal(tokens, command_index, command_start, variables, cwd)
        if stdin_text is UNKNOWN_SHELL_STDIN:
            command_base = token_basename(command_tokens[0]) if command_tokens else ''
            return command_base in {'codex'} or command_base in DIRECT_CODEX_RUNNERS or command_base in PACKAGE_MANAGER_RUNNERS
        if stdin_text:
            command_tokens.extend(shell_tokens(stdin_text))
    return has_raw_codex_delegation(shell_quote_tokens(command_tokens), depth + 1, cwd)


def find_exec_commands(tokens, command_index):
    commands = []
    index = command_index + 1
    while index < len(tokens):
        token = tokens[index]
        if token in SHELL_SEPARATORS and token != ';':
            break
        if token in {'-exec', '-execdir', '-ok', '-okdir'}:
            index += 1
            command = []
            while index < len(tokens):
                if tokens[index] in {';', '+'}:
                    break
                command.append(tokens[index])
                index += 1
            if command:
                commands.append(command)
        index += 1
    return commands


def find_exec_is_blocked(tokens, command_index, cwd=None, depth=0):
    if token_basename(tokens[command_index]) != 'find':
        return False
    for command_tokens in find_exec_commands(tokens, command_index):
        if has_raw_codex_delegation(shell_quote_tokens(command_tokens), depth + 1, cwd):
            return True
    return False


def next_non_separator(tokens, index):
    while index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
        yield tokens[index], index
        index += 1


def codex_invocation_is_blocked(tokens, codex_index):
    index = skip_codex_options(tokens, codex_index + 1)
    if index >= len(tokens) or tokens[index] in SHELL_SEPARATORS:
        return True

    if codex_index + 1 < len(tokens):
        scan_index = codex_index + 1
        while scan_index < len(tokens) and tokens[scan_index] not in SHELL_SEPARATORS:
            if tokens[scan_index] == '--':
                return True
            scan_index += 1

    subcmd = token_basename(tokens[index])
    if subcmd in CODEX_ALLOWED_TOP_LEVEL:
        return False

    if subcmd == 'login':
        end_of_options = False
        for token, _ in next_non_separator(tokens, index + 1):
            if token == '--':
                end_of_options = True
                continue
            base = token_basename(token)
            if not end_of_options and (base in CODEX_HELP_TOKENS or base == 'status'):
                return False
            if not end_of_options and token.startswith('-'):
                continue
            return True
        return True

    if subcmd in {'exec', 'e'}:
        # `codex exec --help`, `codex e -h`, `codex exec help`, and
        # `codex exec review --help` are help lookups, not delegated work.
        review_seen = False
        end_of_options = False
        for token, _ in next_non_separator(tokens, index + 1):
            if token == '--':
                end_of_options = True
                continue
            base = token_basename(token)
            if not end_of_options and base in CODEX_HELP_TOKENS:
                return False
            if not end_of_options and base == 'review':
                review_seen = True
                continue
            if not end_of_options and token.startswith('-'):
                continue
            if review_seen:
                return True
            return True
        return True

    if subcmd == 'review':
        for token, _ in next_non_separator(tokens, index + 1):
            if token == '--':
                return True
            base = token_basename(token)
            if base in CODEX_HELP_TOKENS:
                return False
            if token.startswith('-'):
                continue
            return True
        return True

    return True


def command_substitution_end(tokens, index):
    if index >= len(tokens) or tokens[index] != '$' or index + 1 >= len(tokens) or tokens[index + 1] != '(':
        return None
    depth = 1
    cursor = index + 2
    while cursor < len(tokens):
        if tokens[cursor] == '(':
            depth += 1
        elif tokens[cursor] == ')':
            depth -= 1
            if depth == 0:
                return cursor
        cursor += 1
    return None


def backtick_substitution_end(tokens, index):
    if index >= len(tokens) or not tokens[index].startswith('`'):
        return None
    cursor = index
    while cursor < len(tokens):
        if cursor == index:
            token = tokens[cursor][1:]
        else:
            token = tokens[cursor]
        if token.endswith('`'):
            return cursor
        cursor += 1
    return None


def substitution_end(tokens, index):
    dollar_end = command_substitution_end(tokens, index)
    if dollar_end is not None:
        return dollar_end
    return backtick_substitution_end(tokens, index)


def codex_lookup_fragment(tokens):
    return any(is_codex_package_token(token) for token in tokens)


def codex_assignment_name(tokens, index):
    name, value = assignment_parts(tokens[index])
    if not name:
        return None, index + 1
    if is_codex_package_token(value):
        return name, index + 1
    if 'codex' in value.lower():
        return name, index + 1
    if value == '$':
        if index + 1 >= len(tokens) or tokens[index + 1] != '(':
            return None, index + 1
        depth = 1
        cursor = index + 2
        while cursor < len(tokens):
            token = tokens[cursor]
            if token == '(':
                depth += 1
            if ')' in token:
                depth -= token.count(')')
                if depth <= 0:
                    if codex_lookup_fragment(tokens[index + 2:cursor + 1]):
                        return name, cursor + 1
                    return None, cursor + 1
            cursor += 1
        return None, index + 1
    if value.startswith('`'):
        body_tokens = [value[1:]]
        cursor = index
        while cursor < len(tokens):
            if body_tokens[-1].endswith('`'):
                body_tokens[-1] = body_tokens[-1][:-1]
                if codex_lookup_fragment(body_tokens):
                    return name, cursor + 1
                return None, cursor + 1
            cursor += 1
            if cursor < len(tokens):
                body_tokens.append(tokens[cursor])
        return None, index + 1
    if value.startswith('$(') and 'codex' in value:
        return name, index + 1
    return None, index + 1


def collect_codex_variables(tokens):
    codex_vars = set()
    command_position = True
    index = 0
    while index < len(tokens):
        token = tokens[index]
        base = token_basename(token)
        if token in SHELL_SEPARATORS:
            command_position = True
            index += 1
            continue
        if base in SHELL_COMMAND_KEYWORDS:
            command_position = True
            index += 1
            continue
        if base in SHELL_END_KEYWORDS or base in {'for', 'select', 'case', 'in'}:
            command_position = False
            index += 1
            continue
        if command_position and is_shell_assignment(token):
            var_name, next_index = codex_assignment_name(tokens, index)
            if var_name:
                codex_vars.add(var_name)
            index = next_index
            continue
        command_position = False
        index += 1
    return codex_vars


def substitution_command_is_blocked(tokens, index):
    dollar_end = command_substitution_end(tokens, index)
    if dollar_end is not None:
        body_tokens = tokens[index + 2:dollar_end]
        next_index = dollar_end + 1
    else:
        backtick_end = backtick_substitution_end(tokens, index)
        if backtick_end is None:
            return False
        body_tokens = tokens[index:backtick_end + 1]
        body_tokens[0] = body_tokens[0][1:]
        body_tokens[-1] = body_tokens[-1][:-1]
        next_index = backtick_end + 1

    if not codex_lookup_fragment(body_tokens):
        return False
    if next_index >= len(tokens) or tokens[next_index] in SHELL_SEPARATORS:
        return True
    return codex_invocation_is_blocked(['codex'] + tokens[next_index:], 0)


def command_variable_resolves_to_codex(var_name, variables=None):
    if not var_name:
        return False
    if 'codex' in var_name.lower():
        return True
    variables = variables or {}
    value = variables.get(var_name, os.environ.get(var_name, ''))
    if not value:
        return False
    expanded = decode_ansi_c_token(value)
    return is_codex_package_token(expanded) or 'codex' in expanded.lower()


def shell_script_arg(tokens, shell_index):
    index = shell_index + 1
    while index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
        token = tokens[index]
        if token == '--':
            index += 1
            continue
        if token in {'-c', '--command'}:
            return ' '.join(tokens[index + 1:]) if index + 1 < len(tokens) else ''
        if token.startswith('-') and not token.startswith('--') and 'c' in token[1:]:
            return ' '.join(tokens[index + 1:]) if index + 1 < len(tokens) else ''
        index += 1
    return ''


def shell_c_scripts(text, variables=None):
    tokens = shell_word_tokens(text)
    if variables is None:
        variables = collect_literal_variables(tokens)
    scripts = []
    command_position = True
    index = 0
    while index < len(tokens):
        token = tokens[index]
        base = token_basename(token)
        if token in SHELL_SEPARATORS:
            command_position = True
            index += 1
            continue
        if base in SHELL_COMMAND_KEYWORDS:
            command_position = True
            index += 1
            continue
        if base in SHELL_END_KEYWORDS or base in {'for', 'select', 'case', 'in'}:
            command_position = False
            index += 1
            continue
        if command_position:
            command_index = skip_wrapper_prefix(tokens, index)
            if command_index < len(tokens) and token_basename(tokens[command_index]) in SHELLS:
                script = shell_script_arg(tokens, command_index)
                if script:
                    scripts.append(expand_executable_script(script, variables))
            while index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
                index += 1
            command_position = False
            continue
        command_position = False
        index += 1
    return scripts


def shell_script_file_arg(tokens, shell_index):
    index = shell_index + 1
    while index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
        token = tokens[index]
        if token == '--':
            index += 1
            break
        if token in {'-c', '--command'}:
            return ''
        if token.startswith('-') and not token.startswith('--') and 'c' in token[1:]:
            return ''
        if token in {'-s', '--stdin', '-'}:
            return ''
        if token in SHELL_REDIRECTS:
            index += 1
            if token in {'<', '<<', '<<<'} and index < len(tokens):
                index += 1
            continue
        if token.startswith('-') and token != '-':
            needs_value = token in SHELL_SCRIPT_VALUE_OPTIONS or token_takes_value(token, SHELL_SCRIPT_VALUE_OPTIONS)
            index += 1
            if needs_value and index < len(tokens):
                index += 1
            continue
        break

    while index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
        token = tokens[index]
        if token in SHELL_REDIRECTS:
            index += 1
            if token in {'<', '<<', '<<<'} and index < len(tokens):
                index += 1
            continue
        if token == '-':
            return ''
        return token
    return ''


def source_script_file_arg(tokens, source_index):
    index = source_index + 1
    while index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
        token = tokens[index]
        if token == '--':
            index += 1
            break
        if token.startswith('-') and token != '-':
            index += 1
            continue
        break
    if index < len(tokens) and tokens[index] not in SHELL_SEPARATORS and tokens[index] != '-':
        return tokens[index]
    return ''


def process_substitution_body(tokens, start_index):
    if start_index >= len(tokens) or tokens[start_index] not in {'<(', '>('}:
        return None
    depth = 1
    cursor = start_index + 1
    body = []
    while cursor < len(tokens):
        token = tokens[cursor]
        if token in {'<(', '>('}:
            depth += 1
            body.append(token)
        elif token == '(':
            depth += 1
            body.append(token)
        elif token == ')':
            depth -= 1
            if depth == 0:
                return body
            body.append(token)
        else:
            body.append(token)
        cursor += 1
    return None


def process_substitution_index_for_command(tokens, command_index):
    index = command_index + 1
    while index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
        if tokens[index] == '<(':
            return index
        index += 1
    return None


def process_substitution_literal_output(tokens, variables=None, cwd=None):
    if not tokens:
        return ''
    command_index = skip_wrapper_prefix(tokens, 0)
    if command_index >= len(tokens):
        return ''
    return literal_shell_input_command(tokens, command_index, variables, cwd)


INLINE_DOLLAR_SUB_RE = re.compile(r'^\$\((.*)\)$', re.S)
INLINE_BACKTICK_SUB_RE = re.compile(r'^`(.*)`$', re.S)


def is_inline_command_substitution(script):
    return INLINE_DOLLAR_SUB_RE.match(script) is not None or INLINE_BACKTICK_SUB_RE.match(script) is not None


def literal_command_lookup_output(tokens, producer_index):
    producer = token_basename(tokens[producer_index])
    index = producer_index + 1

    if producer == 'which':
        while index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
            token = tokens[index]
            if token == '--':
                index += 1
                break
            if token.startswith('-') and token != '-':
                index += 1
                continue
            break
        if index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
            return shutil.which(tokens[index]) or ''
        return ''

    if producer == 'command':
        lookup_mode = False
        while index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
            token = tokens[index]
            if token == '--':
                index += 1
                break
            if token in {'-v', '-V'}:
                lookup_mode = True
                index += 1
                continue
            if token.startswith('-') and token != '-':
                index += 1
                continue
            break
        if lookup_mode and index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
            return shutil.which(tokens[index]) or tokens[index]
        return None

    if producer in {'type', 'whence'}:
        lookup_mode = producer == 'whence'
        while index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
            token = tokens[index]
            if token == '--':
                index += 1
                break
            if token in {'-p', '-P'}:
                lookup_mode = True
                index += 1
                continue
            if token.startswith('-') and token != '-':
                index += 1
                continue
            break
        if lookup_mode and index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
            return shutil.which(tokens[index]) or ''
        return None

    return None


def literal_command_substitution_body_output(body_tokens, variables=None, cwd=None):
    command_index = 0
    if body_tokens and token_basename(body_tokens[0]) == 'builtin' and len(body_tokens) > 1:
        command_index = 1
    if command_index >= len(body_tokens):
        return UNKNOWN_SHELL_STDIN
    lookup_output = literal_command_lookup_output(body_tokens, command_index)
    if lookup_output is not None:
        return lookup_output
    return literal_shell_input_command(body_tokens, command_index, variables, cwd)


def command_substitution_body_tokens(tokens, index):
    dollar_end = command_substitution_end(tokens, index)
    if dollar_end is not None:
        return tokens[index + 2:dollar_end], dollar_end

    backtick_end = backtick_substitution_end(tokens, index)
    if backtick_end is None:
        return None, None
    body_tokens = tokens[index:backtick_end + 1]
    body_tokens[0] = body_tokens[0][1:]
    body_tokens[-1] = body_tokens[-1][:-1]
    return body_tokens, backtick_end


def command_substitution_literal_command_token(tokens, index, variables=None, cwd=None):
    body_tokens, end_index = command_substitution_body_tokens(tokens, index)
    if body_tokens is None:
        return None, None
    output = literal_command_substitution_body_output(body_tokens, variables, cwd)
    if output is UNKNOWN_SHELL_STDIN:
        return UNKNOWN_SHELL_STDIN, end_index
    output_tokens = shell_tokens(output)
    if not output_tokens:
        return '', end_index
    return output_tokens[0], end_index


def command_segment_end(tokens, index):
    while index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
        index += 1
    return index


def command_substitution_resolved_invocation(tokens, index, variables=None, cwd=None):
    command_token, end_index = command_substitution_literal_command_token(tokens, index, variables, cwd)
    if end_index is None:
        return None

    segment_end = command_segment_end(tokens, end_index + 1)
    args = tokens[end_index + 1:segment_end]
    if command_token is UNKNOWN_SHELL_STDIN:
        return UNKNOWN_SHELL_STDIN, args, end_index
    if not command_token:
        return '', args, end_index
    return command_token, args, end_index


def literal_command_substitution_output(script, variables=None, cwd=None):
    body = ''
    match = INLINE_DOLLAR_SUB_RE.match(script)
    if match:
        body = match.group(1)
    else:
        match = INLINE_BACKTICK_SUB_RE.match(script)
        if match:
            body = match.group(1)
    if not body:
        return ''
    body_tokens = shell_tokens(body)
    return literal_command_substitution_body_output(body_tokens, variables, cwd)


def render_printf_once(fmt, values, arg_index):
    decoded_fmt = decode_shell_backslash_escapes(fmt)
    output = []
    conversions = 0
    index = 0
    while index < len(decoded_fmt):
        char = decoded_fmt[index]
        if char != '%':
            output.append(char)
            index += 1
            continue
        if index + 1 < len(decoded_fmt) and decoded_fmt[index + 1] == '%':
            output.append('%')
            index += 2
            continue
        spec_index = index + 1
        while spec_index < len(decoded_fmt) and decoded_fmt[spec_index] not in PRINTF_SPECIFIERS:
            spec_index += 1
        if spec_index >= len(decoded_fmt):
            output.append(decoded_fmt[index:])
            break
        spec = decoded_fmt[spec_index]
        value = values[arg_index] if arg_index < len(values) else ''
        arg_index += 1
        conversions += 1
        if spec == 'b':
            output.append(decode_shell_backslash_escapes(value, stop_at_c=True))
        elif spec == 'c':
            output.append(value[:1])
        else:
            output.append(value)
        index = spec_index + 1
    return ''.join(output), arg_index, conversions


def render_printf_output(fmt, values):
    output = []
    arg_index = 0
    first = True
    while first or arg_index < len(values):
        rendered, next_arg, conversions = render_printf_once(fmt, values, arg_index)
        output.append(rendered)
        first = False
        if conversions == 0:
            break
        if next_arg <= arg_index and arg_index >= len(values):
            break
        arg_index = next_arg
    return ''.join(output)


def normalize_generated_path(path):
    return os.path.realpath(path) if path else ''


def heredoc_write_target(line, variables=None, cwd=None):
    tokens = shell_tokens(line)
    command_index = skip_wrapper_prefix(tokens, 0) if tokens else 0
    segment_end = command_index
    while segment_end < len(tokens) and tokens[segment_end] not in SHELL_SEPARATORS:
        segment_end += 1

    index = command_index
    while index < segment_end:
        if tokens[index] in {'<<', '<<<'}:
            index += 2
            continue
        if tokens[index] in {'>', '>>'} and index + 1 < segment_end:
            return resolve_shell_path(tokens[index + 1], variables, cwd)
        index += 1
    if command_index < len(tokens) and token_basename(tokens[command_index]) == 'tee':
        index = command_index + 1
        while index < segment_end:
            token = tokens[index]
            if token == '--':
                index += 1
                break
            if token in {'<<', '<<<', '>', '>>'}:
                index += 2
                continue
            if token.startswith('-') and token != '-':
                index += 1
                continue
            break
        if index < segment_end and tokens[index] not in SHELL_SEPARATORS:
            return resolve_shell_path(tokens[index], variables, cwd)
    return ''


def heredoc_generated_scripts(text, variables=None, cwd=None):
    generated = {}
    pending = []
    for raw_line in text.splitlines(keepends=True):
        line = raw_line.rstrip('\r\n')
        if pending:
            current = pending[0]
            comparable = line.lstrip('\t') if current['strip_tabs'] else line
            if comparable == current['delimiter']:
                if current['target']:
                    generated[normalize_generated_path(current['target'])] = ''.join(current['body'])
                pending.pop(0)
                continue
            current['body'].append(raw_line)
            continue
        for match in HEREDOC_RE.finditer(raw_line):
            operator = match.group(0)
            delimiter = match.group(2) or match.group(3) or match.group(4) or ''
            if not delimiter:
                continue
            pending.append({
                'delimiter': delimiter,
                'strip_tabs': operator.startswith('<<-'),
                'target': heredoc_write_target(raw_line, variables, cwd),
                'body': [],
            })
    for current in pending:
        if current['target']:
            generated[normalize_generated_path(current['target'])] = ''.join(current['body'])
    return generated


def redirect_generated_scripts(tokens, variables=None, cwd=None):
    generated = {}
    command_position = True
    index = 0
    while index < len(tokens):
        token = tokens[index]
        base = token_basename(token)
        if token in SHELL_SEPARATORS:
            command_position = True
            index += 1
            continue
        if base in SHELL_COMMAND_KEYWORDS:
            command_position = True
            index += 1
            continue
        if command_position:
            command_index = skip_wrapper_prefix(tokens, index)
            tee_target, tee_script = tee_generated_script(tokens, command_index, index, variables, cwd)
            if tee_target and (tee_script is UNKNOWN_SHELL_STDIN or tee_script):
                generated[normalize_generated_path(tee_target)] = tee_script
            segment_end = command_index
            while segment_end < len(tokens) and tokens[segment_end] not in SHELL_SEPARATORS:
                segment_end += 1
            target = ''
            cursor = command_index
            while cursor < segment_end:
                if tokens[cursor] in {'>', '>>'} and cursor + 1 < segment_end:
                    target = resolve_shell_path(tokens[cursor + 1], variables, cwd)
                    break
                cursor += 1
            if target:
                script = literal_shell_input_command(tokens[:segment_end], command_index, variables, cwd)
                if script is UNKNOWN_SHELL_STDIN or script:
                    generated[normalize_generated_path(target)] = script
            index = segment_end
            command_position = False
            continue
        command_position = False
        index += 1
    return generated


def generated_script_for_path(generated_scripts, path, variables=None, cwd=None):
    resolved = resolve_shell_path(path, variables, cwd)
    if not resolved:
        return None
    key = normalize_generated_path(resolved)
    return generated_scripts.get(key)


def direct_script_command_is_blocked(command_token, generated_scripts, variables=None, cwd=None, depth=0):
    script_path = expand_executable_script(command_token, variables)
    if script_path is UNKNOWN_SHELL_STDIN:
        return True
    if not script_path or is_doyaken_codex_wrapper(script_path, variables, cwd):
        return False

    generated_body = generated_script_for_path(generated_scripts, script_path, variables, cwd)
    if generated_body is UNKNOWN_SHELL_STDIN:
        return True
    if generated_body is not None:
        return executable_script_has_raw_codex(generated_body, depth + 1, cwd)

    if '/' not in script_path:
        return False

    script_body, script_status = shell_file_body_status(script_path, variables, cwd)
    if script_body and executable_script_has_raw_codex(script_body, depth + 1, cwd):
        return True
    return script_status in {'unresolved', 'unreadable'}


def cd_target(tokens, command_index, cwd, variables=None):
    index = command_index + 1
    if index < len(tokens) and tokens[index] == '--':
        index += 1
    if index >= len(tokens) or tokens[index] in SHELL_SEPARATORS:
        return os.path.expanduser('~')
    if tokens[index] == '-':
        return ''
    return resolve_shell_path(tokens[index], variables, cwd)


def literal_shell_input_command(tokens, producer_index, variables=None, cwd=None):
    producer = token_basename(tokens[producer_index])
    if producer not in {'printf', 'echo', 'cat'}:
        return UNKNOWN_SHELL_STDIN
    if producer == 'cat':
        literals = []
        index = producer_index + 1
        while index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
            token = tokens[index]
            if token == '--':
                index += 1
                continue
            if token == '<<<':
                if index + 1 >= len(tokens):
                    return ''
                return expand_literal_output_token(tokens[index + 1], variables)
            if token == '<<':
                return ''
            if token in SHELL_REDIRECTS:
                return UNKNOWN_SHELL_STDIN
            if token.startswith('-') and token != '-':
                index += 1
                continue
            if token == '-':
                return UNKNOWN_SHELL_STDIN
            try:
                resolved = resolve_shell_path(token, variables, cwd)
                if not resolved:
                    return UNKNOWN_SHELL_STDIN
                with open(resolved, 'r', encoding='utf-8', errors='replace') as f:
                    literals.append(f.read(1024 * 1024))
            except OSError:
                return UNKNOWN_SHELL_STDIN
            index += 1
        return '\n'.join(literals) if literals else UNKNOWN_SHELL_STDIN

    if producer == 'printf':
        args = []
        index = producer_index + 1
        while index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
            token = tokens[index]
            if token == '--':
                index += 1
                continue
            if token in SHELL_REDIRECTS:
                break
            expanded = expand_literal_output_token(token, variables)
            if expanded is UNKNOWN_SHELL_STDIN:
                return UNKNOWN_SHELL_STDIN
            args.append(expanded)
            index += 1
        return render_printf_output(args[0], args[1:]) if args else ''

    echo_decode_escapes = False
    literals = []
    index = producer_index + 1
    while index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
        token = tokens[index]
        if token == '--':
            index += 1
            continue
        if token.startswith('-') and len(token) > 1 and set(token[1:]) <= {'e', 'E', 'n'}:
            if 'e' in token[1:]:
                echo_decode_escapes = True
            if 'E' in token[1:]:
                echo_decode_escapes = False
            index += 1
            continue
        if token in SHELL_REDIRECTS:
            break
        expanded = expand_literal_output_token(token, variables)
        if expanded is UNKNOWN_SHELL_STDIN:
            return UNKNOWN_SHELL_STDIN
        if echo_decode_escapes:
            expanded = decode_shell_backslash_escapes(expanded)
        literals.append(expanded)
        index += 1
    return ' '.join(literals)


def tee_generated_script(tokens, command_index, command_start, variables=None, cwd=None):
    if command_index >= len(tokens):
        return '', ''
    if token_basename(tokens[command_index]) != 'tee':
        return '', ''
    script = shell_stdin_literal(tokens, command_index, command_start, variables, cwd)
    target = ''
    index = command_index + 1
    while index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
        token = tokens[index]
        if token == '--':
            index += 1
            continue
        if token in {'>', '>>', '<', '<<', '<<<'}:
            index += 2 if index + 1 < len(tokens) else 1
            continue
        if token.startswith('-') and token != '-':
            index += 1
            continue
        target = resolve_shell_path(token, variables, cwd)
        break
    return target, script


def shell_stdin_literal(tokens, shell_index, command_start=None, variables=None, cwd=None):
    if command_start is None:
        command_start = shell_index
    if command_start >= 2 and tokens[command_start - 1] == '|':
        producer_end = command_start - 1
        producer_start = producer_end - 1
        while producer_start >= 0 and tokens[producer_start] not in SHELL_SEPARATORS:
            producer_start -= 1
        producer_start += 1
        if producer_start < producer_end:
            return literal_shell_input_command(tokens, producer_start, variables, cwd)

    index = shell_index + 1
    while index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
        if tokens[index] == '<<<':
            if index + 1 >= len(tokens):
                return ''
            return expand_literal_output_token(tokens[index + 1], variables)
        if tokens[index] == '<':
            if index + 1 >= len(tokens):
                return ''
            resolved = resolve_shell_path(tokens[index + 1], variables, cwd)
            if not resolved:
                return UNKNOWN_SHELL_STDIN
            try:
                with open(resolved, 'r', encoding='utf-8', errors='replace') as f:
                    return f.read(1024 * 1024)
            except OSError:
                return UNKNOWN_SHELL_STDIN
        index += 1
    return ''


def downstream_pipeline_interpreter_kind(tokens, pipe_index):
    index = pipe_index
    command_position = False
    while index < len(tokens):
        token = tokens[index]
        if token == '|':
            command_position = True
            index += 1
            continue
        if token in SHELL_SEPARATORS:
            command_position = True
            index += 1
            continue
        if command_position:
            command_index = skip_wrapper_prefix(tokens, index)
            if command_index < len(tokens):
                kind = interpreter_kind(token_basename(tokens[command_index]))
                if kind:
                    return kind
            command_position = False
        index += 1
    return ''


def heredoc_receiver_interpreter_kind(line):
    tokens = shell_tokens(line)
    command_position = True
    index = 0
    while index < len(tokens):
        token = tokens[index]
        base = token_basename(token)
        if token in SHELL_SEPARATORS:
            command_position = True
            index += 1
            continue
        if base in SHELL_COMMAND_KEYWORDS:
            command_position = True
            index += 1
            continue
        if base in SHELL_END_KEYWORDS or base in {'for', 'select', 'case', 'in'}:
            command_position = False
            index += 1
            continue
        if command_position:
            command_index = skip_wrapper_prefix(tokens, index)
            segment_end = command_index
            while segment_end < len(tokens) and tokens[segment_end] not in SHELL_SEPARATORS:
                segment_end += 1
            has_heredoc = '<<' in tokens[command_index:segment_end]
            if has_heredoc and command_index < len(tokens):
                kind = interpreter_kind(token_basename(tokens[command_index]))
                if kind:
                    return kind
                if segment_end < len(tokens) and tokens[segment_end] == '|':
                    kind = downstream_pipeline_interpreter_kind(tokens, segment_end)
                    if kind:
                        return kind
            index = segment_end
            command_position = False
            continue
        command_position = False
        index += 1
    return ''


def interpreter_heredoc_bodies(text):
    bodies = []
    pending = []
    for raw_line in text.splitlines(keepends=True):
        line = raw_line.rstrip('\r\n')
        if pending:
            current = pending[0]
            comparable = line.lstrip('\t') if current['strip_tabs'] else line
            if comparable == current['delimiter']:
                bodies.append((current['kind'], ''.join(current['body'])))
                pending.pop(0)
                continue
            current['body'].append(raw_line)
            continue
        kind = heredoc_receiver_interpreter_kind(raw_line)
        for match in HEREDOC_RE.finditer(raw_line):
            operator = match.group(0)
            delimiter = match.group(2) or match.group(3) or match.group(4) or ''
            if delimiter and kind:
                pending.append({
                    'delimiter': delimiter,
                    'strip_tabs': operator.startswith('<<-'),
                    'kind': kind,
                    'body': [],
                })
    for current in pending:
        bodies.append((current['kind'], ''.join(current['body'])))
    return bodies


def interpreter_inline_payload(kind, token, tokens, index, command_end, variables=None, cwd=None):
    if kind == 'python':
        if token == '-c':
            if index + 1 < command_end:
                return expand_executable_script(tokens[index + 1], variables), index + 2
            return UNKNOWN_SHELL_STDIN, index + 1
        return None, index

    if kind in {'node', 'ruby', 'perl'}:
        if token in {'-e', '-p', '--eval', '--print'}:
            if index + 1 < command_end:
                return expand_executable_script(tokens[index + 1], variables), index + 2
            return UNKNOWN_SHELL_STDIN, index + 1
        for prefix in ('--eval=', '--print='):
            if token.startswith(prefix):
                return expand_executable_script(token.split('=', 1)[1], variables), index + 1
        if len(token) > 2 and token[:2] in {'-e', '-p'}:
            return expand_executable_script(token[2:], variables), index + 1
    return None, index


def interpreter_option_takes_value(kind, token):
    value_options = PYTHON_VALUE_OPTIONS if kind == 'python' else NODE_VALUE_OPTIONS
    return token in value_options or token_takes_value(token, value_options)


def interpreter_script_body(script_file, generated_scripts, variables=None, cwd=None):
    generated_body = generated_script_for_path(generated_scripts, script_file, variables, cwd)
    if generated_body is UNKNOWN_SHELL_STDIN:
        return UNKNOWN_SHELL_STDIN
    if generated_body is not None:
        return generated_body
    script_body, script_status = shell_file_body_status(script_file, variables, cwd)
    if script_body:
        return script_body
    if script_status in {'unresolved', 'unreadable'}:
        return UNKNOWN_SHELL_STDIN
    return ''


def interpreter_code_payloads(tokens, command_index, command_start, generated_scripts, variables=None, cwd=None):
    kind = interpreter_kind(token_basename(tokens[command_index]))
    if not kind:
        return []

    command_end = command_index + 1
    while command_end < len(tokens) and tokens[command_end] not in SHELL_SEPARATORS:
        command_end += 1

    payloads = []
    index = command_index + 1
    while index < command_end:
        token = tokens[index]
        if token == '--':
            index += 1
            break
        if token in SHELL_REDIRECTS:
            index += 2 if token in {'<', '<<', '<<<'} and index + 1 < command_end else 1
            continue
        payload, next_index = interpreter_inline_payload(kind, token, tokens, index, command_end, variables, cwd)
        if payload is not None:
            payloads.append((kind, payload))
            return payloads
        if token == '-':
            if '<<' in tokens[command_index:command_end]:
                return payloads
            stdin_script = shell_stdin_literal(tokens, command_index, command_start, variables, cwd)
            payloads.append((kind, stdin_script if stdin_script else UNKNOWN_SHELL_STDIN))
            return payloads
        if kind == 'python' and token == '-m':
            return payloads
        if token.startswith('-'):
            needs_value = interpreter_option_takes_value(kind, token)
            index += 1
            if needs_value and index < command_end:
                index += 1
            continue
        payloads.append((kind, interpreter_script_body(token, generated_scripts, variables, cwd)))
        return payloads

    stdin_script = shell_stdin_literal(tokens, command_index, command_start, variables, cwd)
    if stdin_script:
        payloads.append((kind, stdin_script))
    elif stdin_script is UNKNOWN_SHELL_STDIN:
        payloads.append((kind, UNKNOWN_SHELL_STDIN))
    return payloads


def skip_wrapper_prefix(tokens, index):
    while index < len(tokens):
        while index < len(tokens) and is_shell_assignment(tokens[index]):
            index += 1
        if index >= len(tokens):
            return index

        base = token_basename(tokens[index])
        if base == 'command':
            index += 1
            while index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
                token = tokens[index]
                if token == '--':
                    index += 1
                    break
                if token.startswith('-') and len(token) > 1 and all(ch in 'pVv' for ch in token[1:]):
                    if 'v' in token[1:] or 'V' in token[1:]:
                        while index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
                            index += 1
                        return index
                    index += 1
                    continue
                break
            continue

        if base == 'builtin':
            index += 1
            if index < len(tokens) and tokens[index] == '--':
                index += 1
            continue

        if base == 'exec':
            index += 1
            while index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
                token = tokens[index]
                if token == '--':
                    index += 1
                    break
                if token in {'-a', '-c'}:
                    index += 2 if index + 1 < len(tokens) else 1
                    continue
                if token == '-l':
                    index += 1
                    continue
                break
            continue

        if base == 'env':
            if index + 1 < len(tokens) and (
                tokens[index + 1] in {'-S', '--split-string'} or tokens[index + 1].startswith('--split-string=')
            ):
                break
            index += 1
            while index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
                token = tokens[index]
                if token == '--':
                    index += 1
                    break
                if is_shell_assignment(token):
                    index += 1
                    continue
                if token.startswith('-'):
                    needs_value = token in ENV_OPTION_ARGS or token_takes_value(token, ENV_OPTION_ARGS)
                    index += 1
                    if needs_value and index < len(tokens):
                        index += 1
                    continue
                break
            continue

        if base in {'time', 'nohup'}:
            index += 1
            while index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
                token = tokens[index]
                if token == '--':
                    index += 1
                    break
                if base == 'time' and token in TIME_FLAGS:
                    index += 1
                    continue
                if base == 'time' and (token in TIME_OPTION_ARGS or token_takes_value(token, TIME_OPTION_ARGS)):
                    index += 1
                    if index < len(tokens):
                        index += 1
                    continue
                break
            continue

        if base == 'nice':
            index += 1
            while index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
                token = tokens[index]
                if token == '--':
                    index += 1
                    break
                if re.match(r'^-\d+$', token):
                    index += 1
                    continue
                if token.startswith('-'):
                    needs_value = token in NICE_VALUE_OPTIONS or token_takes_value(token, NICE_VALUE_OPTIONS)
                    index += 1
                    if needs_value and index < len(tokens):
                        index += 1
                    continue
                break
            continue

        if base in {'timeout', 'gtimeout'}:
            index += 1
            while index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
                token = tokens[index]
                if token == '--':
                    index += 1
                    break
                if token.startswith('-'):
                    needs_value = token in TIMEOUT_VALUE_OPTIONS or token_takes_value(token, TIMEOUT_VALUE_OPTIONS)
                    index += 1
                    if needs_value and index < len(tokens):
                        index += 1
                    continue
                break
            if index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
                index += 1
            continue

        if base in {'sudo', 'doas'}:
            index += 1
            while index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
                token = tokens[index]
                if is_shell_assignment(token):
                    index += 1
                    continue
                if token == '--':
                    index += 1
                    break
                if token.startswith('-'):
                    needs_value = token in SUDO_OPTION_ARGS or token_takes_value(token, SUDO_OPTION_ARGS)
                    index += 1
                    if needs_value and index < len(tokens):
                        index += 1
                    continue
                break
            continue

        break
    return index


def has_raw_codex_delegation(text, depth=0, cwd=None):
    if depth > 24:
        return True
    if not text.strip():
        return False
    if cwd is None:
        cwd = os.getcwd()

    shell_text, heredoc_substitutions, heredoc_bodies = strip_heredoc_bodies(text)
    for fragment in heredoc_substitutions:
        if has_raw_codex_delegation(fragment, depth + 1, cwd):
            return True
    for body in heredoc_bodies:
        if has_raw_codex_delegation(body, depth + 1, cwd):
            return True
    for kind, body in interpreter_heredoc_bodies(text):
        if code_has_raw_codex_delegation(body, kind, depth + 1, cwd):
            return True
    for fragment in extract_executable_backticks(shell_text):
        if has_raw_codex_delegation(fragment, depth + 1, cwd):
            return True
    for fragment in extract_dollar_substitutions(shell_text):
        if has_raw_codex_delegation(fragment, depth + 1, cwd):
            return True

    tokens = shell_tokens(shell_text)
    shell_vars = collect_literal_variables(tokens)
    codex_vars = collect_codex_variables(tokens)
    aliases = collect_aliases(tokens, shell_vars)
    functions = shell_functions(tokens)
    generated_scripts = redirect_generated_scripts(tokens, shell_vars, cwd)
    generated_scripts.update(heredoc_generated_scripts(text, shell_vars, cwd))

    for script in shell_c_scripts(shell_text, shell_vars):
        if script is UNKNOWN_SHELL_STDIN:
            return True
        if is_inline_command_substitution(script):
            script_output = literal_command_substitution_output(script, shell_vars, cwd)
            if script_output is UNKNOWN_SHELL_STDIN:
                return True
            if script_output and has_raw_codex_delegation(script_output, depth + 1, cwd):
                return True
        elif script and has_raw_codex_delegation(script, depth + 1, cwd):
            return True

    command_position = True
    index = 0
    while index < len(tokens):
        token = tokens[index]
        base = token_basename(token)

        if token in SHELL_SEPARATORS:
            command_position = True
            index += 1
            continue
        if base in SHELL_COMMAND_KEYWORDS:
            command_position = True
            index += 1
            continue
        if base in SHELL_END_KEYWORDS or base in {'for', 'select', 'case', 'in'}:
            command_position = False
            index += 1
            continue

        if command_position:
            if is_shell_assignment(token):
                index = assignment_end(tokens, index)
                continue
            definition_end = function_definition_end(tokens, index)
            if definition_end is not None:
                command_position = False
                index = definition_end + 1
                continue
            if substitution_command_is_blocked(tokens, index):
                return True
            direct_substitution_end = substitution_end(tokens, index)
            if direct_substitution_end is not None:
                resolved_invocation = command_substitution_resolved_invocation(tokens, index, shell_vars, cwd)
                if resolved_invocation is not None:
                    resolved_command, resolved_args, _ = resolved_invocation
                    if resolved_command is UNKNOWN_SHELL_STDIN:
                        if codex_lookup_fragment(resolved_args):
                            return True
                    if resolved_command:
                        resolved_text = shell_quote_tokens([resolved_command] + resolved_args)
                        if has_raw_codex_delegation(resolved_text, depth + 1, cwd):
                            return True
                command_position = False
                index = direct_substitution_end + 1
                continue
            if command_token_has_embedded_substitution(tokens, index):
                return True
            var_name, var_end = variable_name_at(tokens, index)
            if var_name in codex_vars:
                return codex_invocation_is_blocked(['codex'] + tokens[var_end:], 0)
            if var_name:
                if command_variable_resolves_to_codex(var_name, shell_vars):
                    return codex_invocation_is_blocked(['codex'] + tokens[var_end:], 0)
                command_position = False
                index = var_end
                continue

            command_index = skip_wrapper_prefix(tokens, index)
            if command_index >= len(tokens):
                return False
            if substitution_command_is_blocked(tokens, command_index):
                return True
            wrapped_substitution_end = substitution_end(tokens, command_index)
            if wrapped_substitution_end is not None:
                resolved_invocation = command_substitution_resolved_invocation(tokens, command_index, shell_vars, cwd)
                if resolved_invocation is not None:
                    resolved_command, resolved_args, _ = resolved_invocation
                    if resolved_command is UNKNOWN_SHELL_STDIN:
                        if codex_lookup_fragment(resolved_args):
                            return True
                    if resolved_command:
                        resolved_text = shell_quote_tokens(tokens[index:command_index] + [resolved_command] + resolved_args)
                        if has_raw_codex_delegation(resolved_text, depth + 1, cwd):
                            return True
                command_position = False
                index = wrapped_substitution_end + 1
                continue
            if command_token_has_embedded_substitution(tokens, command_index):
                return True
            var_name, var_end = variable_name_at(tokens, command_index)
            if var_name in codex_vars:
                return codex_invocation_is_blocked(['codex'] + tokens[var_end:], 0)
            if var_name:
                if command_variable_resolves_to_codex(var_name, shell_vars):
                    return codex_invocation_is_blocked(['codex'] + tokens[var_end:], 0)
                command_position = False
                index = var_end
                continue
            command_token = expand_shell_command_token(tokens[command_index], shell_vars)
            if command_token is UNKNOWN_SHELL_STDIN:
                return True
            raw_command = command_token.strip('`"\'')
            command_base = '.' if raw_command == '.' else token_basename(command_token)

            if command_base in aliases:
                alias_body = aliases[command_base]
                if alias_body is UNKNOWN_SHELL_STDIN:
                    return True
                alias_command = f"{alias_body} {shell_quote_tokens(tokens[command_index + 1:])}"
                if has_raw_codex_delegation(alias_command, depth + 1, cwd):
                    return True

            if command_base in functions:
                function_body = shell_quote_tokens(functions[command_base] + tokens[command_index + 1:])
                if has_raw_codex_delegation(function_body, depth + 1, cwd):
                    return True

            if command_base == 'codex' and codex_invocation_is_blocked(['codex'] + tokens[command_index + 1:], 0):
                return True

            if command_base in CODEX_HELPER_COMMANDS and codex_invocation_is_blocked(['codex'] + tokens[command_index + 1:], 0):
                return True

            if command_base in SHELLS:
                script = shell_script_arg(tokens, command_index)
                if script:
                    script = expand_executable_script(script, shell_vars)
                    if script is UNKNOWN_SHELL_STDIN:
                        return True
                    if is_inline_command_substitution(script):
                        script_output = literal_command_substitution_output(script, shell_vars, cwd)
                        if script_output is UNKNOWN_SHELL_STDIN:
                            return True
                        if script_output and has_raw_codex_delegation(script_output, depth + 1, cwd):
                            return True
                    elif has_raw_codex_delegation(script, depth + 1, cwd):
                        return True
                process_index = process_substitution_index_for_command(tokens, command_index)
                if process_index is not None:
                    process_body = process_substitution_body(tokens, process_index)
                    if process_body is None:
                        return True
                    process_text = ' '.join(process_body)
                    if process_text and has_raw_codex_delegation(process_text, depth + 1, cwd):
                        return True
                    process_output = process_substitution_literal_output(process_body, shell_vars, cwd)
                    if process_output is UNKNOWN_SHELL_STDIN:
                        return True
                    if process_output and has_raw_codex_delegation(process_output, depth + 1, cwd):
                        return True
                script_file = shell_script_file_arg(tokens, command_index) if process_index is None else ''
                if script_file:
                    generated_body = generated_script_for_path(generated_scripts, script_file, shell_vars, cwd)
                    if generated_body is UNKNOWN_SHELL_STDIN:
                        return True
                    if generated_body is not None and has_raw_codex_delegation(generated_body, depth + 1, cwd):
                        return True
                    script_body, script_status = shell_file_body_status(script_file, shell_vars, cwd)
                    if script_body and has_raw_codex_delegation(script_body, depth + 1, cwd):
                        return True
                    if generated_body is None and script_status in {'unresolved', 'unreadable'}:
                        return True
                stdin_script = shell_stdin_literal(tokens, command_index, index, shell_vars, cwd)
                if stdin_script is UNKNOWN_SHELL_STDIN:
                    return True
                if stdin_script and has_raw_codex_delegation(stdin_script, depth + 1, cwd):
                    return True

            if command_base in SOURCE_COMMANDS:
                process_index = process_substitution_index_for_command(tokens, command_index)
                if process_index is not None:
                    process_body = process_substitution_body(tokens, process_index)
                    if process_body is None:
                        return True
                    process_text = ' '.join(process_body)
                    if process_text and has_raw_codex_delegation(process_text, depth + 1, cwd):
                        return True
                    process_output = process_substitution_literal_output(process_body, shell_vars, cwd)
                    if process_output is UNKNOWN_SHELL_STDIN:
                        return True
                    if process_output and has_raw_codex_delegation(process_output, depth + 1, cwd):
                        return True
                script_file = source_script_file_arg(tokens, command_index) if process_index is None else ''
                if script_file:
                    generated_body = generated_script_for_path(generated_scripts, script_file, shell_vars, cwd)
                    if generated_body is UNKNOWN_SHELL_STDIN:
                        return True
                    if generated_body is not None and has_raw_codex_delegation(generated_body, depth + 1, cwd):
                        return True
                    script_body, script_status = shell_file_body_status(script_file, shell_vars, cwd)
                    if script_body and has_raw_codex_delegation(script_body, depth + 1, cwd):
                        return True
                    if generated_body is None and script_status in {'unresolved', 'unreadable'}:
                        return True

            if command_base in EVAL_COMMANDS:
                script = expand_executable_script(' '.join(tokens[command_index + 1:]), shell_vars)
                if script is UNKNOWN_SHELL_STDIN:
                    return True
                if script and has_raw_codex_delegation(script, depth + 1, cwd):
                    return True

            env_payload = env_split_payload(tokens, command_index, shell_vars)
            if env_payload is UNKNOWN_SHELL_STDIN:
                return True
            if env_payload and has_raw_codex_delegation(env_payload, depth + 1, cwd):
                return True

            for kind, script in interpreter_code_payloads(tokens, command_index, index, generated_scripts, shell_vars, cwd):
                if script is UNKNOWN_SHELL_STDIN:
                    return True
                if code_has_raw_codex_delegation(script, kind, depth + 1, cwd):
                    return True

            if xargs_command_is_blocked(tokens, command_index, index, shell_vars, cwd, depth):
                return True

            if find_exec_is_blocked(tokens, command_index, cwd, depth):
                return True

            if direct_script_command_is_blocked(command_token, generated_scripts, shell_vars, cwd, depth):
                return True

            if command_base == 'cd':
                target = cd_target(tokens, command_index, cwd, shell_vars)
                if target and os.path.isdir(target):
                    cwd = target

            for runner_script in runner_shell_payloads(tokens, command_index, shell_vars):
                if runner_script is UNKNOWN_SHELL_STDIN:
                    return True
                if is_inline_command_substitution(runner_script):
                    script_output = literal_command_substitution_output(runner_script, shell_vars, cwd)
                    if script_output is UNKNOWN_SHELL_STDIN:
                        return True
                    if script_output and has_raw_codex_delegation(script_output, depth + 1, cwd):
                        return True
                elif runner_script and has_raw_codex_delegation(runner_script, depth + 1, cwd):
                    return True

            runner_index = runner_codex_index(tokens, command_index)
            if runner_index is not None and codex_invocation_is_blocked(tokens, runner_index):
                return True

        command_position = False
        index += 1

    return False


def guard_detector_matches(guard, text):
    detector = guard.get('detector', '')
    if not detector:
        return None
    if detector == 'raw-codex-delegation':
        return has_raw_codex_delegation(text)
    print(f"[guard:{guard.get('name', 'unnamed')}] skipped — unknown detector: {detector}", file=sys.stderr)
    return False


def check_guards(guards, text):
    """Check text against all guards. Returns (warnings, blocks).

    Each guard's regex pattern is matched against the full text. Matching is
    case-insensitive by default; set case_sensitive: true in frontmatter for
    exact-case matching. If allow_pattern is present, it is checked against each
    individual match so one allowed command does not hide a separate blocked one.
    """
    warnings = []
    blocks = []

    for guard in guards:
        pattern = guard.get('pattern', '')
        allow_pattern = guard.get('allow_pattern', '')
        name = guard.get('name', 'unnamed')
        if not guard_environment_matches(guard):
            continue

        detector_match = guard_detector_matches(guard, text)
        if detector_match is not None:
            if not detector_match:
                continue
            entry = {
                'name': name,
                'message': guard.get('message', 'Guard triggered.'),
                'action': guard.get('action', 'warn'),
            }
            if entry['action'] == 'block':
                blocks.append(entry)
            else:
                warnings.append(entry)
            continue

        if not pattern:
            print(f"[guard:{name}] skipped — no pattern defined", file=sys.stderr)
            continue

        try:
            flags = re.MULTILINE
            # Default: case-insensitive matching. Set `case_sensitive: true`
            # in frontmatter to require exact case. See docs/guards.md.
            if not guard.get('case_sensitive'):
                flags |= re.IGNORECASE
            compiled = re.compile(pattern, flags)
        except re.error as e:
            print(f"[guard:{name}] skipped — invalid regex: {e}", file=sys.stderr)
            continue

        allow_compiled = None
        if allow_pattern:
            try:
                allow_compiled = re.compile(allow_pattern, flags)
            except re.error as e:
                print(f"[guard:{name}] invalid allow_pattern regex: {e}", file=sys.stderr)
                allow_compiled = None

        # ReDoS protection: guard patterns come from .md files which could be
        # contributed by anyone in a repo. A 2-second alarm prevents pathological
        # backtracking from hanging the hook. When the alarm fires, the signal
        # handler raises TimeoutError in the main thread, interrupting re.search.
        # signal.alarm is Unix-only; Doyaken targets macOS/Linux exclusively.
        # See: https://docs.python.org/3/library/signal.html#signal.alarm
        _prev_handler = signal.signal(signal.SIGALRM, _timeout_handler)
        signal.alarm(2)
        try:
            matched = None
            for candidate in compiled.finditer(text):
                if allow_compiled and allow_compiled.search(candidate.group(0)):
                    continue
                matched = candidate
                break
        except TimeoutError:
            print(f"[guard:{name}] skipped — regex timed out (possible ReDoS)", file=sys.stderr)
            continue
        finally:
            signal.alarm(0)
            signal.signal(signal.SIGALRM, _prev_handler)

        if not matched:
            continue

        entry = {
            'name': name,
            'message': guard.get('message', 'Guard triggered.'),
            'action': guard.get('action', 'warn'),
        }

        if entry['action'] == 'block':
            blocks.append(entry)
        else:
            warnings.append(entry)

    return warnings, blocks


def extract_hook_text(raw_input, event_type):
    """Extract guard-checkable text from Claude hook JSON.

    Claude Code sends hook payloads as JSON on stdin. The legacy
    CLAUDE_TOOL_USE_INPUT path passes plain text for manual tests and older
    wrappers, so non-JSON input is returned as-is.
    """
    if not raw_input.strip():
        return ''

    try:
        payload = json.loads(raw_input)
    except json.JSONDecodeError:
        return raw_input

    if not isinstance(payload, dict):
        return raw_input

    tool_input = payload.get('tool_input', {})
    if not isinstance(tool_input, dict):
        return raw_input

    if event_type == 'bash':
        command = tool_input.get('command', '')
        if isinstance(command, str):
            return command
        return raw_input

    if event_type == 'file':
        parts = []
        for key in ('file_path', 'notebook_path', 'content', 'old_string', 'new_string', 'new_source'):
            value = tool_input.get(key)
            if isinstance(value, str):
                parts.append(value)
        edits = tool_input.get('edits', [])
        if isinstance(edits, list):
            for edit in edits:
                if not isinstance(edit, dict):
                    continue
                for key in ('old_string', 'new_string'):
                    value = edit.get(key)
                    if isinstance(value, str):
                        parts.append(value)
        return '\n'.join(parts) if parts else raw_input

    return raw_input


def warning_context(warnings):
    lines = []
    for warning in warnings:
        lines.append(f"[guard:{warning['name']}] WARNING")
        lines.append(warning['message'])
    return '\n\n'.join(lines)


def hook_event_name_for_guard_event(event_type):
    if event_type == 'commit':
        return 'PostToolUse'
    if event_type in ('bash', 'file'):
        return 'PreToolUse'
    return event_type


def main():
    # Flow: read tool input from env → determine event type → load matching
    # guards from built-in (hooks/guards/) and project (.doyaken/guards/) dirs
    # → check each guard's regex against the input → print warnings/blocks
    # → exit 2 if any blocking guard triggered, 0 otherwise.
    # See: docs/guards.md for full guard system documentation.
    stdin_input = '' if sys.stdin.isatty() else sys.stdin.read()
    tool_input = stdin_input if stdin_input.strip() else os.environ.get('CLAUDE_TOOL_USE_INPUT', '')

    # Determine event type from environment
    event_type = os.environ.get('DOYAKEN_GUARD_EVENT', 'bash')

    guards = load_guards(event_type)
    if not guards:
        sys.exit(0)

    # Build text to check against. Claude Code sends hook payload JSON on stdin;
    # CLAUDE_TOOL_USE_INPUT remains only as a no-stdin/manual-test fallback.
    text = extract_hook_text(tool_input, event_type) if tool_input.strip() else ''

    # For commit events, fetch committed files and message from git if not
    # already provided (post-commit-guard.sh sets CLAUDE_TOOL_USE_INPUT)
    if event_type == 'commit' and not text.strip():
        try:
            msg = subprocess.check_output(
                ['git', 'log', '-1', '--pretty=format:%s'], text=True, stderr=subprocess.DEVNULL
            ).strip()
            files = subprocess.check_output(
                ['git', 'diff-tree', '--no-commit-id', '--name-only', '-r', 'HEAD'],
                text=True, stderr=subprocess.DEVNULL
            ).strip()
            text = f"{files}\n{msg}"
        except Exception:
            pass

    warnings, blocks = check_guards(guards, text)

    # Print blocks
    for b in blocks:
        print(f"\n[guard:{b['name']}] BLOCKED", file=sys.stderr)
        print(b['message'], file=sys.stderr)

    # Exit 2 to block if any blocking guards triggered
    if blocks:
        sys.exit(2)

    if warnings:
        context = warning_context(warnings)
        print(json.dumps({
            "continue": True,
            "systemMessage": context,
            "hookSpecificOutput": {
                "hookEventName": hook_event_name_for_guard_event(event_type),
                "additionalContext": context,
            },
        }))

    sys.exit(0)


if __name__ == '__main__':
    main()
