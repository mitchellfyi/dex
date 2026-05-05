#!/usr/bin/env bash
# PostToolUse hook (Bash) — validates commits after creation
# Checks conventional commit format, then delegates to guard-handler.py
# for markdown-based guard evaluation.
set -euo pipefail

__dk_post_commit_hook_field() {
  local raw="$1" field="$2"
  [[ -n "$raw" ]] || return 1
  DK_HOOK_RAW="$raw" python3 - "$field" <<'PY'
import json
import os
import sys

field = sys.argv[1]
try:
    payload = json.loads(os.environ.get("DK_HOOK_RAW", ""))
except Exception:
    sys.exit(1)

if field == "command":
    value = payload.get("tool_input", {}).get("command", "")
elif field == "exit_code":
    response = payload.get("tool_response", {})
    value = response.get("exit_code", response.get("status", ""))
else:
    value = ""

if value is None:
    sys.exit(1)
print(value)
PY
}

__dk_post_commit_is_json_payload() {
  local raw="$1"
  [[ -n "$raw" ]] || return 1
  DK_HOOK_RAW="$raw" python3 - <<'PY'
import json
import os
import sys

try:
    json.loads(os.environ.get("DK_HOOK_RAW", ""))
except Exception:
    sys.exit(1)
sys.exit(0)
PY
}

__dk_post_commit_is_git_commit() {
  local command_text="$1"
  DK_HOOK_COMMAND="$command_text" python3 - <<'PY'
import os
import re
import shlex
import shutil
import sys

SEPARATORS = {';', ';;', ';&', ';;&', '&', '&&', '|', '||', '(', ')', '{', '}', '{}'}
REDIRECTS = {'<', '<<', '<<<', '>', '>>', '<>'}
COMMAND_KEYWORDS = {'if', 'then', 'elif', 'else', 'while', 'until', 'do', '!', '{'}
END_KEYWORDS = {'fi', 'done', 'esac', '}'}
WRAPPERS = {'command', 'builtin'}
ENV_OPTION_ARGS = {'-u', '--unset', '-C', '--chdir', '-S', '--split-string'}
SUDO_OPTION_ARGS = {
    '-A', '-a', '-b', '-C', '-c', '-D', '-g', '-h', '-p', '-R', '-r', '-T', '-t', '-U', '-u',
    '--askpass', '--background', '--chdir', '--close-from', '--group', '--host',
    '--prompt', '--role', '--type', '--user',
}
TIME_OPTION_ARGS = {'-f', '--format', '-o', '--output'}
TIME_FLAGS = {'-p', '-l', '-a', '--append', '-v', '--verbose', '--quiet'}
SHELLS = {'bash', 'sh', 'zsh', 'dash', 'ksh'}
EVALS = {'eval'}
SOURCES = {'source', '.'}
GIT_OPTION_ARGS = {
    '-C', '-c', '--config-env', '--exec-path', '--git-dir', '--work-tree',
    '--namespace', '--super-prefix',
}
GIT_COMMIT_NO_CREATE_OPTIONS = {
    '--dry-run', '--short', '--porcelain', '--long', '-z', '--null',
    '--help', '-h',
}
HEREDOC_RE = re.compile(r"<<-?\s*('([^']+)'|\"([^\"]+)\"|\\?([A-Za-z_][A-Za-z0-9_]*))")
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
DIRECT_SHELL_RUNNERS = {'npx', 'bunx', 'uvx'}
PACKAGE_MANAGER_RUNNERS = {
    'npm': {'exec', 'x'},
    'pnpm': {'dlx', 'exec', 'x'},
    'yarn': {'dlx', 'exec'},
}
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
    parts = tokens(first_line[2:])
    if not parts:
        return ''
    name = base(parts[0])
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
            name = base(token)
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


def code_git_commit_target(code, cwd, depth=0):
    if code is UNKNOWN_SHELL_STDIN:
        return None
    if depth > 24:
        return None
    if not code or not code.strip():
        return None
    for fragment in code_execution_fragments(code):
        target = has_git_commit(fragment, cwd, depth + 1)
        if target:
            return target
    return None


def executable_script_git_commit_target(script_body, cwd, depth=0, kind=''):
    if script_body is UNKNOWN_SHELL_STDIN:
        return None
    if not script_body:
        return None
    target = has_git_commit(script_body, cwd, depth + 1)
    if target:
        return target
    script_kind = kind or shebang_interpreter_kind(script_body)
    return code_git_commit_target(script_body, cwd, depth + 1) if script_kind else None


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
    text = '\n'.join(line for line in text.splitlines() if not line.lstrip().startswith('#'))
    text = text.replace('\n', ' ; ')
    parsed = []
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
                parsed.append(''.join(word))
                word = []
            index += 1
            continue
        if not in_single and not in_double and char in punctuation:
            if word:
                parsed.append(''.join(word))
                word = []
            start = index
            while index < len(text) and text[index] in punctuation:
                index += 1
            parsed.append(text[start:index])
            continue
        word.append(char)
        index += 1
    if word:
        parsed.append(''.join(word))
    return normalize(parsed)


def tokens(text):
    text = '\n'.join(line for line in text.splitlines() if not line.lstrip().startswith('#'))
    lexer = shlex.shlex(text.replace('\n', ' ; '), posix=True, punctuation_chars=';&|()<>')
    lexer.whitespace_split = True
    try:
        return normalize(list(lexer))
    except ValueError:
        return normalize(
            text.replace(';', ' ; ')
            .replace('|', ' | ')
            .replace('&', ' & ')
            .replace('<', ' < ')
            .replace('>', ' > ')
            .split()
        )


def normalize(parts):
    normalized = []
    punct = set(';&|(){}<>')
    multi = {'&&', '||', ';;', ';&', ';;&', '<<', '<<<', '>>', '<>', '<(', '>('}
    for token in parts:
        if len(token) > 1 and set(token) <= punct and token not in multi:
            normalized.extend(token)
        else:
            normalized.append(token)
    return normalized


def extract_backticks(text):
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


def extract_dollars(text):
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


def strip_heredoc_bodies(text):
    output = []
    substitutions = []
    executable_bodies = []
    pending = []
    for raw_line in text.splitlines(keepends=True):
        line = raw_line.rstrip('\r\n')
        if pending:
            current = pending[0]
            delimiter, strip_tabs, quoted = current['delimiter'], current['strip_tabs'], current['quoted']
            comparable = line.lstrip('\t') if strip_tabs else line
            if comparable == delimiter:
                if current['receiver_shell']:
                    executable_bodies.append(''.join(current['body']))
                pending.pop(0)
                continue
            current['body'].append(raw_line)
            if not quoted:
                substitutions.extend(extract_backticks(raw_line))
                substitutions.extend(extract_dollars(raw_line))
            continue
        output.append(raw_line)
        receiver_shell = heredoc_receiver_is_shell(raw_line)
        for match in HEREDOC_RE.finditer(raw_line):
            operator = match.group(0)
            delimiter = match.group(2) or match.group(3) or match.group(4) or ''
            if not delimiter:
                continue
            pending.append({
                'delimiter': delimiter,
                'strip_tabs': operator.startswith('<<-'),
                'quoted': bool(match.group(2) or match.group(3)),
                'receiver_shell': receiver_shell,
                'body': [],
            })
    for current in pending:
        if current['receiver_shell']:
            executable_bodies.append(''.join(current['body']))
    return ''.join(output), substitutions, executable_bodies


def base(token):
    return os.path.basename(token.strip('`"\''))


def apply_literal_variables(value, variables=None):
    if not variables:
        return value
    for name, replacement in variables.items():
        escaped = re.escape(name)
        value = re.sub(r'\$\{' + escaped + r'\}', lambda _match: replacement, value)
        value = re.sub(r'\$\{' + escaped + r':-[^}]*\}', lambda _match: replacement, value)
        value = re.sub(r'\$' + escaped + r'(?=\W|$)', lambda _match: replacement, value)
    return value


def resolve_shell_token(cwd, path, variables=None):
    path = apply_literal_variables(path, variables)
    doyaken_dir = os.environ.get('DOYAKEN_DIR', '')
    path = re.sub(r'\$\{DOYAKEN_DIR:-[^}]*\}', doyaken_dir, path)
    path = path.replace('${DOYAKEN_DIR}', os.environ.get('DOYAKEN_DIR', ''))
    path = path.replace('$DOYAKEN_DIR', os.environ.get('DOYAKEN_DIR', ''))
    path = os.path.expanduser(os.path.expandvars(path))
    if '$' in path or '`' in path:
        return ''
    return resolve_dir(cwd, path)


def read_shell_file(cwd, path, variables=None):
    resolved = resolve_shell_token(cwd, path, variables)
    if not resolved:
        return ''
    try:
        with open(resolved, 'r', encoding='utf-8', errors='replace') as f:
            body = f.read(1024 * 1024)
            return '' if '\x00' in body else body
    except OSError:
        return ''


def downstream_pipeline_has_shell(parts, pipe_index):
    index = pipe_index
    command_position = False
    while index < len(parts):
        token = parts[index]
        if token == '|':
            command_position = True
            index += 1
            continue
        if token in SEPARATORS:
            return False
        if command_position:
            command_index = skip_prefix(parts, index)
            if command_index < len(parts) and base(parts[command_index]) in SHELLS.union(EVALS):
                return True
            while index < len(parts) and parts[index] not in SEPARATORS:
                index += 1
            command_position = False
            continue
        index += 1
    return False


def heredoc_receiver_is_shell(line):
    parts = tokens(line)
    command_position = True
    index = 0
    while index < len(parts):
        token = parts[index]
        name = base(token)
        if token in SEPARATORS:
            command_position = True
            index += 1
            continue
        if name in COMMAND_KEYWORDS:
            command_position = True
            index += 1
            continue
        if name in END_KEYWORDS or name in {'for', 'select', 'case', 'in'}:
            command_position = False
            index += 1
            continue
        if command_position:
            command_index = skip_prefix(parts, index)
            segment_end = command_index
            while segment_end < len(parts) and parts[segment_end] not in SEPARATORS:
                segment_end += 1
            has_heredoc = '<<' in parts[command_index:segment_end]
            if has_heredoc and command_index < len(parts):
                if base(parts[command_index]) in SHELLS.union(EVALS):
                    return True
                if segment_end < len(parts) and parts[segment_end] == '|' and downstream_pipeline_has_shell(parts, segment_end):
                    return True
            index = segment_end
            command_position = False
            continue
        command_position = False
        index += 1
    return False


def assignment(token):
    return re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', token) is not None


def assignment_parts(token):
    match = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)=(.*)$', token)
    if not match:
        return None, None
    return match.group(1), match.group(2)


