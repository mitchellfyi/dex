#!/usr/bin/env python3
"""Shared shell-command parsing for the Dex hooks.

Two hooks read the same Bash command and ask different questions of it:

  hooks/guard-handler.py      does this command do something worth flagging?
  hooks/git-commit-target.py  did this command create a commit, and where?

Both have to see through the same obfuscation surface first — wrappers, env
prefixes, aliases and functions, nested shells, interpreter payloads, heredocs,
generated scripts, xargs, find -exec, command substitution — before either
question can be answered. That reading is what lives here.

These primitives used to be copied into both hooks, and they drifted: one
learned to expand `${VAR:+…}`, to track `export`/`declare` assignments, to keep
a backslash inside double quotes, and to pass an xargs item along as a single
argument, while the other kept the older answers. One copy means a capability
taught once reaches both questions.

No external dependencies — stdlib only.
"""
import os
import re
import shlex
import shutil

# Everything below is shared with both hooks. Listed explicitly so the
# module's surface is stated in one place, and so tests/parser-drift-test.sh
# can tell a primitive that belongs here from one a hook legitimately owns.
__all__ = [
    'ASSIGNMENT_BUILTINS', 'CODE_EXECUTION_RE', 'CODE_FRAGMENT_SUFFIX_JOINS',
    'DIRECT_SHELL_RUNNERS', 'ENV_OPTION_ARGS', 'EVAL_COMMANDS', 'HEREDOC_RE',
    'INLINE_BACKTICK_SUB_RE', 'INLINE_DOLLAR_SUB_RE', 'NICE_VALUE_OPTIONS',
    'NODE_VALUE_OPTIONS', 'PACKAGE_MANAGER_RUNNERS',
    'PREFIX_WRAPPER_VALUE_OPTIONS', 'PRINTF_SPECIFIERS',
    'PYTHON_VALUE_OPTIONS', 'RUNNER_SHELL_VALUE_OPTIONS',
    'RUNNER_VALUE_OPTIONS', 'SHELLS', 'SHELL_COMMAND_KEYWORDS',
    'SHELL_END_KEYWORDS', 'SHELL_LEADING_VARIABLE_RE', 'SHELL_REDIRECTS',
    'SHELL_SCRIPT_VALUE_OPTIONS', 'SHELL_SEPARATORS', 'SHELL_VARIABLE_REF_RE',
    'SHELL_VARIABLE_WORD_RE', 'SOURCE_COMMANDS', 'SUDO_OPTION_ARGS',
    'TIMEOUT_VALUE_OPTIONS', 'TIME_FLAGS', 'TIME_OPTION_ARGS',
    'UNKNOWN_SHELL_STDIN', 'XARGS_REPLACEMENT_OPTIONS', 'XARGS_VALUE_OPTIONS',
    'adjacent_string_fragments', 'apply_literal_variables',
    'apply_parameter_expansion_defaults', 'assignment_end', 'assignment_parts',
    'backtick_substitution_end', 'cd_target', 'code_execution_fragments',
    'code_without_string_literals', 'collect_aliases',
    'collect_literal_variables', 'command_segment_end',
    'command_substitution_body_tokens', 'command_substitution_end',
    'command_substitution_literal_command_token',
    'command_substitution_resolved_invocation',
    'command_token_has_embedded_substitution', 'decode_ansi_c_token',
    'decode_shell_backslash_escapes', 'dex_root',
    'downstream_pipeline_has_shell', 'downstream_pipeline_interpreter_kind',
    'env_split_payload', 'execution_call_regions', 'expand_executable_script',
    'expand_literal_output_token', 'expand_shell_command_token',
    'extract_dollar_substitutions', 'extract_executable_backticks',
    'find_exec_commands', 'fragment_region_candidates',
    'function_definition_end', 'generated_script_for_path',
    'heredoc_generated_scripts', 'heredoc_receiver_interpreter_kind',
    'heredoc_receiver_is_shell', 'heredoc_write_target',
    'interpreter_code_payloads', 'interpreter_heredoc_bodies',
    'interpreter_inline_payload', 'interpreter_kind',
    'interpreter_option_takes_value', 'interpreter_script_body',
    'is_dex_codex_wrapper', 'is_inline_command_substitution',
    'is_shell_assignment', 'is_supported_runner_command',
    'joined_string_fragments', 'literal_command_lookup_output',
    'literal_command_substitution_body_output',
    'literal_command_substitution_output', 'literal_shell_input_command',
    'normalize_generated_path', 'normalize_shell_tokens',
    'process_substitution_body', 'process_substitution_index_for_command',
    'process_substitution_literal_output', 'quoted_string_fragments',
    'redirect_generated_scripts', 'render_printf_once', 'render_printf_output',
    'replace_xargs_placeholders', 'resolve_shell_path',
    'ruby_perl_exec_fragments', 'runner_command_end', 'runner_shell_payloads',
    'scan_backtick_word', 'scan_dollar_substitution_word',
    'shebang_interpreter_kind', 'shell_assignment_literal_pair',
    'shell_c_scripts', 'shell_file_body_status', 'shell_functions',
    'shell_invocation_is_noexec', 'shell_quote_tokens', 'shell_script_arg',
    'shell_script_file_arg', 'shell_stdin_literal', 'shell_tokens',
    'shell_word_tokens', 'shell_wrapper_variables',
    'short_option_has_attached_value', 'skip_runner_options',
    'skip_wrapper_prefix', 'source_script_file_arg', 'strip_heredoc_bodies',
    'substitution_end', 'tee_generated_script', 'token_basename',
    'token_takes_value', 'variable_name_at', 'word_array_fragments',
    'xargs_command_start', 'xargs_splits_items_on_blanks',
    'xargs_stdin_tokens', 'xargs_uses_null_delimiter',
]


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


