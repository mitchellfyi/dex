#!/usr/bin/env python3
"""
Dex Guard Handler — evaluates markdown-based guard rules.

Reads Claude Code hook payload JSON from stdin. Also supports
CLAUDE_TOOL_USE_INPUT as a plain-text/manual-test fallback.

Reads guard files from:
  1. $DEX_DIR/hooks/guards/*.md  (built-in guards)
  2. .dex/guards/*.md            (project-specific guards)

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

# Running this file by path already puts hooks/ on sys.path, but not under
# PYTHONSAFEPATH, so name the directory rather than depend on the default.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from shell_parse import *  # noqa: E402,F403  shared shell-command parsing


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

    # The closing fence is a line that is exactly ---. Splitting on the bare
    # substring instead used to end the frontmatter at the first --- inside a
    # value, silently dropping every key after it (a block guard could lose
    # its action: line and quietly become a warn guard).
    fence = re.match(r'^---[ \t]*\n(.*?)\n---[ \t]*(?:\n|\Z)', content, re.DOTALL)
    if not fence:
        print(f"[guard] skipped {filepath}: malformed frontmatter", file=sys.stderr)
        return None

    try:
        meta = parse_frontmatter(fence.group(1))
    except Exception as e:
        print(f"[guard] skipped {filepath}: parse error: {e}", file=sys.stderr)
        return None

    if not meta or not meta.get('enabled', True):
        return None

    meta['message'] = content[fence.end():].strip()
    meta['source'] = filepath
    return meta


def load_guards(event_type):
    """Load all enabled guards for a given event type.

    Returns (guards, builtins_healthy). ``builtins_healthy`` is False when the
    built-in guard set could not be read at all, which means the safety rules
    are absent rather than simply not matching this event.
    """
    guards = []
    dex_dir = os.environ.get('DEX_DIR') or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    # Built-in guards
    builtin_dir = os.path.join(dex_dir, 'hooks', 'guards')
    builtin_files = []
    if os.path.isdir(builtin_dir):
        builtin_files = sorted(glob.glob(os.path.join(builtin_dir, '*.md')))
    builtin_loaded = 0
    for f in builtin_files:
        g = parse_guard(f)
        if g:
            builtin_loaded += 1
            if not g.get('event'):
                print(f"[guard] Warning: guard {f} missing 'event' field, skipping", file=sys.stderr)
            elif g['event'] in (event_type, 'all'):
                guards.append(g)
    builtins_healthy = builtin_loaded > 0

    # Project-specific guards — resolve project root via git toplevel so guards
    # are found regardless of which subdirectory the tool runs from.
    project_root = git_toplevel() or os.getcwd()
    project_dir = os.path.join(project_root, '.dex', 'guards')
    if os.path.isdir(project_dir):
        for f in sorted(glob.glob(os.path.join(project_dir, '*.md'))):
            g = parse_guard(f)
            if g:
                if not g.get('event'):
                    print(f"[guard] Warning: guard {f} missing 'event' field, skipping", file=sys.stderr)
                elif g['event'] in (event_type, 'all'):
                    guards.append(g)

    return guards, builtins_healthy


def _timeout_handler(signum, frame):
    """SIGALRM handler for ReDoS protection. Defined at module level to avoid
    creating a new function object per guard iteration."""
    raise TimeoutError()


# Wall-clock budget for evaluating a single guard against one tool call, for
# both regex patterns and the syntax-aware detectors. Guard patterns can come
# from any repo's .dex/guards/, and detector parsing is super-linear on some
# inputs, so neither may hang the hook. A blocking guard that exceeds this
# denies the command; see check_guards.
GUARD_EVAL_TIMEOUT_SECONDS = 2


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


# These run on every tool call and are asked for several times per run — by
# guard loading, by provider resolution, and again by each env-gated guard.
# The answers cannot change within a single invocation, so resolve once.
_GUARD_PROCESS_CACHE = {}


def git_toplevel():
    if 'git_toplevel' in _GUARD_PROCESS_CACHE:
        return _GUARD_PROCESS_CACHE['git_toplevel']
    try:
        value = subprocess.check_output(
            ['git', 'rev-parse', '--show-toplevel'],
            text=True, stderr=subprocess.DEVNULL
        ).strip()
    except Exception:
        value = ''
    _GUARD_PROCESS_CACHE['git_toplevel'] = value
    return value


def provider_repo_root():
    root = git_toplevel()
    if not root:
        return ''
    marker = os.sep + '.dex' + os.sep + 'worktrees' + os.sep
    if marker in root:
        root = root.split(marker, 1)[0]
    return root


def provider_repo_config_path():
    root = provider_repo_root()
    if not root:
        return ''
    return os.path.join(root, '.dex', 'providers.json')


def provider_global_config_path():
    return os.path.expanduser('~/.dex/providers.json')


def provider_repo_session_key():
    if 'repo_session_key' in _GUARD_PROCESS_CACHE:
        return _GUARD_PROCESS_CACHE['repo_session_key']
    key = __provider_repo_session_key_uncached()
    _GUARD_PROCESS_CACHE['repo_session_key'] = key
    return key


def __provider_repo_session_key_uncached():
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
    if repo_scoped and engine == 'anthropic-gateway' and os.environ.get('DX_ALLOW_REPO_GATEWAY_PROVIDER', '') != '1':
        return ''
    return engine


def provider_default_engine(path, repo_scoped=False):
    data = read_provider_config(path)
    default_profile = data.get('default', '')
    if not isinstance(default_profile, str) or not default_profile:
        return ''
    return provider_profile_engine(path, default_profile, repo_scoped=repo_scoped)


def provider_session_id():
    session_id = os.environ.get('DEX_SESSION_ID', '')
    if session_id:
        return session_id
    if 'provider_session_id' in _GUARD_PROCESS_CACHE:
        return _GUARD_PROCESS_CACHE['provider_session_id']
    root = git_toplevel()
    if root:
        marker = os.sep + '.dex' + os.sep + 'worktrees' + os.sep
        if marker in root:
            return provider_scoped_session_id(f"worktree-{os.path.basename(root)}")
    try:
        branch = subprocess.check_output(
            ['git', 'rev-parse', '--abbrev-ref', 'HEAD'],
            text=True, stderr=subprocess.DEVNULL
        ).strip()
    except Exception:
        branch = ''
    resolved = provider_scoped_session_id(branch.replace('/', '-')) if branch else ''
    _GUARD_PROCESS_CACHE['provider_session_id'] = resolved
    return resolved


def provider_session_engine():
    explicit_session_id = os.environ.get('DEX_SESSION_ID', '')
    # Without an explicit session id, an exported DX_PROVIDER_ENGINE wins over
    # session state (mirrored below after the read). Deciding that from the
    # environment alone skips the git/cksum session-id derivation and the
    # state-file read on every tool call in Dex-launched sessions.
    if not explicit_session_id and os.environ.get('DX_PROVIDER_ENGINE', ''):
        return ''
    session_id = provider_session_id()
    if not session_id:
        return ''
    loop_dir = os.environ.get('DX_LOOP_DIR') or os.path.expanduser('~/.claude/.dex-loops')
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
    if not explicit_session_id and os.environ.get('DX_PROVIDER_ENGINE', ''):
        return ''
    return engine


def resolved_provider_engine():
    if 'resolved_provider_engine' in _GUARD_PROCESS_CACHE:
        return _GUARD_PROCESS_CACHE['resolved_provider_engine']
    engine = __resolve_provider_engine_uncached()
    _GUARD_PROCESS_CACHE['resolved_provider_engine'] = engine
    return engine


def __resolve_provider_engine_uncached():
    session_engine = provider_session_engine()
    if session_engine:
        return session_engine

    repo_config = provider_repo_config_path()
    global_config = provider_global_config_path()
    explicit_profile = os.environ.get('DX_PROVIDER_PROFILE', '')
    if explicit_profile:
        if explicit_profile in PROVIDER_BUILTIN_ENGINES:
            return PROVIDER_BUILTIN_ENGINES[explicit_profile]
        # Mirror dx_provider_apply: explicit custom profiles prefer global user
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
    if env_var == 'DX_PROVIDER_ENGINE':
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
    if env_name == 'DX_PROVIDER_ENGINE':
        actual = provider_session_engine() or os.environ.get(env_name, '') or resolved_guard_environment_value(env_name)
    else:
        actual = os.environ.get(env_name, '') or resolved_guard_environment_value(env_name)
    expected = guard.get('env_value')
    if expected is None or expected == '':
        return bool(actual)
    return actual == str(expected)


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


def is_trusted_dex_helper(path, variables=None, cwd=None):
    resolved = resolve_shell_path(path, variables, cwd)
    if not resolved:
        return False
    root = os.path.realpath(dex_root())
    real = os.path.realpath(resolved)
    try:
        relative = os.path.relpath(real, root)
    except ValueError:
        return False
    if relative.startswith('..' + os.sep) or relative == '..':
        return False
    if relative.startswith('lib' + os.sep) and relative.endswith('.sh'):
        return True
    return relative == os.path.join('bin', 'ui-capture.sh')


CODEX_HELPER_COMMANDS = {'dx_provider_codex', '__dx_provider_codex_raw'}
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


def code_has_raw_codex_delegation(code, kind, depth=0, cwd=None, whole_file=False):
    if code is UNKNOWN_SHELL_STDIN:
        return True
    if depth > 24:
        return True
    if not code or not code.strip():
        return False
    for fragment in code_execution_fragments(code, whole_file=whole_file):
        if has_raw_codex_delegation(fragment, depth + 1, cwd):
            return True
    return False


def code_has_destructive_command(code, depth=0, whole_file=False):
    """Inspect literal commands passed to process-launch APIs in inline code.

    Unlike code_has_raw_codex_delegation, an unverifiable payload (UNKNOWN
    stdin, runaway depth) is allowed rather than blocked: this guard runs on
    every Bash call, and blocking every `python3 -c "$VAR"` whose value it
    cannot see would deny far more legitimate work than it could ever catch.
    The raw-codex guard covers a narrow delegation wrapper, so it can afford
    to fail closed on the same shapes.
    """
    if code is UNKNOWN_SHELL_STDIN or depth > 12:
        return False
    if not code or not code.strip():
        return False
    return any(
        has_destructive_command(fragment, depth + 1)
        for fragment in code_execution_fragments(code, whole_file=whole_file)
    )


def executable_script_has_raw_codex(script_body, depth=0, cwd=None, kind=''):
    if script_body is UNKNOWN_SHELL_STDIN:
        return True
    if not script_body:
        return False
    if has_raw_codex_delegation(script_body, depth + 1, cwd):
        return True
    script_kind = kind or shebang_interpreter_kind(script_body)
    if script_kind and code_has_raw_codex_delegation(
        script_body, script_kind, depth + 1, cwd, whole_file=True
    ):
        return True
    return False


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


def runner_codex_index(tokens, command_index):
    command_base = token_basename(tokens[command_index])
    if command_base in DIRECT_SHELL_RUNNERS:
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


def xargs_substitution_can_launch(command_tokens, replacement):
    """Whether substituting unknown xargs values could produce a new command.

    `xargs -I{} du -k {}` can only ever pass values as arguments to `du`, so
    unreadable stdin is no reason to deny it. `xargs -I{} {}` or
    `xargs -I{} bash -c {}` do turn a value into a command, so those stay
    fail-closed when the values cannot be read.
    """
    if not command_tokens:
        return True
    base_index = skip_wrapper_prefix(command_tokens, 0)
    if base_index >= len(command_tokens):
        return True
    if replacement:
        # The tokenizer splits `{}` into two punctuation tokens.
        if replacement == '{}' and command_tokens[base_index:base_index + 2] == ['{', '}']:
            return True
        if replacement in command_tokens[base_index]:
            return True
    base = token_basename(command_tokens[base_index])
    if base in SHELLS or base in EVAL_COMMANDS or base in SOURCE_COMMANDS:
        return True
    if interpreter_kind(base):
        return True
    return (
        base == 'codex'
        or base in CODEX_HELPER_COMMANDS
        or base in DIRECT_SHELL_RUNNERS
        or base in PACKAGE_MANAGER_RUNNERS
    )


def xargs_stdin_source_visible(tokens, command_index, command_start):
    """Whether the line says where this xargs reads its input.

    An empty result from `shell_stdin_literal` means two different things:
    a source was read and had nothing in it, or no source appears at all and
    the command will read the terminal. The first is provably inert, the
    second is unknowable — they must not be judged the same way.
    """
    if command_start >= 1 and tokens[command_start - 1] == '|':
        return True
    # This deliberately stops at `{` and `}` even though xargs treats them as
    # arguments. `shell_stdin_literal`, which actually reads the source, stops
    # there too — and the pair only holds together while they agree. Excluding
    # them here alone made this say "a source is visible" while the reader
    # returned nothing, and a readable `<<< 'rm -rf /'` became "provably empty".
    # Whoever teaches the reader to look past a bare placeholder can teach this
    # to as well, in the same change.
    index = command_index + 1
    while index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
        if tokens[index] in {'<', '<<<'}:
            return True
        index += 1
    return False


def xargs_unbounded_removal(command_tokens):
    """A recursive forced removal whose targets come from the xargs values.

    Looks past `sudo`, `nice` and the other wrapper prefixes: `xargs sudo rm
    -rf` is as unbounded as `xargs rm -rf`.
    """
    if not command_tokens:
        return False
    base_index = skip_wrapper_prefix(command_tokens, 0)
    if base_index >= len(command_tokens):
        return False
    if token_basename(command_tokens[base_index]) != 'rm':
        return False
    rest = command_tokens[base_index + 1:]
    return (any(rm_option_is_recursive(token) for token in rest)
            and any(rm_option_is_force(token) for token in rest))


def xargs_join_split_placeholder(command_tokens, replacement):
    """Re-join the `{` and `}` tokens the tokenizer splits a bare `{}` into.

    Without this the default spelling reads differently from every other one:
    `xargs -I% %` was judged and `xargs -I{} {}` was not.
    """
    if replacement != '{}':
        return list(command_tokens)
    joined = []
    index = 0
    while index < len(command_tokens):
        if command_tokens[index:index + 2] == ['{', '}']:
            joined.append('{}')
            index += 2
            continue
        joined.append(command_tokens[index])
        index += 1
    return joined


def xargs_placeholder_is_used(command_tokens, replacement):
    """Whether substituted values reach the command at all.

    With `-I`, a command that never names the replacement runs unchanged for
    every input line, so the values cannot influence what it does.
    """
    if not replacement:
        return False
    return any(replacement in token
               for token in xargs_join_split_placeholder(command_tokens, replacement))


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
        values = [] if stdin_text is UNKNOWN_SHELL_STDIN else xargs_stdin_tokens(
            stdin_text, xargs_uses_null_delimiter(tokens, command_index),
            by_line=not xargs_splits_items_on_blanks(tokens, command_index))
        # No values on the line is not no values: `xargs` without a pipe reads
        # the terminal, and the command runs for every line typed there. Judge
        # it the same way unreadable input already is.
        if stdin_text is UNKNOWN_SHELL_STDIN or not values:
            # Values can only become a command where the placeholder appears.
            if xargs_placeholder_is_used(command_tokens, replacement) \
                    and xargs_substitution_can_launch(command_tokens, replacement):
                return True
            # Values can only land in argument position, so judge the template.
            return has_raw_codex_delegation(shell_quote_tokens(command_tokens), depth + 1, cwd)
        for value in values:
            replaced_tokens = replace_xargs_placeholders(command_tokens, replacement, value)
            if replaced_tokens is UNKNOWN_SHELL_STDIN:
                return True
            if has_raw_codex_delegation(shell_quote_tokens(replaced_tokens), depth + 1, cwd):
                return True
        return False
    else:
        stdin_text = shell_stdin_literal(tokens, command_index, command_start, variables, cwd)
        if stdin_text is UNKNOWN_SHELL_STDIN:
            command_base = token_basename(command_tokens[0]) if command_tokens else ''
            return command_base in {'codex'} or command_base in DIRECT_SHELL_RUNNERS or command_base in PACKAGE_MANAGER_RUNNERS
        if stdin_text:
            command_tokens.extend(shell_tokens(stdin_text))
    return has_raw_codex_delegation(shell_quote_tokens(command_tokens), depth + 1, cwd)


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


def expand_literal_shell_word(value, variables=None, cwd=None):
    expanded = apply_literal_variables(value, variables)
    expanded = apply_parameter_expansion_defaults(expanded)
    expanded = decode_ansi_c_token(expanded)
    output = []
    index = 0
    while index < len(expanded):
        if expanded.startswith('$(', index):
            substitution, next_index = scan_dollar_substitution_word(expanded, index)
            if not substitution.endswith(')'):
                return UNKNOWN_SHELL_STDIN
            substitution_output = literal_command_substitution_output(substitution, variables, cwd)
            if substitution_output is UNKNOWN_SHELL_STDIN:
                return UNKNOWN_SHELL_STDIN
            output.append(substitution_output)
            index = next_index
            continue
        if expanded[index] == '`':
            substitution, next_index = scan_backtick_word(expanded, index)
            if not substitution.endswith('`'):
                return UNKNOWN_SHELL_STDIN
            substitution_output = literal_command_substitution_output(substitution, variables, cwd)
            if substitution_output is UNKNOWN_SHELL_STDIN:
                return UNKNOWN_SHELL_STDIN
            output.append(substitution_output)
            index = next_index
            continue
        output.append(expanded[index])
        index += 1
    return ''.join(output)


def direct_script_command_is_blocked(command_token, generated_scripts, variables=None, cwd=None, depth=0):
    script_path = expand_executable_script(command_token, variables)
    if script_path is UNKNOWN_SHELL_STDIN:
        return True
    if not script_path or is_dex_codex_wrapper(script_path, variables, cwd):
        return False

    generated_body = generated_script_for_path(generated_scripts, script_path, variables, cwd)
    if generated_body is UNKNOWN_SHELL_STDIN:
        return True
    if generated_body is not None:
        return executable_script_has_raw_codex(generated_body, depth + 1, cwd)

    if '/' not in script_path:
        return False
    if is_trusted_dex_helper(script_path, variables, cwd):
        return False

    script_body, script_status = shell_file_body_status(script_path, variables, cwd)
    if script_body and executable_script_has_raw_codex(script_body, depth + 1, cwd):
        return True
    return script_status in {'unresolved', 'unreadable'}


def rm_option_is_recursive(token):
    if token in {'-r', '-R', '--recursive'}:
        return True
    return token.startswith('-') and not token.startswith('--') and any(ch in token[1:] for ch in 'rR')


def rm_option_is_force(token):
    if token in {'-f', '--force'}:
        return True
    return token.startswith('-') and not token.startswith('--') and 'f' in token[1:]


def collapse_parent_segments(target):
    """Resolve `..` the way the filesystem will.

    `.` was already collapsed here and `..` was not, so every ascending
    spelling read as an ordinary subdirectory path — the one shape the guard
    deliberately waves through. `rm -rf /etc/..` is `rm -rf /`.

    Above a root this guard protects there is no name to check: `$HOME/..` is
    /Users on this machine and /home on most others. That directory strictly
    contains the protected one, so it is folded back onto the root and judged
    the same. Ascending and then naming a child — `../sibling`,
    `$HOME/../other` — is a specific directory and is left alone.
    """
    segments = target.split('/')
    if '..' not in segments:
        return target
    absolute = segments[0] == ''
    if absolute:
        root, rest = '/', segments[1:]
    elif segments[0] == '..':
        root, rest = '.', segments      # a bare ../ is relative to the cwd
    else:
        root, rest = segments[0], segments[1:]

    kept = []
    for segment in rest:
        if segment == '..':
            if kept:
                kept.pop()
        elif segment not in ('', '.'):
            kept.append(segment)

    if kept:
        return target                   # names a directory; judged as written
    if absolute:
        return '/'                      # root cannot be escaped: /.. is /
    return root


def normalize_rm_target_alias(target):
    wildcard = False
    if target.endswith('/*'):
        wildcard = True
        target = target[:-2]
    if target.startswith('//'):
        target = '/' + target.lstrip('/')
    target = collapse_parent_segments(target)
    while len(target) > 1 and target.endswith('/'):
        target = target[:-1]
    while target.endswith('/.'):
        target = target[:-2] or '/'
        if target.startswith('//'):
            target = '/' + target.lstrip('/')
        while len(target) > 1 and target.endswith('/'):
            target = target[:-1]
    if wildcard:
        return '/*' if target == '/' else f"{target}/*"
    return target


def parameter_expansion_destructive_target(target, depth=0):
    if depth > 2:
        return False
    match = re.match(r'^\$\{[A-Za-z_][A-Za-z0-9_]*((?::?[-=+]))([^}]*)\}(.*)$', target)
    if not match:
        return False
    operator = match.group(1) or ''
    word = match.group(2) or ''
    suffix = match.group(3) or ''
    if operator not in {'-', ':-', '=', ':=', '+', ':+'} or not word:
        return False
    candidate = word
    if suffix:
        candidate = f"{word.rstrip('/') or '/'}{suffix}"
    return destructive_rm_target(candidate, depth + 1)


def destructive_rm_target(token, depth=0):
    target = normalize_rm_target_alias(token.strip('`"\''))
    if target in {'/*', '~/*', '~+/*', '$HOME/*', '${HOME}/*', '$PWD/*', '${PWD}/*', './*', '{}'}:
        return True
    if re.match(r'^\$\{(?:HOME|PWD)(?:(?::?[-=?+])[^}]*)?\}(?:/\*)?$', target):
        return True
    if parameter_expansion_destructive_target(target, depth):
        return True
    if target != '/':
        target = target.rstrip('/')
    return target in {'/', '~', '~+', '$HOME', '${HOME}', '$PWD', '${PWD}', '.', '*'}


def literal_rm_target(token, variables=None, cwd=None):
    expanded = expand_literal_shell_word(token, variables, cwd)
    if expanded is UNKNOWN_SHELL_STDIN:
        return UNKNOWN_SHELL_STDIN
    return expanded


def rm_target_is_destructive(token, variables=None, cwd=None):
    if token is UNKNOWN_SHELL_STDIN:
        return True
    if destructive_rm_target(token):
        return True
    target = literal_rm_target(token, variables, cwd)
    if target is UNKNOWN_SHELL_STDIN:
        return True
    return destructive_rm_target(target)


def rm_invocation_parts(tokens, command_index, variables=None, cwd=None):
    recursive = False
    force = False
    targets = []
    unknown_option = False
    index = command_index + 1

    while index < len(tokens):
        token = tokens[index]
        if token == '$' and index + 1 < len(tokens) and tokens[index + 1] == '(':
            end_index = command_substitution_end(tokens, index)
            if end_index is None:
                targets.append(token)
                index += 1
                continue
            targets.append(f"$({shell_quote_tokens(tokens[index + 2:end_index])})")
            index = end_index + 1
            continue
        if tokens[index:index + 2] == ['{', '}']:
            targets.append('{}')
            index += 2
            continue
        if token in SHELL_SEPARATORS:
            break
        if token == '--':
            cursor = index + 1
            while cursor < len(tokens):
                if tokens[cursor] == '$' and cursor + 1 < len(tokens) and tokens[cursor + 1] == '(':
                    end_index = command_substitution_end(tokens, cursor)
                    if end_index is None:
                        targets.append(tokens[cursor])
                        cursor += 1
                        continue
                    targets.append(f"$({shell_quote_tokens(tokens[cursor + 2:end_index])})")
                    cursor = end_index + 1
                    continue
                if tokens[cursor:cursor + 2] == ['{', '}']:
                    targets.append('{}')
                    cursor += 2
                    continue
                if tokens[cursor] in SHELL_SEPARATORS:
                    break
                targets.append(tokens[cursor])
                cursor += 1
            break
        if token.startswith('-') and token != '-':
            option = expand_literal_shell_word(token, variables, cwd)
            if option is UNKNOWN_SHELL_STDIN:
                unknown_option = True
            else:
                recursive = recursive or rm_option_is_recursive(option)
                force = force or rm_option_is_force(option)
            index += 1
            continue
        expanded = expand_literal_shell_word(token, variables, cwd)
        if expanded is UNKNOWN_SHELL_STDIN:
            unknown_option = True
            targets.append(UNKNOWN_SHELL_STDIN)
        elif expanded.startswith('-') and expanded != '-':
            recursive = recursive or rm_option_is_recursive(expanded)
            force = force or rm_option_is_force(expanded)
        else:
            targets.append(expanded)
        index += 1

    return recursive, force, targets, unknown_option


def rm_invocation_is_destructive(tokens, command_index, variables=None, cwd=None):
    recursive, force, targets, unknown_option = rm_invocation_parts(tokens, command_index, variables, cwd)
    if unknown_option and any(
        target is not UNKNOWN_SHELL_STDIN and rm_target_is_destructive(target, variables, cwd)
        for target in targets
    ):
        return True
    if not recursive or not force:
        return False

    index = 0
    while index < len(targets):
        token = targets[index]
        if token is UNKNOWN_SHELL_STDIN:
            return True
        if token == '$' and index + 1 < len(targets) and targets[index + 1] == '(':
            end_index = command_substitution_end(targets, index)
            if end_index is None:
                return True
            body_tokens = targets[index + 2:end_index]
            target = literal_command_substitution_body_output(body_tokens, variables, cwd)
            if target is UNKNOWN_SHELL_STDIN or destructive_rm_target(target):
                return True
            index = end_index + 1
            continue
        if token.startswith('`'):
            end_index = backtick_substitution_end(targets, index)
            if end_index is None:
                return True
            body_tokens = targets[index:end_index + 1]
            body_tokens[0] = body_tokens[0][1:]
            body_tokens[-1] = body_tokens[-1][:-1]
            target = literal_command_substitution_body_output(body_tokens, variables, cwd)
            if target is UNKNOWN_SHELL_STDIN or destructive_rm_target(target):
                return True
            index = end_index + 1
            continue
        if rm_target_is_destructive(token, variables, cwd):
            return True
        index += 1

    return False


def destructive_command_segment_is_blocked(tokens, command_index, variables=None, cwd=None):
    command_base = token_basename(tokens[command_index])
    segment_tokens = []
    index = command_index + 1
    while index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
        segment_tokens.append(tokens[index])
        index += 1

    if command_base == 'rm':
        return rm_invocation_is_destructive(tokens, command_index, variables, cwd)
    if command_base == 'dd':
        for token in segment_tokens:
            expanded = expand_literal_shell_word(token, variables, cwd)
            if expanded is UNKNOWN_SHELL_STDIN or not expanded.startswith('of='):
                continue
            target = expanded.split('=', 1)[1].strip('"\'')
            if target.startswith('/dev/') and target not in {'/dev/null', '/dev/stdout'}:
                return True
            if re.match(r'^\\\\\.\\PhysicalDrive[0-9]+$', target, re.IGNORECASE):
                return True
        return False
    if command_base == 'diskutil':
        destructive_subcommands = {
            'deletedisk', 'deletecontainer', 'deletevolume', 'erasedisk',
            'erasevolume', 'partitiondisk', 'randomdisk', 'secureerase',
            'zerodisk',
        }
        return any(token.lower() in destructive_subcommands for token in segment_tokens)
    if command_base == 'busybox':
        applet_index = 0
        while applet_index < len(segment_tokens) and segment_tokens[applet_index].startswith('-'):
            applet_index += 1
        if applet_index < len(segment_tokens):
            nested_tokens = segment_tokens[applet_index:]
            return destructive_command_segment_is_blocked(nested_tokens, 0, variables, cwd)
        return False
    if command_base == 'mkfs' or command_base.startswith('mkfs.'):
        return True
    if command_base == 'format':
        return any(re.match(r'^[a-z]:$', token, re.IGNORECASE) for token in segment_tokens)
    return False


def xargs_destructive_command_is_blocked(tokens, command_index, command_start, variables=None, cwd=None, depth=0):
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
    null_delimited = xargs_uses_null_delimiter(tokens, command_index)
    if replacement:
        stdin_text = shell_stdin_literal(tokens, command_index, command_start, variables, cwd)
        values = [] if stdin_text is UNKNOWN_SHELL_STDIN else xargs_stdin_tokens(
            stdin_text, null_delimited,
            by_line=not xargs_splits_items_on_blanks(tokens, command_index))
        # No values visible on the line is not the same as no values: `xargs`
        # without a pipe reads the terminal, and every line typed there runs
        # the command. Judging it as written is what the unreadable case
        # already does, and returning False here skipped the command entirely.
        if (stdin_text is not UNKNOWN_SHELL_STDIN and not stdin_text
                and xargs_stdin_source_visible(tokens, command_index, command_start)):
            # The line shows where the input comes from and there is nothing in
            # it at all, so no value is substituted. That is not the same as
            # the command not running: GNU xargs runs it once anyway unless
            # given `-r`, with the replacement left as written. So judge the
            # command as it stands rather than calling it inert.
            #
            # This asks about the text, not the items: a whitespace-only line
            # yields no item here but is still an item to xargs, which runs the
            # command once with the replacement expanded to nothing.
            return has_destructive_command(shell_quote_tokens(command_tokens), depth + 1)
        if stdin_text is UNKNOWN_SHELL_STDIN or not values:
            if not xargs_placeholder_is_used(command_tokens, replacement):
                # The values never reach the command, so judge it as written.
                # `xargs -I{} rm -rf ./build` removes that directory and
                # nothing else, however many lines arrive on stdin.
                return has_destructive_command(shell_quote_tokens(command_tokens), depth + 1)
            if xargs_substitution_can_launch(command_tokens, replacement):
                # Handed to a shell or an interpreter, an unknown value can be
                # a command. Telling the code positions from the data ones was
                # tried and repeatedly got it wrong — a script can `eval` or
                # `exec` its own positionals, an option's separate value hides
                # the program, and each refinement lost coverage somewhere
                # else. This is the coarse answer, and it is the safe one.
                return True
            # Substituted into an ordinary argument it is a filename, which is
            # only destructive for a recursive forced removal.
            if xargs_unbounded_removal(command_tokens):
                return True
            return has_destructive_command(shell_quote_tokens(command_tokens), depth + 1)
        # A readable value handed to a shell has to be read as a command in its
        # own right: substituted in, it is only ever an argument, so a readable
        # `rm -rf /` arriving at `sh -c 'eval "$1"' sh {}` looked harmless.
        substitutes_into_code = (
            xargs_placeholder_is_used(command_tokens, replacement)
            and xargs_substitution_can_launch(command_tokens, replacement)
        )
        for value in values:
            if substitutes_into_code and has_destructive_command(value, depth + 1):
                return True
            replaced_tokens = replace_xargs_placeholders(command_tokens, replacement, value)
            if replaced_tokens is UNKNOWN_SHELL_STDIN:
                return True
            if has_destructive_command(shell_quote_tokens(replaced_tokens), depth + 1):
                return True
        return False
    else:
        stdin_text = shell_stdin_literal(tokens, command_index, command_start, variables, cwd)
        # Without a replacement the values are appended as further arguments,
        # so they are targets. Not seeing them on the line says nothing about
        # what they will be — the same reasoning as the `-I` branch above.
        # A source that is there and empty appends nothing, which is different.
        if (stdin_text is not UNKNOWN_SHELL_STDIN and not stdin_text
                and xargs_stdin_source_visible(tokens, command_index, command_start)):
            return has_destructive_command(shell_quote_tokens(command_tokens), depth + 1)
        if stdin_text is UNKNOWN_SHELL_STDIN or not stdin_text:
            if xargs_unbounded_removal(command_tokens):
                return True
            return has_destructive_command(shell_quote_tokens(command_tokens), depth + 1)
        command_tokens.extend(xargs_stdin_tokens(stdin_text, null_delimited))
    return has_destructive_command(shell_quote_tokens(command_tokens), depth + 1)


def find_search_roots(tokens, command_index):
    roots = []
    index = command_index + 1
    while index < len(tokens):
        token = tokens[index]
        if token in SHELL_SEPARATORS:
            break
        if token == '$' and index + 1 < len(tokens) and tokens[index + 1] == '(':
            end_index = command_substitution_end(tokens, index)
            if end_index is None:
                roots.append(token)
                index += 1
                continue
            roots.append(f"$({shell_quote_tokens(tokens[index + 2:end_index])})")
            index = end_index + 1
            continue
        if token in {'-H', '-L', '-P'}:
            index += 1
            continue
        if token == '--':
            index += 1
            continue
        if token.startswith('-') or token in {'!', ','}:
            break
        roots.append(token)
        index += 1
    return roots or ['.']


def find_deletes_in_place(tokens, command_index):
    """Whether this `find` removes what it matches without running `rm`.

    `-delete` reaches the same end as `-exec rm -rf {} +`, which is caught by
    resolving the nested command. Here there is no nested command to resolve,
    so the action has to be recognised on its own — `find / -delete` was the
    one spelling of "empty the disk" that this detector let through.

    A `-delete` inside an `-exec` belongs to that nested command, not to this
    find, so those spans are skipped rather than scanned.
    """
    index = command_index + 1
    while index < len(tokens):
        token = tokens[index]
        if token == '$' and index + 1 < len(tokens) and tokens[index + 1] == '(':
            end_index = command_substitution_end(tokens, index)
            if end_index is not None:
                index = end_index + 1
                continue
        if token in SHELL_SEPARATORS and token != ';':
            break
        if token in {'-exec', '-execdir', '-ok', '-okdir'}:
            index += 1
            while index < len(tokens) and tokens[index] not in {';', '+'}:
                index += 1
        elif token == '-delete':
            return True
        index += 1
    return False


def find_destructive_command_is_blocked(tokens, command_index, variables=None, cwd=None, depth=0):
    if token_basename(tokens[command_index]) != 'find':
        return False
    roots = find_search_roots(tokens, command_index)
    if find_deletes_in_place(tokens, command_index) and \
            any(rm_target_is_destructive(root, variables, cwd) for root in roots):
        return True
    for command_tokens in find_exec_commands(tokens, command_index):
        nested_command_index = skip_wrapper_prefix(command_tokens, 0) if command_tokens else 0
        if nested_command_index < len(command_tokens) and token_basename(command_tokens[nested_command_index]) == 'rm':
            recursive, force, targets, unknown_option = rm_invocation_parts(command_tokens, nested_command_index, variables, cwd)
            if unknown_option and any(rm_target_is_destructive(target, variables, cwd) for target in targets):
                return True
            if recursive and force:
                non_placeholder_targets = [target for target in targets if target != '{}']
                if any(rm_target_is_destructive(target, variables, cwd) for target in non_placeholder_targets):
                    return True
                if any(target == '{}' for target in targets):
                    return any(rm_target_is_destructive(root, variables, cwd) for root in roots)
                continue
        if has_destructive_command(shell_quote_tokens(command_tokens), depth + 1):
            return True
    return False


def eval_destructive_command_is_blocked(tokens, command_index, variables=None, depth=0):
    if token_basename(tokens[command_index]) not in EVAL_COMMANDS:
        return False
    index = command_index + 1
    script_tokens = []
    while index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
        script_tokens.append(tokens[index])
        index += 1
    if not script_tokens:
        return False
    script = expand_executable_script(' '.join(script_tokens), variables)
    if script is UNKNOWN_SHELL_STDIN:
        return True
    return bool(script and has_destructive_command(script, depth + 1))


def substitution_invocation_is_destructive(tokens, index, shell_vars=None, cwd=None, depth=0):
    resolved_invocation = command_substitution_resolved_invocation(tokens, index, shell_vars, cwd)
    if resolved_invocation is None:
        return False, None

    resolved_command, resolved_args, _ = resolved_invocation
    body_tokens, substitution_end_index = command_substitution_body_tokens(tokens, index)
    if resolved_command is UNKNOWN_SHELL_STDIN:
        return True, substitution_end_index
    if not resolved_command:
        return False, substitution_end_index

    resolved_text = shell_quote_tokens([resolved_command] + resolved_args)
    return has_destructive_command(resolved_text, depth + 1), substitution_end_index


def has_destructive_command(text, depth=0):
    # Fail closed on runaway nesting. This is lower than the raw-codex and
    # commit parsers' 24 on purpose: resolution gives up on a nested `$(…)`
    # ladder from the second level, so between here and there the cap is the
    # only thing standing in the way of one that ends in a destructive
    # command. Raising it to match the siblings was measured to let depths 9
    # through 24 execute. Aligning them means teaching resolution to see
    # through the ladder first.
    if depth > 8:
        return True
    if not text.strip():
        return False

    shell_text, heredoc_substitutions, heredoc_bodies = strip_heredoc_bodies(text)
    for fragment in heredoc_substitutions:
        if has_destructive_command(fragment, depth + 1):
            return True
    for body in heredoc_bodies:
        if has_destructive_command(body, depth + 1):
            return True
    for _kind, body in interpreter_heredoc_bodies(text):
        if code_has_destructive_command(body, depth + 1):
            return True
    for fragment in extract_executable_backticks(shell_text):
        if has_destructive_command(fragment, depth + 1):
            return True
    for fragment in extract_dollar_substitutions(shell_text):
        if has_destructive_command(fragment, depth + 1):
            return True

    tokens = shell_word_tokens(shell_text)
    shell_vars = collect_literal_variables(tokens)
    aliases = collect_aliases(tokens, shell_vars)
    generated_scripts = redirect_generated_scripts(tokens, shell_vars, os.getcwd())
    generated_scripts.update(heredoc_generated_scripts(text, shell_vars, os.getcwd()))
    for script in shell_c_scripts(shell_text, shell_vars):
        if script is UNKNOWN_SHELL_STDIN:
            return True
        if has_destructive_command(script, depth + 1):
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
            blocked, direct_substitution_end = substitution_invocation_is_destructive(tokens, index, shell_vars, None, depth)
            if blocked:
                return True
            if direct_substitution_end is not None:
                command_position = False
                index = direct_substitution_end + 1
                continue
            command_index = skip_wrapper_prefix(tokens, index)
            if command_index >= len(tokens):
                return False
            # Resolve the command word the way has_raw_codex_delegation does.
            # Reading the raw token meant `R=rm; $R -rf /` named no command this
            # guard knows, so it passed in silence — while the same line written
            # as an alias or a substitution was caught. An unresolvable word is
            # left alone rather than warned about: the coarse answer belongs to
            # payloads that can launch something, not to every unknown name.
            segment_tokens = tokens
            command_token = expand_shell_command_token(tokens[command_index], shell_vars)
            if command_token is not UNKNOWN_SHELL_STDIN and command_token != tokens[command_index]:
                segment_tokens = (
                    tokens[:command_index] + [command_token] + tokens[command_index + 1:]
                )
            command_base = token_basename(segment_tokens[command_index])
            if command_base in aliases:
                alias_body = aliases[command_base]
                if alias_body is UNKNOWN_SHELL_STDIN:
                    return True
                segment_end = command_segment_end(tokens, command_index + 1)
                alias_command = f"{alias_body} {shell_quote_tokens(tokens[command_index + 1:segment_end])}"
                if has_destructive_command(alias_command, depth + 1):
                    return True
            blocked, wrapped_substitution_end = substitution_invocation_is_destructive(tokens, command_index, shell_vars, None, depth)
            if blocked:
                return True
            if wrapped_substitution_end is not None:
                command_position = False
                index = wrapped_substitution_end + 1
                continue
            if eval_destructive_command_is_blocked(tokens, command_index, shell_vars, depth):
                return True
            if destructive_command_segment_is_blocked(segment_tokens, command_index, shell_vars, None):
                return True
            env_payload = env_split_payload(tokens, command_index, shell_vars)
            if env_payload is UNKNOWN_SHELL_STDIN:
                return True
            if env_payload and has_destructive_command(env_payload, depth + 1):
                return True
            if xargs_destructive_command_is_blocked(tokens, command_index, index, shell_vars, None, depth):
                return True
            if find_destructive_command_is_blocked(tokens, command_index, shell_vars, None, depth):
                return True
            for _kind, script, from_file in interpreter_code_payloads(
                tokens, command_index, index, generated_scripts, shell_vars, os.getcwd()
            ):
                if code_has_destructive_command(script, depth + 1, whole_file=from_file):
                    return True
            while index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
                index += 1
            command_position = False
            continue

        command_position = False
        index += 1

    return False


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

            if command_base in SHELLS and shell_invocation_is_noexec(tokens, command_index):
                # Syntax-check only: nothing in the script or -c payload runs.
                command_position = False
                index = command_segment_end(tokens, command_index + 1)
                continue

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
                    if generated_body is None and is_trusted_dex_helper(script_file, shell_vars, cwd):
                        command_position = False
                        index = command_segment_end(tokens, command_index + 1)
                        continue
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
                    if generated_body is None and is_trusted_dex_helper(script_file, shell_vars, cwd):
                        command_position = False
                        index = command_segment_end(tokens, command_index + 1)
                        continue
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

            for kind, script, from_file in interpreter_code_payloads(tokens, command_index, index, generated_scripts, shell_vars, cwd):
                if script is UNKNOWN_SHELL_STDIN:
                    return True
                if code_has_raw_codex_delegation(script, kind, depth + 1, cwd, whole_file=from_file):
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


_LOOP_HEADER_RE = re.compile(
    r'(?<![\w$])(?:(?P<async_prefix>async|await)\s+)?'
    r'(?P<kind>foreach|for|while)(?:\s+(?P<await_suffix>await)\b)?'
    r'(?![\w$])'
)
_AWAIT_TOKEN_RE = re.compile(r'(?<![\w$])await(?![\w$])')
_FUNCTION_TOKEN_RE = re.compile(r'(?<![\w$])function(?![\w$])')
_CONTROL_SCOPE_WORDS = {
    'catch', 'class', 'do', 'else', 'finally', 'for', 'foreach', 'if',
    'switch', 'try', 'while', 'with',
}


def strip_comments_and_strings(text):
    """Blank string/template literals and comments so loop/brace/await scanning
    only sees real code. Strings are blanked first (so a `//` or `/*` inside a
    string is already gone), then line and block comments are removed."""
    cleaned = code_without_string_literals(text)
    cleaned = re.sub(r'/\*.*?\*/', ' ', cleaned, flags=re.DOTALL)
    cleaned = re.sub(r'//[^\n]*', '', cleaned)
    cleaned = re.sub(r'#[^\n]*', '', cleaned)
    return cleaned


def previous_nonspace_index(text, index):
    i = index
    while i >= 0 and text[i].isspace():
        i -= 1
    return i


def previous_word(text, index):
    i = previous_nonspace_index(text, index)
    end = i + 1
    while i >= 0 and (text[i].isalnum() or text[i] in {'_', '$'}):
        i -= 1
    return text[i + 1:end], i


def matching_open_paren(text, close_index):
    depth = 0
    i = close_index
    while i >= 0:
        char = text[i]
        if char == ')':
            depth += 1
        elif char == '(':
            depth -= 1
            if depth == 0:
                return i
        i -= 1
    return -1


def matching_brace_body(text, open_index):
    """Return the body between the '{' at open_index and its matching '}'. If the
    brace is never closed (a partial Edit fragment), the body runs to end-of-text
    so the pattern is still caught."""
    depth = 0
    i = open_index
    n = len(text)
    while i < n:
        char = text[i]
        if char == '{':
            depth += 1
        elif char == '}':
            depth -= 1
            if depth == 0:
                return text[open_index + 1:i]
        i += 1
    return text[open_index + 1:]


def matching_parenthesized_header_end(text, open_index):
    depth = 0
    i = open_index
    n = len(text)
    while i < n:
        char = text[i]
        if char == '(':
            depth += 1
        elif char == ')':
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return n


def colon_body(text, colon_index):
    line_end = text.find('\n', colon_index)
    if line_end == -1:
        return text[colon_index + 1:]
    inline = text[colon_index + 1:line_end]
    if inline.strip():
        return inline

    header_line_start = text.rfind('\n', 0, colon_index) + 1
    header_indent = len(text[header_line_start:colon_index]) - len(text[header_line_start:colon_index].lstrip())
    body_start = line_end + 1
    body_end = body_start
    n = len(text)
    while body_end < n:
        next_end = text.find('\n', body_end)
        if next_end == -1:
            next_end = n
        line = text[body_end:next_end]
        if line.strip():
            indent = len(line) - len(line.lstrip())
            if indent <= header_indent:
                break
        body_end = next_end + 1
    return text[body_start:body_end]


def loop_body_after_header(text, header):
    if header.group('async_prefix') in {'async', 'await'} or header.group('await_suffix'):
        return None

    i = header.end()
    n = len(text)
    while i < n and text[i].isspace():
        i += 1

    if i < n and text[i] == '(':
        i = matching_parenthesized_header_end(text, i)
    else:
        while i < n and text[i] not in {'{', ':', '\n', ';'}:
            i += 1

    while i < n and text[i].isspace() and text[i] != '\n':
        i += 1
    if i < n and text[i] == '{':
        return matching_brace_body(text, i)
    if i < n and text[i] == ':':
        return colon_body(text, i)

    statement_end = n
    for delimiter in (';', '\n'):
        found = text.find(delimiter, i)
        if found != -1:
            statement_end = min(statement_end, found)
    return text[i:statement_end]


def skip_arrow_expression_body(text, index):
    i = index
    n = len(text)
    paren_depth = bracket_depth = brace_depth = 0
    while i < n:
        char = text[i]
        if char == '(':
            paren_depth += 1
        elif char == '[':
            bracket_depth += 1
        elif char == '{':
            brace_depth += 1
        elif char == ')':
            if paren_depth == 0 and bracket_depth == 0 and brace_depth == 0:
                return i
            paren_depth = max(paren_depth - 1, 0)
        elif char == ']':
            if paren_depth == 0 and bracket_depth == 0 and brace_depth == 0:
                return i
            bracket_depth = max(bracket_depth - 1, 0)
        elif char == '}':
            if paren_depth == 0 and bracket_depth == 0 and brace_depth == 0:
                return i
            brace_depth = max(brace_depth - 1, 0)
        elif char in {';', ',', '\n'} and paren_depth == 0 and bracket_depth == 0 and brace_depth == 0:
            return i
        i += 1
    return i


def brace_opens_callable_scope(body, brace_index, next_brace_is_fn):
    if next_brace_is_fn:
        return True

    prev = previous_nonspace_index(body, brace_index - 1)
    if prev == -1:
        return False
    if body[prev] == ')':
        open_paren = matching_open_paren(body, prev)
        if open_paren == -1:
            return False
        word, _ = previous_word(body, open_paren - 1)
        return bool(word) and word not in _CONTROL_SCOPE_WORDS

    word, _ = previous_word(body, brace_index - 1)
    return bool(word) and word not in _CONTROL_SCOPE_WORDS


def body_has_unnested_await(body):
    """True if body contains an `await` that is NOT inside an inner function or
    callable scope. Awaits inside `if`/`try`/nested loop blocks still count;
    awaits inside closures or methods belong to a different async context and
    do not."""
    i = 0
    n = len(body)
    scope_is_fn = []          # one bool per currently-open '{'
    next_brace_is_fn = False  # does the next '{' open a function scope?
    while i < n:
        if body.startswith('function', i) and _FUNCTION_TOKEN_RE.match(body, i):
            next_brace_is_fn = True
            i += 8
            continue
        if body.startswith('=>', i):
            j = i + 2
            while j < n and body[j].isspace():
                j += 1
            if j < n and body[j] == '{':
                next_brace_is_fn = True
            else:
                i = skip_arrow_expression_body(body, j)
                continue
            i += 2
            continue
        char = body[i]
        if char == '{':
            scope_is_fn.append(brace_opens_callable_scope(body, i, next_brace_is_fn))
            next_brace_is_fn = False
            i += 1
            continue
        if char == '}':
            if scope_is_fn:
                scope_is_fn.pop()
            i += 1
            continue
        if body.startswith('await', i) and _AWAIT_TOKEN_RE.match(body, i):
            if not any(scope_is_fn):
                return True
            i += 5
            continue
        i += 1
    return False


def has_await_in_loop(text):
    """Detect `await` used directly inside a loop body. Async iteration forms
    such as `for await`, `async for`, and `await foreach` are intentional and
    are not flagged."""
    cleaned = strip_comments_and_strings(text)
    for header in _LOOP_HEADER_RE.finditer(cleaned):
        body = loop_body_after_header(cleaned, header)
        if body is None:
            continue
        if body_has_unnested_await(body):
            return True
    return False


def guard_detector_matches(guard, text):
    detector = guard.get('detector', '')
    if not detector:
        return None
    if detector == 'destructive-commands':
        return has_destructive_command(text)
    if detector == 'raw-codex-delegation':
        return has_raw_codex_delegation(text)
    if detector == 'await-in-loop':
        return has_await_in_loop(text)
    print(f"[guard:{guard.get('name', 'unnamed')}] skipped — unknown detector: {detector}", file=sys.stderr)
    return False


def check_guards(guards, full_text, path_text=''):
    """Check text against all guards. Returns (warnings, blocks).

    Each guard's regex pattern is matched against the full text. Matching is
    case-insensitive by default; set case_sensitive: true in frontmatter for
    exact-case matching. If allow_pattern is present, it is checked against each
    individual match so one allowed command does not hide a separate blocked one.

    A guard with `match: path` is checked against `path_text` — the file paths
    of a file event — rather than the paths plus the file's contents.
    """
    warnings = []
    blocks = []

    for guard in guards:
        pattern = guard.get('pattern', '')
        allow_pattern = guard.get('allow_pattern', '')
        name = guard.get('name', 'unnamed')
        if not guard_environment_matches(guard):
            continue

        action = guard.get('action', 'warn')

        scope = str(guard.get('match', 'all')).strip().lower()
        if scope == 'path':
            if not path_text:
                continue
            text = path_text
        else:
            text = full_text

        # Detectors parse the whole command, which can be slow on pathological
        # input and can raise on deeply nested constructs. Bound and contain
        # both: for a blocking guard, an evaluation failure on this specific
        # input must deny the command rather than let it through unchecked.
        # Only this one tool call is affected, so the user can rephrase it.
        # `allow_pattern` exempts a span, not the command. Blanking the allowed
        # spans and judging what is left is the difference between "this form
        # is fine" and "mentioning this form makes the rest invisible": a
        # command that pairs an exempted `eval` with something else still gets
        # judged on the something else. Done before the detector runs, so it
        # costs one parse rather than two.
        detector_text = text
        if allow_pattern and guard.get('detector'):
            try:
                detector_text = re.sub(
                    allow_pattern, ' ', text,
                    flags=re.MULTILINE | (0 if guard.get('case_sensitive') else re.IGNORECASE))
            except re.error as error:
                print(f"[guard:{name}] invalid allow_pattern regex: {error}", file=sys.stderr)
                detector_text = text

        _prev_handler = signal.signal(signal.SIGALRM, _timeout_handler)
        signal.alarm(GUARD_EVAL_TIMEOUT_SECONDS)
        try:
            detector_match = guard_detector_matches(guard, detector_text)
            detector_error = ''
        except TimeoutError:
            detector_match = None
            detector_error = f'evaluation exceeded {GUARD_EVAL_TIMEOUT_SECONDS}s'
        except RecursionError:
            detector_match = None
            detector_error = 'input nesting exceeded the parser limit'
        except Exception as e:  # noqa: BLE001 - fail closed on any parse failure
            detector_match = None
            detector_error = f'{type(e).__name__}: {e}'
        finally:
            signal.alarm(0)
            signal.signal(signal.SIGALRM, _prev_handler)

        if detector_error:
            if action == 'block':
                blocks.append({
                    'name': name,
                    'message': (
                        f'BLOCKED: this guard could not finish checking the command '
                        f'({detector_error}).\n\nDex denies commands it cannot verify. '
                        f'Simplify or split the command and try again.'
                    ),
                    'action': 'block',
                })
            else:
                print(f"[guard:{name}] skipped — {detector_error}", file=sys.stderr)
            continue

        if detector_match is not None:
            if not detector_match:
                continue
            entry = {
                'name': name,
                'message': guard.get('message', 'Guard triggered.'),
                'action': action,
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
        # signal.alarm is Unix-only; Dex targets macOS/Linux exclusively.
        # See: https://docs.python.org/3/library/signal.html#signal.alarm
        _prev_handler = signal.signal(signal.SIGALRM, _timeout_handler)
        signal.alarm(GUARD_EVAL_TIMEOUT_SECONDS)
        try:
            matched = None
            for candidate in compiled.finditer(text):
                if allow_compiled and allow_compiled.search(candidate.group(0)):
                    continue
                matched = candidate
                break
        except TimeoutError:
            if action == 'block':
                blocks.append({
                    'name': name,
                    'message': (
                        'BLOCKED: this guard timed out while checking the command '
                        '(possible ReDoS).\n\nDex denies commands it cannot verify. '
                        'Simplify or split the command and try again.'
                    ),
                    'action': 'block',
                })
            else:
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


def extract_hook_path_text(raw_input, event_type):
    """Return only the file paths from a file-event payload.

    Guards that scope to a location (`match: path`) check this instead of the
    path concatenated with the file's contents, so a rule about `lib/*.sh` does
    not fire on every file that merely mentions that path.
    """
    if event_type != 'file' or not raw_input.strip():
        return ''
    try:
        payload = json.loads(raw_input)
    except json.JSONDecodeError:
        return ''
    if not isinstance(payload, dict):
        return ''
    tool_input = payload.get('tool_input', {})
    if not isinstance(tool_input, dict):
        return ''
    parts = []
    for key in ('file_path', 'notebook_path'):
        value = tool_input.get(key)
        if isinstance(value, str) and value:
            parts.append(value)
    return '\n'.join(parts)


def extract_hook_text(raw_input, event_type):
    """Extract guard-checkable text from Claude hook JSON.

    Claude Code sends hook payloads as JSON on stdin. Manual tests may pass
    plain text, so non-JSON input is returned as-is.
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
    # guards from built-in (hooks/guards/) and project (.dex/guards/) dirs
    # → check each guard's regex against the input → print warnings/blocks
    # → exit 2 if any blocking guard triggered, 0 otherwise.
    # See: docs/guards.md for full guard system documentation.
    stdin_input = '' if sys.stdin.isatty() else sys.stdin.read()
    tool_input = stdin_input if stdin_input.strip() else os.environ.get('CLAUDE_TOOL_USE_INPUT', '')

    # Determine event type from environment
    event_type = os.environ.get('DEX_GUARD_EVENT', 'bash')

    guards, builtins_healthy = load_guards(event_type)
    if not builtins_healthy:
        # The built-in rules are the security baseline. If none could be read,
        # the install is broken and nothing is being checked — deny rather than
        # run every tool call unguarded.
        print("\n[guard] BLOCKED — no built-in guards could be loaded.", file=sys.stderr)
        print("Dex cannot verify this tool call. Check that DEX_DIR points at the Dex "
              "checkout and that hooks/guards/ is readable, then run 'dx tools bootstrap'.",
              file=sys.stderr)
        sys.exit(2)
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

    warnings, blocks = check_guards(guards, text, extract_hook_path_text(tool_input, event_type))

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
    try:
        main()
    except SystemExit:
        raise
    except BaseException as e:  # noqa: BLE001 - a crashed guard must not allow the call
        # Exit 1 would let the tool call through with no guard evaluation at
        # all, silently disabling every safety rule. Deny instead: a parser
        # bug then costs one blocked command rather than an unguarded one.
        print(f"\n[guard] BLOCKED — guard evaluation failed: {type(e).__name__}: {e}",
              file=sys.stderr)
        print("Dex denies tool calls it cannot check. Rephrase the command, or set "
              "'enabled: false' in the offending guard's .md file if this persists.",
              file=sys.stderr)
        sys.exit(2)