def assignment_end(parts, index):
    if index >= len(parts) or not assignment(parts[index]):
        return index
    value = assignment_parts(parts[index])[1] or ''
    if '$(' in value:
        depth = value.count('$(') + value.count('(') - value.count(')')
        cursor = index + 1
        while cursor < len(parts) and depth > 0:
            depth += parts[cursor].count('(')
            depth -= parts[cursor].count(')')
            cursor += 1
        return cursor
    if '`' in value and value.count('`') % 2 == 1:
        cursor = index + 1
        while cursor < len(parts):
            if '`' in parts[cursor]:
                return cursor + 1
            cursor += 1
        return cursor
    return index + 1


def collect_literal_variables(parts):
    variables = {}
    command_position = True
    index = 0
    while index < len(parts):
        token = parts[index]
        name = base(token)
        if token in SEPARATORS:
            command_position = True
            index += 1
            continue
        if name in COMMAND_KEYWORDS:
            command_position = True
            index += 1
            continue
        if name in END_KEYWORDS or name in {'for', 'select', 'case', 'in'}:
            command_position = False
            index += 1
            continue
        if command_position and assignment(token):
            var_name, value = assignment_parts(token)
            if var_name and value and value != '$' and '$(' not in value and '`' not in value:
                variables[var_name] = value
            index += 1
            continue
        command_position = False
        index += 1
    return variables


def takes_value(token, value_options):
    if token in value_options:
        return True
    if '=' in token and token.split('=', 1)[0] in value_options:
        return False
    return len(token) == 2 and token in value_options


def short_option_has_attached_value(token, options):
    return len(token) > 2 and token[:2] in options


def skip_prefix(parts, index):
    while index < len(parts):
        while index < len(parts) and assignment(parts[index]):
            index += 1
        if index >= len(parts):
            return index
        name = base(parts[index])
        if name == 'command':
            index += 1
            while index < len(parts) and parts[index] not in SEPARATORS:
                token = parts[index]
                if token == '--':
                    index += 1
                    break
                if token.startswith('-') and len(token) > 1 and all(ch in 'pVv' for ch in token[1:]):
                    if 'v' in token[1:] or 'V' in token[1:]:
                        while index < len(parts) and parts[index] not in SEPARATORS:
                            index += 1
                        return index
                    index += 1
                    continue
                break
            continue
        if name == 'builtin':
            index += 1
            if index < len(parts) and parts[index] == '--':
                index += 1
            continue
        if name == 'exec':
            index += 1
            while index < len(parts) and parts[index] not in SEPARATORS:
                token = parts[index]
                if token == '--':
                    index += 1
                    break
                if token in {'-a', '-c'}:
                    index += 2 if index + 1 < len(parts) else 1
                    continue
                if token == '-l':
                    index += 1
                    continue
                break
            continue
        if name == 'env':
            if index + 1 < len(parts) and (
                parts[index + 1] in {'-S', '--split-string'} or parts[index + 1].startswith('--split-string=')
            ):
                break
            index += 1
            while index < len(parts) and parts[index] not in SEPARATORS:
                token = parts[index]
                if token == '--':
                    index += 1
                    break
                if assignment(token):
                    index += 1
                    continue
                if token.startswith('-'):
                    needs_value = token in ENV_OPTION_ARGS or takes_value(token, ENV_OPTION_ARGS)
                    index += 1
                    if needs_value and index < len(parts):
                        index += 1
                    continue
                break
            continue
        if name in {'time', 'nohup'}:
            index += 1
            while index < len(parts) and parts[index] not in SEPARATORS:
                token = parts[index]
                if token == '--':
                    index += 1
                    break
                if name == 'time' and token in TIME_FLAGS:
                    index += 1
                    continue
                if name == 'time' and (token in TIME_OPTION_ARGS or takes_value(token, TIME_OPTION_ARGS)):
                    index += 1
                    if index < len(parts):
                        index += 1
                    continue
                break
            continue
        if name == 'nice':
            index += 1
            while index < len(parts) and parts[index] not in SEPARATORS:
                token = parts[index]
                if token == '--':
                    index += 1
                    break
                if re.match(r'^-\d+$', token):
                    index += 1
                    continue
                if token.startswith('-'):
                    needs_value = token in NICE_VALUE_OPTIONS or takes_value(token, NICE_VALUE_OPTIONS)
                    index += 1
                    if needs_value and index < len(parts):
                        index += 1
                    continue
                break
            continue
        if name in {'timeout', 'gtimeout'}:
            index += 1
            while index < len(parts) and parts[index] not in SEPARATORS:
                token = parts[index]
                if token == '--':
                    index += 1
                    break
                if token.startswith('-'):
                    needs_value = token in TIMEOUT_VALUE_OPTIONS or takes_value(token, TIMEOUT_VALUE_OPTIONS)
                    index += 1
                    if needs_value and index < len(parts):
                        index += 1
                    continue
                break
            if index < len(parts) and parts[index] not in SEPARATORS:
                index += 1
            continue
        if name in {'sudo', 'doas'}:
            index += 1
            while index < len(parts) and parts[index] not in SEPARATORS:
                token = parts[index]
                if assignment(token):
                    index += 1
                    continue
                if token == '--':
                    index += 1
                    break
                if token.startswith('-'):
                    needs_value = token in SUDO_OPTION_ARGS or takes_value(token, SUDO_OPTION_ARGS)
                    index += 1
                    if needs_value and index < len(parts):
                        index += 1
                    continue
                break
            continue
        return index
    return index


def shell_script_arg(parts, shell_index):
    index = shell_index + 1
    while index < len(parts) and parts[index] not in SEPARATORS:
        token = parts[index]
        if token == '--':
            index += 1
            continue
        if token in {'-c', '--command'}:
            return ' '.join(parts[index + 1:]) if index + 1 < len(parts) else ''
        if token.startswith('-') and not token.startswith('--') and 'c' in token[1:]:
            return ' '.join(parts[index + 1:]) if index + 1 < len(parts) else ''
        index += 1
    return ''