def dex_root():
    return os.environ.get('DEX_DIR') or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def apply_literal_variables(value, variables=None):
    if not variables:
        return value
    for name, replacement in variables.items():
        escaped = re.escape(name)
        pattern = re.compile(r'\$\{' + escaped + r'((?::?[-=?+])([^}]*))?\}')

        def replace_parameter(match):
            expansion = match.group(1) or ''
            word = match.group(2) or ''
            if expansion.startswith(':+') or expansion.startswith('+'):
                return word
            return replacement

        value = pattern.sub(replace_parameter, value)
        value = re.sub(r'\$' + escaped + r'(?=\W|$)', lambda _match: replacement, value)
    return value


def apply_parameter_expansion_defaults(value):
    pattern = re.compile(r'\$\{[A-Za-z_][A-Za-z0-9_]*((?::?[-=+]))([^}]*)\}')

    def replace_parameter(match):
        operator = match.group(1) or ''
        word = match.group(2) or ''
        if operator in {'-', ':-', '=', ':=', '+', ':+'}:
            return word
        return match.group(0)

    return pattern.sub(replace_parameter, value)


def resolve_shell_path(path, variables=None, cwd=None):
    root = dex_root()
    path = apply_literal_variables(path, variables)
    path = re.sub(r'\$\{DEX_DIR:-[^}]*\}', root, path)
    path = path.replace('${DEX_DIR}', root).replace('$DEX_DIR', root)
    path = apply_parameter_expansion_defaults(path)
    path = os.path.expanduser(os.path.expandvars(path))
    if '$' in path or '`' in path:
        return ''
    if os.path.isabs(path):
        return os.path.abspath(path)
    return os.path.abspath(os.path.join(cwd or os.getcwd(), path))


def is_dex_codex_wrapper(path, variables=None, cwd=None):
    resolved = resolve_shell_path(path, variables, cwd)
    if not resolved:
        return False
    expected = os.path.abspath(os.path.join(dex_root(), 'bin', 'dxcodex.sh'))
    return os.path.realpath(resolved) == os.path.realpath(expected)


def shell_file_body_status(path, variables=None, cwd=None):
    if is_dex_codex_wrapper(path, variables, cwd):
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
        if command_position and base in ASSIGNMENT_BUILTINS:
            index += 1
            while index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
                token = tokens[index]
                if token == '--':
                    index += 1
                    continue
                if token.startswith('-') and not is_shell_assignment(token):
                    index += 1
                    continue
                if is_shell_assignment(token):
                    name, value = assignment_parts(token)
                    if name and value and value != '$' and '$(' not in value and '`' not in value:
                        variables[name] = apply_literal_variables(value, variables)
                    index += 1
                    continue
                break
            command_position = False
            continue
        command_position = False
        index += 1
    return variables


def shell_assignment_literal_pair(token):
    name, value = assignment_parts(token)
    if name and value and value != '$' and '$(' not in value and '`' not in value:
        return name, value
    return None, None


def shell_wrapper_variables(tokens, start_index, command_index, variables=None):
    merged = dict(variables or {})
    index = start_index
    while index < command_index:
        token = tokens[index]
        if is_shell_assignment(token):
            name, value = shell_assignment_literal_pair(token)
            if name:
                merged[name] = apply_literal_variables(value, merged)
            index += 1
            continue
        base = token_basename(token)
        if base == 'env':
            index += 1
            while index < command_index and tokens[index] not in SHELL_SEPARATORS:
                token = tokens[index]
                if token == '--':
                    index += 1
                    break
                if is_shell_assignment(token):
                    name, value = shell_assignment_literal_pair(token)
                    if name:
                        merged[name] = apply_literal_variables(value, merged)
                    index += 1
                    continue
                if token.startswith('-'):
                    needs_value = token in ENV_OPTION_ARGS or token_takes_value(token, ENV_OPTION_ARGS)
                    index += 1
                    if needs_value and index < command_index:
                        index += 1
                    continue
                break
            continue
        index += 1
    return merged


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
EVAL_COMMANDS = {'eval'}
SOURCE_COMMANDS = {'source', '.'}
ASSIGNMENT_BUILTINS = {'export', 'readonly', 'declare', 'typeset', 'local'}
DIRECT_SHELL_RUNNERS = {'npx', 'bunx', 'uvx'}
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
RUNNER_VALUE_OPTIONS = {
    '-c', '--call', '-p', '--package', '--cache', '--userconfig',
    '--registry', '--scope', '--workspace',
}
RUNNER_SHELL_VALUE_OPTIONS = {'-c', '--call'}
NICE_VALUE_OPTIONS = {'-n', '--adjustment'}
TIMEOUT_VALUE_OPTIONS = {'-k', '--kill-after', '-s', '--signal'}
# Wrappers that take their own options and then run the rest as a command,
# mapped to the options of theirs that take a separate value. Unknown to the
# scanner, a wrapper hides everything after it: `stdbuf -oL <anything>` was
# read as a command named `stdbuf` and looked at no further.
PREFIX_WRAPPER_VALUE_OPTIONS = {
    'stdbuf': {'-i', '--input', '-o', '--output', '-e', '--error'},
    'setsid': set(),
    'unbuffer': set(),
}
# Options whose argument is required and therefore separate. `--replace` is
# absent on purpose: its argument is optional, so treating it as required made
# the option scanners skip the token after it — which is how `xargs --replace
# -0 …` hid its own NUL delimiter.
XARGS_VALUE_OPTIONS = {
    '-a', '--arg-file', '-d', '--delimiter', '-E', '--eof', '-I',
    '-L', '--max-lines', '-n', '--max-args', '-P', '--max-procs',
    '-s', '--max-chars',
}
XARGS_REPLACEMENT_OPTIONS = {'-I', '--replace'}
UNKNOWN_SHELL_STDIN = object()
SHELL_SCRIPT_VALUE_OPTIONS = {'--init-file', '--rcfile', '-O', '-D'}
SHELL_VARIABLE_WORD_RE = re.compile(r'^\s*(?:\$\{[A-Za-z_][A-Za-z0-9_]*\}|\$[A-Za-z_][A-Za-z0-9_]*)\s*$')
SHELL_LEADING_VARIABLE_RE = re.compile(r'^\s*(?:\$\{[A-Za-z_][A-Za-z0-9_]*\}|\$[A-Za-z_][A-Za-z0-9_]*)(?:\s|$)')
SHELL_VARIABLE_REF_RE = re.compile(r'\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))')
PYTHON_VALUE_OPTIONS = {'-c', '-m', '-W', '-X', '--check-hash-based-pycs'}
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
    expanded = apply_parameter_expansion_defaults(expanded)
    expanded = decode_ansi_c_token(expanded)
    if SHELL_LEADING_VARIABLE_RE.match(expanded):
        return UNKNOWN_SHELL_STDIN
    return expanded


def expand_literal_output_token(token, variables=None):
    expanded = apply_literal_variables(token, variables)
    expanded = apply_parameter_expansion_defaults(expanded)
    expanded = decode_ansi_c_token(expanded)
    if SHELL_VARIABLE_WORD_RE.match(expanded):
        return UNKNOWN_SHELL_STDIN
    return expanded