def shell_c_scripts(text, variables=None):
    parts = shell_word_tokens(text)
    if variables is None:
        variables = collect_literal_variables(parts)
    scripts = []
    command_position = True
    index = 0
    while index < len(parts):
        token = parts[index]
        name = base(token)
        if token in SEPARATORS:
            command_position = True
            index += 1
            continue
        if name in COMMAND_KEYWORDS:
            command_position = True
            index += 1
            continue
        if name in END_KEYWORDS or name in {'for', 'select', 'case', 'in'}:
            command_position = False
            index += 1
            continue
        if command_position:
            command_index = skip_prefix(parts, index)
            if command_index < len(parts) and base(parts[command_index]) in SHELLS:
                script = shell_script_arg(parts, command_index)
                if script:
                    scripts.append(expand_executable_script(script, variables))
            while index < len(parts) and parts[index] not in SEPARATORS:
                index += 1
            command_position = False
            continue
        command_position = False
        index += 1
    return scripts


def skip_runner_options(parts, index):
    while index < len(parts):
        token = parts[index]
        if token in SEPARATORS:
            break
        if token == '--':
            index += 1
            break
        if not token.startswith('-') or token == '-':
            break
        needs_value = token in RUNNER_VALUE_OPTIONS or takes_value(token, RUNNER_VALUE_OPTIONS)
        index += 1
        if needs_value and index < len(parts):
            index += 1
    return index


def runner_command_end(parts, command_index):
    index = command_index + 1
    while index < len(parts) and parts[index] not in SEPARATORS:
        index += 1
    return index


def is_supported_runner_command(parts, command_index, command_end):
    command_name = base(parts[command_index])
    if command_name in DIRECT_SHELL_RUNNERS:
        return True
    subcommands = PACKAGE_MANAGER_RUNNERS.get(command_name)
    if not subcommands:
        return False
    index = skip_runner_options(parts, command_index + 1)
    return index < command_end and base(parts[index]) in subcommands


def runner_shell_payloads(parts, command_index, variables=None):
    command_end = runner_command_end(parts, command_index)
    if not is_supported_runner_command(parts, command_index, command_end):
        return []

    payloads = []
    index = command_index + 1
    while index < command_end:
        token = parts[index]
        if token == '--':
            break
        if token in RUNNER_SHELL_VALUE_OPTIONS:
            if index + 1 < command_end:
                payloads.append(expand_executable_script(parts[index + 1], variables))
                index += 2
                continue
            payloads.append(UNKNOWN_SHELL_STDIN)
            index += 1
            continue
        if token.startswith('--call='):
            payloads.append(expand_executable_script(token.split('=', 1)[1], variables))
        index += 1
    return payloads


def env_split_payload(parts, command_index, variables=None):
    if base(parts[command_index]) != 'env':
        return ''
    index = command_index + 1
    while index < len(parts) and parts[index] not in SEPARATORS:
        token = parts[index]
        if token == '--':
            index += 1
            break
        if assignment(token):
            index += 1
            continue
        if token == '-S' or token == '--split-string':
            if index + 1 < len(parts) and parts[index + 1] not in SEPARATORS:
                return expand_executable_script(parts[index + 1], variables)
            return UNKNOWN_SHELL_STDIN
        if token.startswith('--split-string='):
            return expand_executable_script(token.split('=', 1)[1], variables)
        if token.startswith('-'):
            needs_value = token in ENV_OPTION_ARGS or takes_value(token, ENV_OPTION_ARGS)
            index += 1
            if needs_value and index < len(parts):
                index += 1
            continue
        break
    return ''


def shell_quote_parts(parts):
    return ' '.join(shlex.quote(token) for token in parts)


def collect_aliases(parts, variables=None):
    aliases = {}
    command_position = True
    index = 0
    while index < len(parts):
        token = parts[index]
        name = base(token)
        if token in SEPARATORS:
            command_position = True
            index += 1
            continue
        if name in COMMAND_KEYWORDS:
            command_position = True
            index += 1
            continue
        if command_position:
            command_index = skip_prefix(parts, index)
            if command_index < len(parts) and base(parts[command_index]) == 'alias':
                cursor = command_index + 1
                while cursor < len(parts) and parts[cursor] not in SEPARATORS:
                    alias_name, value = assignment_parts(parts[cursor])
                    if alias_name and value:
                        aliases[alias_name] = expand_executable_script(value, variables)
                    cursor += 1
                index = cursor
                command_position = False
                continue
            while index < len(parts) and parts[index] not in SEPARATORS:
                index += 1
            command_position = False
            continue
        command_position = False
        index += 1
    return aliases


def shell_functions(parts):
    functions = {}
    index = 0
    while index < len(parts):
        name = ''
        open_index = None
        if parts[index] == 'function' and index + 2 < len(parts):
            name = parts[index + 1]
            open_index = index + 2 if parts[index + 2] == '{' else None
        elif index + 3 < len(parts) and parts[index + 1:index + 4] == ['(', ')', '{']:
            name = parts[index]
            open_index = index + 3
        if name and open_index is not None:
            depth = 1
            cursor = open_index + 1
            body = []
            while cursor < len(parts):
                if parts[cursor] == '{':
                    depth += 1
                    body.append(parts[cursor])
                elif parts[cursor] == '}':
                    depth -= 1
                    if depth == 0:
                        functions[name] = body
                        index = cursor + 1
                        break
                    body.append(parts[cursor])
                else:
                    body.append(parts[cursor])
                cursor += 1
        index += 1
    return functions


def function_definition_end(parts, index):
    open_index = None
    if index < len(parts) and parts[index] == 'function' and index + 2 < len(parts):
        open_index = index + 2 if parts[index + 2] == '{' else None
    elif index + 3 < len(parts) and parts[index + 1:index + 4] == ['(', ')', '{']:
        open_index = index + 3
    if open_index is None:
        return None
    depth = 1
    cursor = open_index + 1
    while cursor < len(parts):
        if parts[cursor] == '{':
            depth += 1
        elif parts[cursor] == '}':
            depth -= 1
            if depth == 0:
                return cursor
        cursor += 1
    return None


def xargs_command_start(parts, command_index):
    index = command_index + 1
    replacement = None
    while index < len(parts) and parts[index] not in SEPARATORS:
        token = parts[index]
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
            if index + 1 < len(parts):
                if parts[index + 1:index + 3] == ['{', '}']:
                    replacement = '{}'
                    index += 3
                else:
                    replacement = parts[index + 1]
                    index += 2
            else:
                index += 1
            continue
        if short_option_has_attached_value(token, {'-a', '-d', '-E', '-L', '-n', '-P', '-s'}):
            index += 1
            continue
        if token.startswith('-'):
            needs_value = token in XARGS_VALUE_OPTIONS or takes_value(token, XARGS_VALUE_OPTIONS)
            index += 1
            if needs_value and index < len(parts):
                index += 1
            continue
        break
    return index, replacement


def replace_xargs_placeholders(command_parts, replacement, stdin_text):
    if not replacement:
        return command_parts
    if stdin_text is UNKNOWN_SHELL_STDIN:
        return UNKNOWN_SHELL_STDIN
    value = stdin_text.strip().splitlines()[0] if stdin_text.strip() else ''
    if not value:
        return command_parts
    replaced = []
    index = 0
    while index < len(command_parts):
        if replacement == '{}' and command_parts[index:index + 2] == ['{', '}']:
            replaced.extend(tokens(value))
            index += 2
            continue
        token = command_parts[index]
        if token == replacement:
            replaced.extend(tokens(value))
        elif replacement in token:
            replaced.append(token.replace(replacement, value))
        else:
            replaced.append(token)
        index += 1
    return replaced


def xargs_commit_target(parts, command_index, command_start, cwd, variables=None, depth=0):
    if base(parts[command_index]) != 'xargs':
        return None
    command_arg_start, replacement = xargs_command_start(parts, command_index)
    xargs_separators = SEPARATORS - {'{', '}'}
    if command_arg_start >= len(parts) or parts[command_arg_start] in xargs_separators:
        return None
    command_end = command_arg_start
    while command_end < len(parts) and parts[command_end] not in xargs_separators:
        command_end += 1
    command_parts = parts[command_arg_start:command_end]
    literal_command = shell_quote_parts(command_parts)
    if replacement:
        stdin_text = shell_stdin_literal(parts, command_index, cwd, command_start, variables)
        command_parts = replace_xargs_placeholders(command_parts, replacement, stdin_text)
        if command_parts is UNKNOWN_SHELL_STDIN:
            return has_git_commit(literal_command, cwd, depth + 1)
    else:
        stdin_text = shell_stdin_literal(parts, command_index, cwd, command_start, variables)
        if stdin_text is UNKNOWN_SHELL_STDIN:
            return has_git_commit(literal_command, cwd, depth + 1)
        if stdin_text:
            command_parts.extend(tokens(stdin_text))
    return has_git_commit(shell_quote_parts(command_parts), cwd, depth + 1)


def find_exec_commands(parts, command_index):
    commands = []
    index = command_index + 1
    while index < len(parts):
        token = parts[index]
        if token in SEPARATORS and token != ';':
            break
        if token in {'-exec', '-execdir', '-ok', '-okdir'}:
            index += 1
            command = []
            while index < len(parts):
                if parts[index] in {';', '+'}:
                    break
                command.append(parts[index])
                index += 1
            if command:
                commands.append(command)
        index += 1
    return commands


def find_exec_commit_target(parts, command_index, cwd, depth=0):
    if base(parts[command_index]) != 'find':
        return None
    for command_parts in find_exec_commands(parts, command_index):
        target = has_git_commit(shell_quote_parts(command_parts), cwd, depth + 1)
        if target:
            return target
    return None


def shell_script_file_arg(parts, shell_index):
    index = shell_index + 1
    while index < len(parts) and parts[index] not in SEPARATORS:
        token = parts[index]
        if token == '--':
            index += 1
            break
        if token in {'-c', '--command'}:
            return ''
        if token.startswith('-') and not token.startswith('--') and 'c' in token[1:]:
            return ''
        if token in {'-s', '--stdin', '-'}:
            return ''
        if token in REDIRECTS:
            index += 1
            if token in {'<', '<<', '<<<'} and index < len(parts):
                index += 1
            continue
        if token.startswith('-') and token != '-':
            needs_value = token in SHELL_SCRIPT_VALUE_OPTIONS or takes_value(token, SHELL_SCRIPT_VALUE_OPTIONS)
            index += 1
            if needs_value and index < len(parts):
                index += 1
            continue
        break

    while index < len(parts) and parts[index] not in SEPARATORS:
        token = parts[index]
        if token in REDIRECTS:
            index += 1
            if token in {'<', '<<', '<<<'} and index < len(parts):
                index += 1
            continue
        if token == '-':
            return ''
        return token
    return ''


def source_script_file_arg(parts, source_index):
    index = source_index + 1
    while index < len(parts) and parts[index] not in SEPARATORS:
        token = parts[index]
        if token == '--':
            index += 1
            break
        if token.startswith('-') and token != '-':
            index += 1
            continue
        break
    if index < len(parts) and parts[index] not in SEPARATORS and parts[index] != '-':
        return parts[index]
    return ''


def process_substitution_body(parts, start_index):
    if start_index >= len(parts) or parts[start_index] not in {'<(', '>('}:
        return None
    depth = 1
    cursor = start_index + 1
    body = []
    while cursor < len(parts):
        token = parts[cursor]
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


def process_substitution_index_for_command(parts, command_index):
    index = command_index + 1
    while index < len(parts) and parts[index] not in SEPARATORS:
        if parts[index] == '<(':
            return index
        index += 1
    return None


def process_substitution_literal_output(parts, cwd, variables=None):
    if not parts:
        return ''
    command_index = skip_prefix(parts, 0)
    if command_index >= len(parts):
        return ''
    return literal_shell_input_command(parts, command_index, cwd, variables)


INLINE_DOLLAR_SUB_RE = re.compile(r'^\$\((.*)\)$', re.S)
INLINE_BACKTICK_SUB_RE = re.compile(r'^`(.*)`$', re.S)


def is_inline_command_substitution(script):
    return INLINE_DOLLAR_SUB_RE.match(script) is not None or INLINE_BACKTICK_SUB_RE.match(script) is not None


def literal_command_lookup_output(parts, producer_index):
    producer = base(parts[producer_index])
    index = producer_index + 1

    if producer == 'which':
        while index < len(parts) and parts[index] not in SEPARATORS:
            token = parts[index]
            if token == '--':
                index += 1
                break
            if token.startswith('-') and token != '-':
                index += 1
                continue
            break
        if index < len(parts) and parts[index] not in SEPARATORS:
            return shutil.which(parts[index]) or ''
        return ''

    if producer == 'command':
        lookup_mode = False
        while index < len(parts) and parts[index] not in SEPARATORS:
            token = parts[index]
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
        if lookup_mode and index < len(parts) and parts[index] not in SEPARATORS:
            return shutil.which(parts[index]) or parts[index]
        return None

    if producer in {'type', 'whence'}:
        lookup_mode = producer == 'whence'
        while index < len(parts) and parts[index] not in SEPARATORS:
            token = parts[index]
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
        if lookup_mode and index < len(parts) and parts[index] not in SEPARATORS:
            return shutil.which(parts[index]) or ''
        return None

    return None


def literal_command_substitution_body_output(body_parts, cwd, variables=None):
    command_index = 0
    if body_parts and base(body_parts[0]) == 'builtin' and len(body_parts) > 1:
        command_index = 1
    if command_index >= len(body_parts):
        return UNKNOWN_SHELL_STDIN
    lookup_output = literal_command_lookup_output(body_parts, command_index)
    if lookup_output is not None:
        return lookup_output
    return literal_shell_input_command(body_parts, command_index, cwd, variables)


def command_substitution_body_parts(parts, index):
    dollar_end = command_substitution_end(parts, index)
    if dollar_end is not None:
        return parts[index + 2:dollar_end], dollar_end

    backtick_end = backtick_substitution_end(parts, index)
    if backtick_end is None:
        return None, None
    body_parts = parts[index:backtick_end + 1]
    body_parts[0] = body_parts[0][1:]
    body_parts[-1] = body_parts[-1][:-1]
    return body_parts, backtick_end


def command_substitution_literal_command_token(parts, index, cwd, variables=None):
    body_parts, end_index = command_substitution_body_parts(parts, index)
    if body_parts is None:
        return None, None
    output = literal_command_substitution_body_output(body_parts, cwd, variables)
    if output is UNKNOWN_SHELL_STDIN:
        return UNKNOWN_SHELL_STDIN, end_index
    output_parts = tokens(output)
    if not output_parts:
        return '', end_index
    return output_parts[0], end_index


def command_segment_end(parts, index):
    while index < len(parts) and parts[index] not in SEPARATORS:
        index += 1
    return index


def command_substitution_resolved_invocation(parts, index, cwd, variables=None):
    command_token, end_index = command_substitution_literal_command_token(parts, index, cwd, variables)
    if end_index is None:
        return None
    segment_end = command_segment_end(parts, end_index + 1)
    args = parts[end_index + 1:segment_end]
    if command_token is UNKNOWN_SHELL_STDIN:
        return UNKNOWN_SHELL_STDIN, args, end_index
    if not command_token:
        return '', args, end_index
    return command_token, args, end_index


def literal_command_substitution_output(script, cwd, variables=None):
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
    body_parts = tokens(body)
    return literal_command_substitution_body_output(body_parts, cwd, variables)


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