def expand_shell_command_token(token, variables=None):
    if '$(' in token or '`' in token:
        return UNKNOWN_SHELL_STDIN
    expanded = apply_literal_variables(token, variables)
    expanded = apply_parameter_expansion_defaults(expanded)
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


def execution_call_regions(code):
    """Return the argument text of each process-launch call in `code`."""
    regions = []
    for match in CODE_EXECUTION_RE.finditer(code):
        opening = code.find('(', max(match.end() - 1, 0), match.end() + 200)
        if opening == -1:
            continue
        depth = 0
        index = opening
        limit = min(len(code), opening + 20000)
        while index < limit:
            char = code[index]
            if char == '(':
                depth += 1
            elif char == ')':
                depth -= 1
                if depth == 0:
                    regions.append(code[opening + 1:index])
                    break
            index += 1
    return regions


# Suffix joins model a payload whose command starts mid-argument-vector
# (["helper", "rm", "-rf", "/"]). Uncapped, a call with many string arguments
# expanded into quadratic re-parsed content, which let an ordinary
# `python3 <file>` run past the evaluation budget and be denied.
#
# The cap is where a real command stops being modelled, so it is a coverage
# limit as much as a budget one. Measured on a file of 640 launch calls: 16
# costs 0.59s and misses a verb past argv index 16; 32 costs 0.97s and reaches
# index 24; 64 costs 1.74s and reaches past 32; 128 costs 2.06s, which trips
# the 2s budget and denies the file outright. 32 is the most coverage that
# leaves real headroom — the budget is wall clock, so a loaded machine eats
# what is left. Reaching further wants a cheaper model than joining every
# suffix: only suffixes beginning with a command worth checking need joining.
CODE_FRAGMENT_SUFFIX_JOINS = 32


def fragment_region_candidates(fragments):
    """Candidate command strings for one process-launch call's fragments.

    A fragment that opens with a shell separator cannot execute — bash rejects
    a leading |, ; or & as a syntax error — so scanning it can only produce
    false positives. Markdown table rows inside string literals were reaching
    the command-position scanner this way and failing closed on their inline
    backtick spans.
    """
    candidates = [
        fragment for fragment in fragments
        if (len(fragments) == 1 or re.search(r'[\s;&|()]', fragment))
        and not re.match(r'\s*[|;&]', fragment)
    ]
    if len(fragments) > 1:
        candidates.append(' '.join(shlex.quote(fragment) for fragment in fragments))
        for start in range(1, min(len(fragments), CODE_FRAGMENT_SUFFIX_JOINS + 1)):
            candidates.append(' '.join(shlex.quote(fragment) for fragment in fragments[start:]))
    return candidates


def code_execution_fragments(code, whole_file=False):
    code_without_strings = code_without_string_literals(code)
    exec_operator_fragments = [
        fragment for fragment in ruby_perl_exec_fragments(code) if fragment.strip()
    ]
    if (
        not CODE_EXECUTION_RE.search(code_without_strings)
        and not re.search(r'\b(?:system|exec)\s*(?:["\']|%w|\bqw\b)', code)
        and not exec_operator_fragments
    ):
        return []
    if whole_file:
        # For a whole script file, only literals passed to a process-launch
        # call are candidate commands. Treating every literal in the file as
        # one blocks any script that merely stores command-like strings — a
        # guard's own pattern table, a test fixture, a help message.
        literal_sources = execution_call_regions(code)
    else:
        # Inline code (-c/-e) is itself the payload, so scan all of it.
        literal_sources = [code]
    # Joining fragments per launch call, not across the whole file, keeps the
    # candidate set proportional to the code: cross-call joins never modeled a
    # runnable command, and they made this scan quadratic.
    executable_fragments = []
    for source in literal_sources:
        fragments = [
            fragment for fragment in (
                quoted_string_fragments(source)
                + joined_string_fragments(source)
                + adjacent_string_fragments(source)
                + word_array_fragments(source)
            )
            if fragment.strip()
        ]
        executable_fragments.extend(fragment_region_candidates(fragments))
    executable_fragments.extend(fragment_region_candidates(exec_operator_fragments))
    return executable_fragments


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
            if in_double and index + 1 < len(text) and text[index + 1] not in '$`"\\\n':
                word.append(char)
                index += 1
                continue
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


def runner_command_end(tokens, command_index):
    index = command_index + 1
    while index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
        index += 1
    return index