def literal_shell_input_command(parts, producer_index, cwd, variables=None):
    producer = base(parts[producer_index])
    if producer not in {'printf', 'echo', 'cat'}:
        return UNKNOWN_SHELL_STDIN
    if producer == 'cat':
        literals = []
        index = producer_index + 1
        while index < len(parts) and parts[index] not in SEPARATORS:
            token = parts[index]
            if token == '--':
                index += 1
                continue
            if token == '<<<':
                if index + 1 >= len(parts):
                    return ''
                return expand_literal_output_token(parts[index + 1], variables)
            if token == '<<':
                return ''
            if token in REDIRECTS:
                return UNKNOWN_SHELL_STDIN
            if token.startswith('-') and token != '-':
                index += 1
                continue
            if token == '-':
                return UNKNOWN_SHELL_STDIN
            try:
                resolved = resolve_shell_token(cwd, token, variables)
                if not resolved:
                    return UNKNOWN_SHELL_STDIN
                with open(resolved, 'r', encoding='utf-8', errors='replace') as f:
                    body = f.read(1024 * 1024)
                    if '\x00' in body:
                        return UNKNOWN_SHELL_STDIN
                    literals.append(body)
            except OSError:
                return UNKNOWN_SHELL_STDIN
            index += 1
        return '\n'.join(literals) if literals else UNKNOWN_SHELL_STDIN

    if producer == 'printf':
        args = []
        index = producer_index + 1
        while index < len(parts) and parts[index] not in SEPARATORS:
            token = parts[index]
            if token == '--':
                index += 1
                continue
            if token in REDIRECTS:
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
    while index < len(parts) and parts[index] not in SEPARATORS:
        token = parts[index]
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
        if token in REDIRECTS:
            break
        expanded = expand_literal_output_token(token, variables)
        if expanded is UNKNOWN_SHELL_STDIN:
            return UNKNOWN_SHELL_STDIN
        if echo_decode_escapes:
            expanded = decode_shell_backslash_escapes(expanded)
        literals.append(expanded)
        index += 1
    return ' '.join(literals)


def tee_generated_script(parts, command_index, command_start, cwd, variables=None):
    if command_index >= len(parts):
        return '', ''
    if base(parts[command_index]) != 'tee':
        return '', ''
    script = shell_stdin_literal(parts, command_index, cwd, command_start, variables)
    target = ''
    index = command_index + 1
    while index < len(parts) and parts[index] not in SEPARATORS:
        token = parts[index]
        if token == '--':
            index += 1
            continue
        if token in {'>', '>>', '<', '<<', '<<<'}:
            index += 2 if index + 1 < len(parts) else 1
            continue
        if token.startswith('-') and token != '-':
            index += 1
            continue
        target = resolve_shell_token(cwd, token, variables)
        break
    return target, script


def shell_stdin_literal(parts, shell_index, cwd, command_start=None, variables=None):
    if command_start is None:
        command_start = shell_index
    if command_start >= 2 and parts[command_start - 1] == '|':
        producer_end = command_start - 1
        producer_start = producer_end - 1
        while producer_start >= 0 and parts[producer_start] not in SEPARATORS:
            producer_start -= 1
        producer_start += 1
        if producer_start < producer_end:
            return literal_shell_input_command(parts, producer_start, cwd, variables)

    index = shell_index + 1
    while index < len(parts) and parts[index] not in SEPARATORS:
        if parts[index] == '<<<':
            if index + 1 >= len(parts):
                return ''
            return expand_literal_output_token(parts[index + 1], variables)
        if parts[index] == '<':
            if index + 1 >= len(parts):
                return ''
            resolved = resolve_shell_token(cwd, parts[index + 1], variables)
            if not resolved:
                return UNKNOWN_SHELL_STDIN
            try:
                with open(resolved, 'r', encoding='utf-8', errors='replace') as f:
                    return f.read(1024 * 1024)
            except OSError:
                return UNKNOWN_SHELL_STDIN
        index += 1
    return ''


def downstream_pipeline_interpreter_kind(parts, pipe_index):
    index = pipe_index
    command_position = False
    while index < len(parts):
        token = parts[index]
        if token == '|':
            command_position = True
            index += 1
            continue
        if token in SEPARATORS:
            command_position = True
            index += 1
            continue
        if command_position:
            command_index = skip_prefix(parts, index)
            if command_index < len(parts):
                kind = interpreter_kind(base(parts[command_index]))
                if kind:
                    return kind
            command_position = False
        index += 1
    return ''


def heredoc_receiver_interpreter_kind(line):
    parts = tokens(line)
    command_position = True
    index = 0
    while index < len(parts):
        token = parts[index]
        name = base(token)
        if token in SEPARATORS:
            command_position = True
            index += 1
            continue
        if name in COMMAND_KEYWORDS:
            command_position = True
            index += 1
            continue
        if name in END_KEYWORDS or name in {'for', 'select', 'case', 'in'}:
            command_position = False
            index += 1
            continue
        if command_position:
            command_index = skip_prefix(parts, index)
            segment_end = command_index
            while segment_end < len(parts) and parts[segment_end] not in SEPARATORS:
                segment_end += 1
            has_heredoc = '<<' in parts[command_index:segment_end]
            if has_heredoc and command_index < len(parts):
                kind = interpreter_kind(base(parts[command_index]))
                if kind:
                    return kind
                if segment_end < len(parts) and parts[segment_end] == '|':
                    kind = downstream_pipeline_interpreter_kind(parts, segment_end)
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


def interpreter_inline_payload(kind, token, parts, index, command_end, variables=None):
    if kind == 'python':
        if token == '-c':
            if index + 1 < command_end:
                return expand_executable_script(parts[index + 1], variables), index + 2
            return UNKNOWN_SHELL_STDIN, index + 1
        return None, index

    if kind in {'node', 'ruby', 'perl'}:
        if token in {'-e', '-p', '--eval', '--print'}:
            if index + 1 < command_end:
                return expand_executable_script(parts[index + 1], variables), index + 2
            return UNKNOWN_SHELL_STDIN, index + 1
        for prefix in ('--eval=', '--print='):
            if token.startswith(prefix):
                return expand_executable_script(token.split('=', 1)[1], variables), index + 1
        if len(token) > 2 and token[:2] in {'-e', '-p'}:
            return expand_executable_script(token[2:], variables), index + 1
    return None, index


def interpreter_option_takes_value(kind, token):
    value_options = PYTHON_VALUE_OPTIONS if kind == 'python' else NODE_VALUE_OPTIONS
    return token in value_options or takes_value(token, value_options)


def interpreter_script_body(parts, script_file, cwd, generated_scripts, variables=None):
    generated_body = generated_script_for_path(generated_scripts, cwd, script_file, variables)
    if generated_body is UNKNOWN_SHELL_STDIN:
        return UNKNOWN_SHELL_STDIN
    if generated_body is not None:
        return generated_body
    return read_shell_file(cwd, script_file, variables)


def interpreter_code_payloads(parts, command_index, command_start, cwd, generated_scripts, variables=None):
    kind = interpreter_kind(base(parts[command_index]))
    if not kind:
        return []

    command_end = command_index + 1
    while command_end < len(parts) and parts[command_end] not in SEPARATORS:
        command_end += 1

    payloads = []
    index = command_index + 1
    while index < command_end:
        token = parts[index]
        if token == '--':
            index += 1
            break
        if token in REDIRECTS:
            index += 2 if token in {'<', '<<', '<<<'} and index + 1 < command_end else 1
            continue
        payload, _next_index = interpreter_inline_payload(kind, token, parts, index, command_end, variables)
        if payload is not None:
            payloads.append((kind, payload))
            return payloads
        if token == '-':
            if '<<' in parts[command_index:command_end]:
                return payloads
            stdin_script = shell_stdin_literal(parts, command_index, cwd, command_start, variables)
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
        payloads.append((kind, interpreter_script_body(parts, token, cwd, generated_scripts, variables)))
        return payloads

    stdin_script = shell_stdin_literal(parts, command_index, cwd, command_start, variables)
    if stdin_script:
        payloads.append((kind, stdin_script))
    elif stdin_script is UNKNOWN_SHELL_STDIN:
        payloads.append((kind, UNKNOWN_SHELL_STDIN))
    return payloads


def normalize_generated_path(path):
    return os.path.realpath(path) if path else ''


def heredoc_write_target(line, cwd, variables=None):
    parts = tokens(line)
    command_index = skip_prefix(parts, 0) if parts else 0
    segment_end = command_index
    while segment_end < len(parts) and parts[segment_end] not in SEPARATORS:
        segment_end += 1

    index = command_index
    while index < segment_end:
        if parts[index] in {'<<', '<<<'}:
            index += 2
            continue
        if parts[index] in {'>', '>>'} and index + 1 < segment_end:
            return resolve_shell_token(cwd, parts[index + 1], variables)
        index += 1
    if command_index < len(parts) and base(parts[command_index]) == 'tee':
        index = command_index + 1
        while index < segment_end:
            token = parts[index]
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
        if index < segment_end and parts[index] not in SEPARATORS:
            return resolve_shell_token(cwd, parts[index], variables)
    return ''


def heredoc_generated_scripts(text, cwd, variables=None):
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
                'target': heredoc_write_target(raw_line, cwd, variables),
                'body': [],
            })
    for current in pending:
        if current['target']:
            generated[normalize_generated_path(current['target'])] = ''.join(current['body'])
    return generated


def redirect_generated_scripts(parts, cwd, variables=None):
    generated = {}
    command_position = True
    index = 0
    while index < len(parts):
        token = parts[index]
        name = base(token)
        if token in SEPARATORS:
            command_position = True
            index += 1
            continue
        if name in COMMAND_KEYWORDS:
            command_position = True
            index += 1
            continue
        if command_position:
            command_index = skip_prefix(parts, index)
            tee_target, tee_script = tee_generated_script(parts, command_index, index, cwd, variables)
            if tee_target and (tee_script is UNKNOWN_SHELL_STDIN or tee_script):
                generated[normalize_generated_path(tee_target)] = tee_script
            segment_end = command_index
            while segment_end < len(parts) and parts[segment_end] not in SEPARATORS:
                segment_end += 1
            target = ''
            cursor = command_index
            while cursor < segment_end:
                if parts[cursor] in {'>', '>>'} and cursor + 1 < segment_end:
                    target = resolve_shell_token(cwd, parts[cursor + 1], variables)
                    break
                cursor += 1
            if target:
                script = literal_shell_input_command(parts[:segment_end], command_index, cwd, variables)
                if script is UNKNOWN_SHELL_STDIN or script:
                    generated[normalize_generated_path(target)] = script
            index = segment_end
            command_position = False
            continue
        command_position = False
        index += 1
    return generated


def generated_script_for_path(generated_scripts, cwd, path, variables=None):
    resolved = resolve_shell_token(cwd, path, variables)
    if not resolved:
        return None
    return generated_scripts.get(normalize_generated_path(resolved))


def direct_script_commit_target(parts, command_index, cwd, generated_scripts, variables=None, depth=0):
    script_path = expand_executable_script(parts[command_index], variables)
    if script_path is UNKNOWN_SHELL_STDIN:
        return None

    generated_body = generated_script_for_path(generated_scripts, cwd, script_path, variables)
    if generated_body is UNKNOWN_SHELL_STDIN:
        return None
    target = executable_script_git_commit_target(generated_body, cwd, depth + 1) if generated_body is not None else None
    if target:
        return target

    if not script_path or '/' not in script_path:
        return None

    script_body = read_shell_file(cwd, script_path, variables)
    return executable_script_git_commit_target(script_body, cwd, depth + 1) if script_body else None


def resolve_dir(cwd, path):
    if not path:
        return cwd
    if os.path.isabs(path):
        return os.path.abspath(path)
    return os.path.abspath(os.path.join(cwd, path))


def git_subcommand_info(parts, git_index, cwd):
    index = git_index + 1
    git_cwd = cwd
    while index < len(parts) and parts[index] not in SEPARATORS:
        token = parts[index]
        if token == '--':
            index += 1
            break
        if token == '-C':
            if index + 1 >= len(parts):
                return index, git_cwd
            git_cwd = resolve_dir(git_cwd, parts[index + 1])
            index += 2
            continue
        if token.startswith('-C') and token != '-C':
            git_cwd = resolve_dir(git_cwd, token[2:])
            index += 1
            continue
        if not token.startswith('-') or token == '-':
            break
        needs_value = token in GIT_OPTION_ARGS or takes_value(token, GIT_OPTION_ARGS)
        index += 1
        if needs_value and index < len(parts):
            index += 1
    return index, git_cwd


def git_commit_creates_commit(parts, commit_index):
    index = commit_index + 1
    creates_commit = True
    while index < len(parts) and parts[index] not in SEPARATORS:
        token = parts[index]
        if token == '--':
            break
        if token == '--no-dry-run':
            creates_commit = True
            index += 1
            continue
        if token in GIT_COMMIT_NO_CREATE_OPTIONS:
            creates_commit = False
            index += 1
            continue
        if token.startswith('--dry-run='):
            creates_commit = False
            index += 1
            continue
        index += 1
    return creates_commit


def command_substitution_end(parts, index):
    if index >= len(parts) or parts[index] != '$' or index + 1 >= len(parts) or parts[index + 1] != '(':
        return None
    depth = 1
    cursor = index + 2
    while cursor < len(parts):
        if parts[cursor] == '(':
            depth += 1
        elif parts[cursor] == ')':
            depth -= 1
            if depth == 0:
                return cursor
        cursor += 1
    return None


def backtick_substitution_end(parts, index):
    if index >= len(parts) or not parts[index].startswith('`'):
        return None
    cursor = index
    while cursor < len(parts):
        token = parts[cursor][1:] if cursor == index else parts[cursor]
        if token.endswith('`'):
            return cursor
        cursor += 1
    return None


def substitution_end(parts, index):
    dollar_end = command_substitution_end(parts, index)
    if dollar_end is not None:
        return dollar_end
    return backtick_substitution_end(parts, index)


def git_lookup_fragment(parts):
    return any(base(token) == 'git' for token in parts)


def git_assignment_name(parts, index):
    name, value = assignment_parts(parts[index])
    if not name:
        return None, index + 1
    if base(value) == 'git':
        return name, index + 1
    if 'git' in value.lower():
        return name, index + 1
    if value == '$':
        if index + 1 >= len(parts) or parts[index + 1] != '(':
            return None, index + 1
        depth = 1
        cursor = index + 2
        while cursor < len(parts):
            token = parts[cursor]
            if token == '(':
                depth += 1
            if ')' in token:
                depth -= token.count(')')
                if depth <= 0:
                    if git_lookup_fragment(parts[index + 2:cursor + 1]):
                        return name, cursor + 1
                    return None, cursor + 1
            cursor += 1
        return None, index + 1
    if value.startswith('`'):
        body_parts = [value[1:]]
        cursor = index
        while cursor < len(parts):
            if body_parts[-1].endswith('`'):
                body_parts[-1] = body_parts[-1][:-1]
                if git_lookup_fragment(body_parts):
                    return name, cursor + 1
                return None, cursor + 1
            cursor += 1
            if cursor < len(parts):
                body_parts.append(parts[cursor])
        return None, index + 1
    if value.startswith('$(') and 'git' in value:
        return name, index + 1
    return None, index + 1


def collect_git_variables(parts):
    git_vars = set()
    command_position = True
    index = 0
    while index < len(parts):
        token = parts[index]
        name = base(token)
        if token in SEPARATORS:
            command_position = True
            index += 1
            continue
        if name in COMMAND_KEYWORDS:
            command_position = True
            index += 1
            continue
        if name in END_KEYWORDS or name in {'for', 'select', 'case', 'in'}:
            command_position = False
            index += 1
            continue
        if command_position and assignment(token):
            var_name, next_index = git_assignment_name(parts, index)
            if var_name:
                git_vars.add(var_name)
            index = next_index
            continue
        command_position = False
        index += 1
    return git_vars


def variable_name_at(parts, index):
    if index >= len(parts):
        return None, index
    token = parts[index]
    if token.startswith('$') and len(token) > 1:
        if token.startswith('${') and token.endswith('}'):
            return token[2:-1], index + 1
        return token[1:], index + 1
    if token == '$' and index + 3 < len(parts) and parts[index + 1] == '{' and parts[index + 3] == '}':
        return parts[index + 2], index + 4
    return None, index


def command_token_has_embedded_substitution(parts, index):
    if index >= len(parts):
        return False
    token = parts[index]
    if '$(' in token or '`' in token:
        return True
    return (
        token == '$'
        and index + 2 < len(parts)
        and parts[index + 1] == '('
        and parts[index + 2] not in SEPARATORS
    )


def git_variable_commit_target(parts, var_end, cwd):
    fake_parts = ['git'] + parts[var_end:]
    sub_index, git_cwd = git_subcommand_info(fake_parts, 0, cwd)
    if sub_index < len(fake_parts) and base(fake_parts[sub_index]) == 'commit' and git_commit_creates_commit(fake_parts, sub_index):
        return git_cwd
    return None


def command_variable_resolves_to_git(var_name, variables=None):
    if not var_name:
        return False
    variables = variables or {}
    value = variables.get(var_name, os.environ.get(var_name, ''))
    if not value:
        return False
    expanded = decode_ansi_c_token(value)
    return base(expanded) == 'git' or 'git' in expanded.lower()