def is_supported_runner_command(tokens, command_index, command_end):
    command_base = token_basename(tokens[command_index])
    if command_base in DIRECT_SHELL_RUNNERS:
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
        if token == '--replace':
            # Its argument is optional and defaults to `{}`. Taking the next
            # token as the replacement swallowed the command being run.
            replacement = '{}'
            index += 1
            continue
        if token == '-i' or (token.startswith('-i') and not token.startswith('--')):
            # GNU's deprecated spelling of --replace. Its argument is optional
            # and attached; unrecognised, the command read as one with no
            # replacement at all and was judged by the wrong branch.
            replacement = token[2:] or '{}'
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


def replace_xargs_placeholders(command_tokens, replacement, value):
    if not replacement:
        return command_tokens
    if value is UNKNOWN_SHELL_STDIN:
        return UNKNOWN_SHELL_STDIN
    if not value:
        return command_tokens
    replaced = []
    index = 0
    while index < len(command_tokens):
        # xargs substitutes the item as one argument; it does not re-parse it.
        # Splitting it here turned `python3 -c '<source>'` into a row of loose
        # tokens, so the checks that read an interpreter's payload saw nothing.
        if replacement == '{}' and command_tokens[index:index + 2] == ['{', '}']:
            replaced.append(value)
            index += 2
            continue
        token = command_tokens[index]
        if token == replacement:
            replaced.append(value)
        elif replacement in token:
            replaced.append(token.replace(replacement, value))
        else:
            replaced.append(token)
        index += 1
    return replaced


def xargs_uses_null_delimiter(tokens, command_index):
    index = command_index + 1
    while index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
        token = tokens[index]
        if token == '--':
            index += 1
            break
        if token in {'-0', '--null'}:
            return True
        if short_option_has_attached_value(token, {'-a', '-d', '-E', '-I', '-L', '-n', '-P', '-s'}):
            index += 1
            continue
        if token.startswith('--delimiter=') and token.split('=', 1)[1] in {'\\0', '0'}:
            return True
        if token == '-d' or token == '--delimiter':
            if index + 1 < len(tokens) and tokens[index + 1] in {'\\0', '0'}:
                return True
            index += 2 if index + 1 < len(tokens) else 1
            continue
        if token.startswith('-'):
            needs_value = token in XARGS_VALUE_OPTIONS or token_takes_value(token, XARGS_VALUE_OPTIONS)
            index += 1
            if needs_value and index < len(tokens):
                index += 1
            continue
        break
    return False


def xargs_stdin_tokens(stdin_text, null_delimited=False, by_line=False):
    """Input items, split the way xargs itself would.

    `by_line` is what a replacement option asks for: with `-I`, blanks stop
    separating items and each line is one item. Splitting on whitespace there
    turned a line like a whole command into a handful of harmless words.
    """
    if not stdin_text:
        return []
    if null_delimited:
        values = [value for value in stdin_text.split('\0') if value]
        return values
    if by_line:
        # xargs strips an item's leading and trailing blanks before
        # substituting it, so a line of `  /` is the target `/`. Keeping the
        # blanks made the value stop matching anything once substitution began
        # inserting it whole — an indented list is enough to hide a target.
        stripped = (line.strip() for line in stdin_text.splitlines())
        return [line for line in stripped if line]
    try:
        return shlex.split(stdin_text)
    except ValueError:
        return stdin_text.split()


def xargs_splits_items_on_blanks(tokens, command_index):
    """Whether blanks still separate items despite a replacement option.

    A replacement normally makes each line one item, but `-n`/`--max-args`
    overrides that and blanks separate again: `echo 'safe /' | xargs -n1 -I{}`
    runs twice, the second time with `/`. Reading that line as one item is how
    a target hides in plain sight.
    """
    index = command_index + 1
    while index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
        token = tokens[index]
        if token == '--':
            break
        if token in {'-n', '--max-args'} or token.startswith('--max-args='):
            return True
        if short_option_has_attached_value(token, {'-n'}):
            return True
        index += 1
    return False


def find_exec_commands(tokens, command_index):
    commands = []
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
            if (
                command_index < len(tokens)
                and token_basename(tokens[command_index]) in SHELLS
                and not shell_invocation_is_noexec(tokens, command_index)
            ):
                script = shell_script_arg(tokens, command_index)
                if script:
                    script_vars = shell_wrapper_variables(tokens, index, command_index, variables)
                    scripts.append(expand_executable_script(script, script_vars))
            while index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
                index += 1
            command_position = False
            continue
        command_position = False
        index += 1
    return scripts