def substitution_git_commit_target(parts, index, cwd):
    dollar_end = command_substitution_end(parts, index)
    if dollar_end is not None:
        body_parts = parts[index + 2:dollar_end]
        next_index = dollar_end + 1
    else:
        backtick_end = backtick_substitution_end(parts, index)
        if backtick_end is None:
            return None
        body_parts = parts[index:backtick_end + 1]
        body_parts[0] = body_parts[0][1:]
        body_parts[-1] = body_parts[-1][:-1]
        next_index = backtick_end + 1
    if not git_lookup_fragment(body_parts):
        return None
    if next_index >= len(parts) or parts[next_index] in SEPARATORS:
        return None
    fake_parts = ['git'] + parts[next_index:]
    return cwd if base(parts[next_index]) == 'commit' and git_commit_creates_commit(fake_parts, 1) else None


def cd_target(parts, command_index, cwd, variables=None):
    index = command_index + 1
    if index < len(parts) and parts[index] == '--':
        index += 1
    if index >= len(parts) or parts[index] in SEPARATORS:
        return os.path.expanduser('~')
    if parts[index] == '-':
        return ''
    return resolve_shell_token(cwd, parts[index], variables)


def has_git_commit(text, cwd, depth=0):
    if depth > 24:
        return None
    if not text.strip():
        return None
    shell_text, heredoc_substitutions, heredoc_bodies = strip_heredoc_bodies(text)
    for fragment in heredoc_substitutions:
        target = has_git_commit(fragment, cwd, depth + 1)
        if target:
            return target
    for body in heredoc_bodies:
        target = has_git_commit(body, cwd, depth + 1)
        if target:
            return target
    for kind, body in interpreter_heredoc_bodies(text):
        target = code_git_commit_target(body, cwd, depth + 1)
        if target:
            return target
    for fragment in extract_backticks(shell_text):
        target = has_git_commit(fragment, cwd, depth + 1)
        if target:
            return target
    for fragment in extract_dollars(shell_text):
        target = has_git_commit(fragment, cwd, depth + 1)
        if target:
            return target
    parts = tokens(shell_text)
    shell_vars = collect_literal_variables(parts)
    git_vars = collect_git_variables(parts)
    aliases = collect_aliases(parts, shell_vars)
    functions = shell_functions(parts)
    generated_scripts = redirect_generated_scripts(parts, cwd, shell_vars)
    generated_scripts.update(heredoc_generated_scripts(text, cwd, shell_vars))

    for script in shell_c_scripts(shell_text, shell_vars):
        if script is UNKNOWN_SHELL_STDIN:
            continue
        if is_inline_command_substitution(script):
            script_output = literal_command_substitution_output(script, cwd, shell_vars)
            if script_output is UNKNOWN_SHELL_STDIN:
                continue
            target = has_git_commit(script_output, cwd, depth + 1) if script_output else None
            if target:
                return target
        else:
            target = has_git_commit(script, cwd, depth + 1) if script else None
            if target:
                return target

    command_position = True
    index = 0
    while index < len(parts):
        token = parts[index]
        name = base(token)
        if token in SEPARATORS:
            command_position = True
            index += 1
            continue
        if name in COMMAND_KEYWORDS:
            command_position = True
            index += 1
            continue
        if name in END_KEYWORDS or name in {'for', 'select', 'case', 'in'}:
            command_position = False
            index += 1
            continue
        if command_position:
            if assignment(token):
                index = assignment_end(parts, index)
                continue
            definition_end = function_definition_end(parts, index)
            if definition_end is not None:
                command_position = False
                index = definition_end + 1
                continue
            target = substitution_git_commit_target(parts, index, cwd)
            if target:
                return target
            direct_substitution_end = substitution_end(parts, index)
            if direct_substitution_end is not None:
                resolved_invocation = command_substitution_resolved_invocation(parts, index, cwd, shell_vars)
                if resolved_invocation is not None:
                    resolved_command, resolved_args, _ = resolved_invocation
                    if resolved_command is UNKNOWN_SHELL_STDIN:
                        target = has_git_commit(shell_quote_parts(resolved_args), cwd, depth + 1) if resolved_args else None
                        if target:
                            return target
                    elif resolved_command:
                        target = has_git_commit(shell_quote_parts([resolved_command] + resolved_args), cwd, depth + 1)
                        if target:
                            return target
                command_position = False
                index = direct_substitution_end + 1
                continue
            if command_token_has_embedded_substitution(parts, index):
                command_position = False
                index += 1
                continue
            var_name, var_end = variable_name_at(parts, index)
            if var_name in git_vars:
                target = git_variable_commit_target(parts, var_end, cwd)
                if target:
                    return target
            if var_name:
                if command_variable_resolves_to_git(var_name, shell_vars):
                    target = git_variable_commit_target(parts, var_end, cwd)
                    if target:
                        return target
                command_position = False
                index = var_end
                continue
            command_index = skip_prefix(parts, index)
            if command_index < len(parts):
                target = substitution_git_commit_target(parts, command_index, cwd)
                if target:
                    return target
                wrapped_substitution_end = substitution_end(parts, command_index)
                if wrapped_substitution_end is not None:
                    resolved_invocation = command_substitution_resolved_invocation(parts, command_index, cwd, shell_vars)
                    if resolved_invocation is not None:
                        resolved_command, resolved_args, _ = resolved_invocation
                        if resolved_command is UNKNOWN_SHELL_STDIN:
                            target = has_git_commit(shell_quote_parts(resolved_args), cwd, depth + 1) if resolved_args else None
                            if target:
                                return target
                        elif resolved_command:
                            target = has_git_commit(shell_quote_parts(parts[index:command_index] + [resolved_command] + resolved_args), cwd, depth + 1)
                            if target:
                                return target
                    command_position = False
                    index = wrapped_substitution_end + 1
                    continue
                if command_token_has_embedded_substitution(parts, command_index):
                    command_position = False
                    index = command_index + 1
                    continue
                var_name, var_end = variable_name_at(parts, command_index)
                if var_name in git_vars:
                    target = git_variable_commit_target(parts, var_end, cwd)
                    if target:
                        return target
                if var_name:
                    if command_variable_resolves_to_git(var_name, shell_vars):
                        target = git_variable_commit_target(parts, var_end, cwd)
                        if target:
                            return target
                    command_position = False
                    index = var_end
                    continue
                command_token = expand_shell_command_token(parts[command_index], shell_vars)
                if command_token is UNKNOWN_SHELL_STDIN:
                    command_position = False
                    index = command_index + 1
                    continue
                raw_command = command_token.strip('`"\'')
                command_name = '.' if raw_command == '.' else base(command_token)
                if command_name in aliases:
                    alias_body = aliases[command_name]
                    if alias_body is UNKNOWN_SHELL_STDIN:
                        command_position = False
                        index += 1
                        continue
                    target = has_git_commit(f"{alias_body} {shell_quote_parts(parts[command_index + 1:])}", cwd, depth + 1)
                    if target:
                        return target
                if command_name in functions:
                    target = has_git_commit(shell_quote_parts(functions[command_name] + parts[command_index + 1:]), cwd, depth + 1)
                    if target:
                        return target
                if command_name in SHELLS:
                    script = shell_script_arg(parts, command_index)
                    if script:
                        script = expand_executable_script(script, shell_vars)
                        if script is UNKNOWN_SHELL_STDIN:
                            script = ''
                        if is_inline_command_substitution(script):
                            script_output = literal_command_substitution_output(script, cwd, shell_vars)
                            if script_output is UNKNOWN_SHELL_STDIN:
                                script_output = ''
                            target = has_git_commit(script_output, cwd, depth + 1) if script_output else None
                            if target:
                                return target
                        else:
                            target = has_git_commit(script, cwd, depth + 1)
                            if target:
                                return target
                    process_index = process_substitution_index_for_command(parts, command_index)
                    if process_index is not None:
                        process_body = process_substitution_body(parts, process_index)
                        if process_body is None:
                            process_body = []
                        process_text = ' '.join(process_body)
                        target = has_git_commit(process_text, cwd, depth + 1) if process_text else None
                        if target:
                            return target
                        process_output = process_substitution_literal_output(process_body, cwd, shell_vars)
                        if process_output is UNKNOWN_SHELL_STDIN:
                            process_output = ''
                        target = has_git_commit(process_output, cwd, depth + 1) if process_output else None
                        if target:
                            return target
                    script_file = shell_script_file_arg(parts, command_index)
                    generated_body = generated_script_for_path(generated_scripts, cwd, script_file, shell_vars) if script_file else None
                    if generated_body is UNKNOWN_SHELL_STDIN:
                        generated_body = None
                    target = has_git_commit(generated_body, cwd, depth + 1) if generated_body else None
                    if target:
                        return target
                    script_body = read_shell_file(cwd, script_file, shell_vars) if script_file else ''
                    target = has_git_commit(script_body, cwd, depth + 1) if script_body else None
                    if target:
                        return target
                    stdin_script = shell_stdin_literal(parts, command_index, cwd, index, shell_vars)
                    if stdin_script is UNKNOWN_SHELL_STDIN:
                        stdin_script = ''
                    target = has_git_commit(stdin_script, cwd, depth + 1) if stdin_script else None
                    if target:
                        return target
                if command_name in SOURCES:
                    process_index = process_substitution_index_for_command(parts, command_index)
                    if process_index is not None:
                        process_body = process_substitution_body(parts, process_index)
                        if process_body is None:
                            process_body = []
                        process_text = ' '.join(process_body)
                        target = has_git_commit(process_text, cwd, depth + 1) if process_text else None
                        if target:
                            return target
                        process_output = process_substitution_literal_output(process_body, cwd, shell_vars)
                        if process_output is UNKNOWN_SHELL_STDIN:
                            process_output = ''
                        target = has_git_commit(process_output, cwd, depth + 1) if process_output else None
                        if target:
                            return target
                    script_file = source_script_file_arg(parts, command_index)
                    generated_body = generated_script_for_path(generated_scripts, cwd, script_file, shell_vars) if script_file else None
                    if generated_body is UNKNOWN_SHELL_STDIN:
                        generated_body = None
                    target = has_git_commit(generated_body, cwd, depth + 1) if generated_body else None
                    if target:
                        return target
                    script_body = read_shell_file(cwd, script_file, shell_vars) if script_file else None
                    target = has_git_commit(script_body, cwd, depth + 1) if script_body else None
                    if target:
                        return target
                if command_name in EVALS:
                    script = expand_executable_script(' '.join(parts[command_index + 1:]), shell_vars)
                    if script is UNKNOWN_SHELL_STDIN:
                        script = ''
                    target = has_git_commit(script, cwd, depth + 1) if script else None
                    if target:
                        return target
                env_payload = env_split_payload(parts, command_index, shell_vars)
                if env_payload is UNKNOWN_SHELL_STDIN:
                    env_payload = ''
                target = has_git_commit(env_payload, cwd, depth + 1) if env_payload else None
                if target:
                    return target
                for kind, script in interpreter_code_payloads(parts, command_index, index, cwd, generated_scripts, shell_vars):
                    if script is UNKNOWN_SHELL_STDIN:
                        continue
                    target = code_git_commit_target(script, cwd, depth + 1)
                    if target:
                        return target
                target = xargs_commit_target(parts, command_index, index, cwd, shell_vars, depth)
                if target:
                    return target
                target = find_exec_commit_target(parts, command_index, cwd, depth)
                if target:
                    return target
                for runner_script in runner_shell_payloads(parts, command_index, shell_vars):
                    if runner_script is UNKNOWN_SHELL_STDIN:
                        continue
                    if is_inline_command_substitution(runner_script):
                        script_output = literal_command_substitution_output(runner_script, cwd, shell_vars)
                        if script_output is UNKNOWN_SHELL_STDIN:
                            script_output = ''
                        target = has_git_commit(script_output, cwd, depth + 1) if script_output else None
                        if target:
                            return target
                    else:
                        target = has_git_commit(runner_script, cwd, depth + 1) if runner_script else None
                        if target:
                            return target
                target = direct_script_commit_target([command_token] + parts[command_index + 1:], 0, cwd, generated_scripts, shell_vars, depth)
                if target:
                    return target
                if command_name == 'cd':
                    target = cd_target(parts, command_index, cwd, shell_vars)
                    if os.path.isdir(target):
                        cwd = target
                if command_name == 'git':
                    sub_index, git_cwd = git_subcommand_info(parts, command_index, cwd)
                    if sub_index < len(parts) and base(parts[sub_index]) == 'commit' and git_commit_creates_commit(parts, sub_index):
                        return git_cwd
        command_position = False
        index += 1
    return None


target = has_git_commit(os.environ.get('DK_HOOK_COMMAND', ''), os.getcwd())
if not target:
    sys.exit(1)
print(target)
sys.exit(0)
PY
}

HOOK_INPUT=""
if [[ ! -t 0 ]]; then
  HOOK_INPUT=$(cat)
fi
if [[ -z "$HOOK_INPUT" ]]; then
  HOOK_INPUT="${CLAUDE_TOOL_USE_INPUT:-}"
fi

# Only run after actual git commit commands.
# Uses word-boundary matching to avoid false positives on git commit-tree,
# comments containing "git commit", etc.
TOOL_INPUT="$HOOK_INPUT"
if [[ -n "$HOOK_INPUT" ]]; then
  TOOL_INPUT=$(__dk_post_commit_hook_field "$HOOK_INPUT" "command" 2>/dev/null || printf '%s' "$HOOK_INPUT")
fi
COMMIT_REPO=$(__dk_post_commit_is_git_commit "$TOOL_INPUT") || {
  exit 0
}

# Check if a commit was actually created (exit code 0 means success). Claude
# hook stdin is authoritative; legacy env is only a no-stdin/non-JSON fallback.
TOOL_EXIT=""
HOOK_INPUT_IS_JSON=0
if [[ -n "$HOOK_INPUT" ]]; then
  if __dk_post_commit_is_json_payload "$HOOK_INPUT"; then
    HOOK_INPUT_IS_JSON=1
    TOOL_EXIT=$(__dk_post_commit_hook_field "$HOOK_INPUT" "exit_code" 2>/dev/null || printf '0')
  fi
fi
if [[ -z "$TOOL_EXIT" && $HOOK_INPUT_IS_JSON -eq 0 ]]; then
  TOOL_EXIT="${CLAUDE_TOOL_USE_EXIT_CODE:-}"
fi
TOOL_EXIT="${TOOL_EXIT:-0}"
if [[ "$TOOL_EXIT" != "0" ]]; then
  exit 0
fi

# Delegate to guard handler for markdown-based guard evaluation
source "${DOYAKEN_DIR:-$HOME/work/doyaken}/lib/common.sh"
COMMITTED_FILES=$(git -C "$COMMIT_REPO" diff-tree --root --no-commit-id --name-only -r HEAD 2>/dev/null || echo "")
COMMIT_MSG=$(git -C "$COMMIT_REPO" log -1 --pretty=format:%s 2>/dev/null || echo "")

export DOYAKEN_GUARD_EVENT="commit"
export CLAUDE_TOOL_USE_INPUT="${COMMITTED_FILES}"$'\n'"${COMMIT_MSG}"

GUARD_EXIT=0
if [[ -d "$COMMIT_REPO" ]]; then
  (cd "$COMMIT_REPO" && python3 "$DOYAKEN_DIR/hooks/guard-handler.py") || GUARD_EXIT=$?
else
  python3 "$DOYAKEN_DIR/hooks/guard-handler.py" || GUARD_EXIT=$?
fi

# Validate conventional commit format (handled here, not in guards, because
# it needs to check the commit message specifically, not the combined text)
# Full set of conventional commit types per https://www.conventionalcommits.org
CONVENTIONAL_REGEX='^(feat|fix|refactor|perf|docs|test|chore|build|ci|style|revert)(\([^)]+\))?!?: .+'
if [[ -n "$COMMIT_MSG" ]] && ! printf '%s\n' "$COMMIT_MSG" | grep -qE "$CONVENTIONAL_REGEX"; then
  echo "Commit message does not follow conventional format." >&2
  echo "Expected: <type>[(<scope>)][!]: <description>" >&2
  echo "Got: $COMMIT_MSG" >&2
  echo "Amend the commit with a properly formatted message." >&2
  GUARD_EXIT=2
fi

exit $GUARD_EXIT