def shell_invocation_is_noexec(tokens, shell_index):
    """Return True when a shell is invoked in no-execute (syntax-check) mode.

    `bash -n file.sh` and `zsh -n dx.sh` read their input and exit without
    running any of it, so neither the script body nor a -c payload can launch
    anything. Without this, syntax checks are blocked purely for mentioning a
    pattern the detectors look for.

    Later flags win, so `bash -n +n script.sh` is executing and stays guarded.
    Anything unrecognized ends the scan and leaves the invocation guarded.
    """
    noexec = False
    index = shell_index + 1
    while index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
        token = tokens[index]
        if token == '--':
            break
        if token in {'-o', '+o'}:
            if index + 1 < len(tokens) and tokens[index + 1] == 'noexec':
                noexec = token == '-o'
                index += 2
                continue
            index += 2
            continue
        if len(token) > 1 and token[0] in '-+' and token[1] != '-':
            flags = token[1:]
            if 'n' in flags:
                noexec = token[0] == '-'
            if 'c' in flags:
                # -c consumes the command string; option parsing ends here.
                break
            index += 1
            continue
        if token.startswith('--'):
            index += 1
            continue
        break
    return noexec


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
    if index < len(tokens):
        token = tokens[index]
        match = INLINE_DOLLAR_SUB_RE.match(token)
        if match:
            return shell_tokens(match.group(1)), index
        match = INLINE_BACKTICK_SUB_RE.match(token)
        if match:
            return shell_tokens(match.group(1)), index

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
    """Command a substitution resolves to, its end index, and the words after it.

    The shell word-splits the output of a substitution in command position, so
    `$(echo 'rm -rf /')` runs `rm` with `-rf /`. Returning only the first word
    dropped exactly the arguments that decide whether the command is
    destructive, and a bare `rm` is not.
    """
    body_tokens, end_index = command_substitution_body_tokens(tokens, index)
    if body_tokens is None:
        return None, None, []
    output = literal_command_substitution_body_output(body_tokens, variables, cwd)
    if output is UNKNOWN_SHELL_STDIN:
        return UNKNOWN_SHELL_STDIN, end_index, []
    output_tokens = shell_tokens(output)
    if not output_tokens:
        return '', end_index, []
    return output_tokens[0], end_index, output_tokens[1:]


def command_segment_end(tokens, index):
    while index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
        index += 1
    return index


def command_substitution_resolved_invocation(tokens, index, variables=None, cwd=None):
    command_token, end_index, output_args = command_substitution_literal_command_token(
        tokens, index, variables, cwd)
    if end_index is None:
        return None

    segment_end = command_segment_end(tokens, end_index + 1)
    # The substitution's own trailing words come first: they are closer to the
    # command than anything written after the substitution on the line.
    args = output_args + tokens[end_index + 1:segment_end]
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
            payloads.append((kind, payload, False))
            return payloads
        if token == '-':
            if '<<' in tokens[command_index:command_end]:
                return payloads
            stdin_script = shell_stdin_literal(tokens, command_index, command_start, variables, cwd)
            payloads.append((kind, stdin_script if stdin_script else UNKNOWN_SHELL_STDIN, False))
            return payloads
        if kind == 'python' and token == '-m':
            return payloads
        if token.startswith('-'):
            needs_value = interpreter_option_takes_value(kind, token)
            index += 1
            if needs_value and index < command_end:
                index += 1
            continue
        payloads.append((kind, interpreter_script_body(token, generated_scripts, variables, cwd), True))
        return payloads

    stdin_script = shell_stdin_literal(tokens, command_index, command_start, variables, cwd)
    if stdin_script:
        payloads.append((kind, stdin_script, False))
    elif stdin_script is UNKNOWN_SHELL_STDIN:
        payloads.append((kind, UNKNOWN_SHELL_STDIN, False))
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

        if base in PREFIX_WRAPPER_VALUE_OPTIONS:
            value_options = PREFIX_WRAPPER_VALUE_OPTIONS[base]
            index += 1
            while index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
                token = tokens[index]
                if token == '--':
                    index += 1
                    break
                if token.startswith('-'):
                    needs_value = token in value_options or token_takes_value(token, value_options)
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
