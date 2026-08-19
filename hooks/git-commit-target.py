#!/usr/bin/env python3
"""Decide whether a Bash command created a git commit, and where.

Invoked by hooks/post-commit-guard.sh with the command in DX_HOOK_COMMAND.
Prints the repository directory and exits 0 when the command creates a
commit; exits 1 otherwise.

Reading the command — through wrappers, shells, aliases, interpreters, xargs,
find -exec, and command substitution — is hooks/shell_parse.py, shared with
hooks/guard-handler.py. What lives here is only the git question: which token
is git, which subcommand it runs, and which directory the commit lands in.
"""
import os
import sys

# Running this file by path already puts hooks/ on sys.path, but not under
# PYTHONSAFEPATH, so name the directory rather than depend on the default.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from shell_parse import *  # noqa: E402,F403  shared shell-command parsing

GIT_OPTION_ARGS = {
    '-C', '-c', '--config-env', '--exec-path', '--git-dir', '--work-tree',
    '--namespace', '--super-prefix',
}
GIT_COMMIT_NO_CREATE_OPTIONS = {
    '--dry-run', '--short', '--porcelain', '--long', '-z', '--null',
    '--help', '-h',
}


def code_git_commit_target(code, cwd, depth=0, whole_file=False):
    if code is UNKNOWN_SHELL_STDIN:
        return None
    if depth > 24:
        return None
    if not code or not code.strip():
        return None
    for fragment in code_execution_fragments(code, whole_file=whole_file):
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
    if not script_kind:
        return None
    return code_git_commit_target(script_body, cwd, depth + 1, whole_file=True)


def xargs_commit_target(tokens, command_index, command_start, cwd, variables=None, depth=0):
    if token_basename(tokens[command_index]) != 'xargs':
        return None
    command_arg_start, replacement = xargs_command_start(tokens, command_index)
    xargs_separators = SHELL_SEPARATORS - {'{', '}'}
    if command_arg_start >= len(tokens) or tokens[command_arg_start] in xargs_separators:
        return None
    command_end = command_arg_start
    while command_end < len(tokens) and tokens[command_end] not in xargs_separators:
        command_end += 1
    command_tokens = tokens[command_arg_start:command_end]
    literal_command = shell_quote_tokens(command_tokens)
    stdin_text = shell_stdin_literal(tokens, command_index, command_start, variables, cwd)

    if replacement:
        values = [] if stdin_text is UNKNOWN_SHELL_STDIN else xargs_stdin_tokens(
            stdin_text, xargs_uses_null_delimiter(tokens, command_index),
            by_line=not xargs_splits_items_on_blanks(tokens, command_index))
        # Nothing readable to substitute is not the same as nothing running:
        # xargs with no visible source reads the terminal. Either way the
        # template is the best evidence available, so read it as written.
        if not values:
            return has_git_commit(literal_command, cwd, depth + 1)
        for value in values:
            replaced = replace_xargs_placeholders(command_tokens, replacement, value)
            if replaced is UNKNOWN_SHELL_STDIN:
                return has_git_commit(literal_command, cwd, depth + 1)
            target = has_git_commit(shell_quote_tokens(replaced), cwd, depth + 1)
            if target:
                return target
        return None

    if stdin_text is UNKNOWN_SHELL_STDIN:
        return has_git_commit(literal_command, cwd, depth + 1)
    if stdin_text:
        command_tokens = command_tokens + shell_tokens(stdin_text)
    return has_git_commit(shell_quote_tokens(command_tokens), cwd, depth + 1)


def find_exec_commit_target(tokens, command_index, cwd, depth=0):
    if token_basename(tokens[command_index]) != 'find':
        return None
    for command_tokens in find_exec_commands(tokens, command_index):
        target = has_git_commit(shell_quote_tokens(command_tokens), cwd, depth + 1)
        if target:
            return target
    return None


def direct_script_commit_target(tokens, command_index, cwd, generated_scripts, variables=None, depth=0):
    script_path = expand_executable_script(tokens[command_index], variables)
    if script_path is UNKNOWN_SHELL_STDIN:
        return None

    generated_body = generated_script_for_path(generated_scripts, script_path, variables, cwd)
    if generated_body is UNKNOWN_SHELL_STDIN:
        return None
    if generated_body is not None:
        target = executable_script_git_commit_target(generated_body, cwd, depth + 1)
        if target:
            return target

    if not script_path or '/' not in script_path:
        return None

    script_body, _status = shell_file_body_status(script_path, variables, cwd)
    if not script_body:
        return None
    return executable_script_git_commit_target(script_body, cwd, depth + 1)


def resolve_dir(cwd, path):
    """Resolve a `git -C` argument. Unlike resolve_shell_path this does no
    variable expansion: the caller has already expanded the token."""
    if not path:
        return cwd
    if os.path.isabs(path):
        return os.path.abspath(path)
    return os.path.abspath(os.path.join(cwd, path))


def git_subcommand_info(tokens, git_index, cwd):
    index = git_index + 1
    git_cwd = cwd
    while index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
        token = tokens[index]
        if token == '--':
            index += 1
            break
        if token == '-C':
            if index + 1 >= len(tokens):
                return index, git_cwd
            git_cwd = resolve_dir(git_cwd, tokens[index + 1])
            index += 2
            continue
        if token.startswith('-C') and token != '-C':
            git_cwd = resolve_dir(git_cwd, token[2:])
            index += 1
            continue
        if not token.startswith('-') or token == '-':
            break
        needs_value = token in GIT_OPTION_ARGS or token_takes_value(token, GIT_OPTION_ARGS)
        index += 1
        if needs_value and index < len(tokens):
            index += 1
    return index, git_cwd


def git_commit_creates_commit(tokens, commit_index):
    index = commit_index + 1
    creates_commit = True
    while index < len(tokens) and tokens[index] not in SHELL_SEPARATORS:
        token = tokens[index]
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


def git_lookup_fragment(tokens):
    return any(token_basename(token) == 'git' for token in tokens)


def git_assignment_name(tokens, index):
    name, value = assignment_parts(tokens[index])
    if not name:
        return None, index + 1
    if token_basename(value) == 'git':
        return name, index + 1
    if 'git' in value.lower():
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
                    if git_lookup_fragment(tokens[index + 2:cursor + 1]):
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
                if git_lookup_fragment(body_tokens):
                    return name, cursor + 1
                return None, cursor + 1
            cursor += 1
            if cursor < len(tokens):
                body_tokens.append(tokens[cursor])
        return None, index + 1
    if value.startswith('$(') and 'git' in value:
        return name, index + 1
    return None, index + 1


def collect_git_variables(tokens):
    git_vars = set()
    command_position = True
    index = 0
    while index < len(tokens):
        token = tokens[index]
        name = token_basename(token)
        if token in SHELL_SEPARATORS:
            command_position = True
            index += 1
            continue
        if name in SHELL_COMMAND_KEYWORDS:
            command_position = True
            index += 1
            continue
        if name in SHELL_END_KEYWORDS or name in {'for', 'select', 'case', 'in'}:
            command_position = False
            index += 1
            continue
        if command_position and is_shell_assignment(token):
            var_name, next_index = git_assignment_name(tokens, index)
            if var_name:
                git_vars.add(var_name)
            index = next_index
            continue
        command_position = False
        index += 1
    return git_vars


def git_variable_commit_target(tokens, var_end, cwd):
    fake_tokens = ['git'] + tokens[var_end:]
    sub_index, git_cwd = git_subcommand_info(fake_tokens, 0, cwd)
    if sub_index < len(fake_tokens) and token_basename(fake_tokens[sub_index]) == 'commit' \
            and git_commit_creates_commit(fake_tokens, sub_index):
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
    return token_basename(expanded) == 'git' or 'git' in expanded.lower()


def substitution_git_commit_target(tokens, index, cwd):
    dollar_end = command_substitution_end(tokens, index)
    if dollar_end is not None:
        body_tokens = tokens[index + 2:dollar_end]
        next_index = dollar_end + 1
    else:
        backtick_end = backtick_substitution_end(tokens, index)
        if backtick_end is None:
            return None
        body_tokens = tokens[index:backtick_end + 1]
        body_tokens[0] = body_tokens[0][1:]
        body_tokens[-1] = body_tokens[-1][:-1]
        next_index = backtick_end + 1
    if not git_lookup_fragment(body_tokens):
        return None
    if next_index >= len(tokens) or tokens[next_index] in SHELL_SEPARATORS:
        return None
    fake_tokens = ['git'] + tokens[next_index:]
    if token_basename(tokens[next_index]) != 'commit':
        return None
    return cwd if git_commit_creates_commit(fake_tokens, 1) else None


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
    for _kind, body in interpreter_heredoc_bodies(text):
        target = code_git_commit_target(body, cwd, depth + 1)
        if target:
            return target
    for fragment in extract_executable_backticks(shell_text):
        target = has_git_commit(fragment, cwd, depth + 1)
        if target:
            return target
    for fragment in extract_dollar_substitutions(shell_text):
        target = has_git_commit(fragment, cwd, depth + 1)
        if target:
            return target
    tokens = shell_tokens(shell_text)
    shell_vars = collect_literal_variables(tokens)
    git_vars = collect_git_variables(tokens)
    aliases = collect_aliases(tokens, shell_vars)
    functions = shell_functions(tokens)
    generated_scripts = redirect_generated_scripts(tokens, shell_vars, cwd)
    generated_scripts.update(heredoc_generated_scripts(text, shell_vars, cwd))

    for script in shell_c_scripts(shell_text, shell_vars):
        if script is UNKNOWN_SHELL_STDIN:
            continue
        if is_inline_command_substitution(script):
            script_output = literal_command_substitution_output(script, shell_vars, cwd)
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
    while index < len(tokens):
        token = tokens[index]
        name = token_basename(token)
        if token in SHELL_SEPARATORS:
            command_position = True
            index += 1
            continue
        if name in SHELL_COMMAND_KEYWORDS:
            command_position = True
            index += 1
            continue
        if name in SHELL_END_KEYWORDS or name in {'for', 'select', 'case', 'in'}:
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
            target = substitution_git_commit_target(tokens, index, cwd)
            if target:
                return target
            direct_substitution_end = substitution_end(tokens, index)
            if direct_substitution_end is not None:
                resolved_invocation = command_substitution_resolved_invocation(tokens, index, shell_vars, cwd)
                if resolved_invocation is not None:
                    resolved_command, resolved_args, _ = resolved_invocation
                    if resolved_command is UNKNOWN_SHELL_STDIN:
                        target = has_git_commit(shell_quote_tokens(resolved_args), cwd, depth + 1) if resolved_args else None
                        if target:
                            return target
                    elif resolved_command:
                        target = has_git_commit(shell_quote_tokens([resolved_command] + resolved_args), cwd, depth + 1)
                        if target:
                            return target
                command_position = False
                index = direct_substitution_end + 1
                continue
            if command_token_has_embedded_substitution(tokens, index):
                command_position = False
                index += 1
                continue
            var_name, var_end = variable_name_at(tokens, index)
            if var_name in git_vars:
                target = git_variable_commit_target(tokens, var_end, cwd)
                if target:
                    return target
            if var_name:
                if command_variable_resolves_to_git(var_name, shell_vars):
                    target = git_variable_commit_target(tokens, var_end, cwd)
                    if target:
                        return target
                command_position = False
                index = var_end
                continue
            command_index = skip_wrapper_prefix(tokens, index)
            if command_index < len(tokens):
                target = substitution_git_commit_target(tokens, command_index, cwd)
                if target:
                    return target
                wrapped_substitution_end = substitution_end(tokens, command_index)
                if wrapped_substitution_end is not None:
                    resolved_invocation = command_substitution_resolved_invocation(tokens, command_index, shell_vars, cwd)
                    if resolved_invocation is not None:
                        resolved_command, resolved_args, _ = resolved_invocation
                        if resolved_command is UNKNOWN_SHELL_STDIN:
                            target = has_git_commit(shell_quote_tokens(resolved_args), cwd, depth + 1) if resolved_args else None
                            if target:
                                return target
                        elif resolved_command:
                            target = has_git_commit(
                                shell_quote_tokens(tokens[index:command_index] + [resolved_command] + resolved_args),
                                cwd, depth + 1)
                            if target:
                                return target
                    command_position = False
                    index = wrapped_substitution_end + 1
                    continue
                if command_token_has_embedded_substitution(tokens, command_index):
                    command_position = False
                    index = command_index + 1
                    continue
                var_name, var_end = variable_name_at(tokens, command_index)
                if var_name in git_vars:
                    target = git_variable_commit_target(tokens, var_end, cwd)
                    if target:
                        return target
                if var_name:
                    if command_variable_resolves_to_git(var_name, shell_vars):
                        target = git_variable_commit_target(tokens, var_end, cwd)
                        if target:
                            return target
                    command_position = False
                    index = var_end
                    continue
                command_token = expand_shell_command_token(tokens[command_index], shell_vars)
                if command_token is UNKNOWN_SHELL_STDIN:
                    command_position = False
                    index = command_index + 1
                    continue
                raw_command = command_token.strip('`"\'')
                command_name = '.' if raw_command == '.' else token_basename(command_token)
                if command_name in aliases:
                    alias_body = aliases[command_name]
                    if alias_body is UNKNOWN_SHELL_STDIN:
                        command_position = False
                        index += 1
                        continue
                    target = has_git_commit(
                        f"{alias_body} {shell_quote_tokens(tokens[command_index + 1:])}", cwd, depth + 1)
                    if target:
                        return target
                if command_name in functions:
                    target = has_git_commit(
                        shell_quote_tokens(functions[command_name] + tokens[command_index + 1:]), cwd, depth + 1)
                    if target:
                        return target
                if command_name in SHELLS and shell_invocation_is_noexec(tokens, command_index):
                    # Syntax check only: nothing ran, so nothing was committed.
                    command_position = False
                    index = command_segment_end(tokens, command_index + 1)
                    continue
                if command_name in SHELLS:
                    script = shell_script_arg(tokens, command_index)
                    if script:
                        script = expand_executable_script(script, shell_vars)
                        if script is UNKNOWN_SHELL_STDIN:
                            script = ''
                        if is_inline_command_substitution(script):
                            script_output = literal_command_substitution_output(script, shell_vars, cwd)
                            if script_output is UNKNOWN_SHELL_STDIN:
                                script_output = ''
                            target = has_git_commit(script_output, cwd, depth + 1) if script_output else None
                            if target:
                                return target
                        else:
                            target = has_git_commit(script, cwd, depth + 1)
                            if target:
                                return target
                    process_index = process_substitution_index_for_command(tokens, command_index)
                    if process_index is not None:
                        process_body = process_substitution_body(tokens, process_index)
                        if process_body is None:
                            process_body = []
                        process_text = ' '.join(process_body)
                        target = has_git_commit(process_text, cwd, depth + 1) if process_text else None
                        if target:
                            return target
                        process_output = process_substitution_literal_output(process_body, shell_vars, cwd)
                        if process_output is UNKNOWN_SHELL_STDIN:
                            process_output = ''
                        target = has_git_commit(process_output, cwd, depth + 1) if process_output else None
                        if target:
                            return target
                    script_file = shell_script_file_arg(tokens, command_index)
                    generated_body = generated_script_for_path(
                        generated_scripts, script_file, shell_vars, cwd) if script_file else None
                    if generated_body is UNKNOWN_SHELL_STDIN:
                        generated_body = None
                    target = has_git_commit(generated_body, cwd, depth + 1) if generated_body else None
                    if target:
                        return target
                    script_body = shell_file_body_status(script_file, shell_vars, cwd)[0] if script_file else ''
                    target = has_git_commit(script_body, cwd, depth + 1) if script_body else None
                    if target:
                        return target
                    stdin_script = shell_stdin_literal(tokens, command_index, index, shell_vars, cwd)
                    if stdin_script is UNKNOWN_SHELL_STDIN:
                        stdin_script = ''
                    target = has_git_commit(stdin_script, cwd, depth + 1) if stdin_script else None
                    if target:
                        return target
                if command_name in SOURCE_COMMANDS:
                    process_index = process_substitution_index_for_command(tokens, command_index)
                    if process_index is not None:
                        process_body = process_substitution_body(tokens, process_index)
                        if process_body is None:
                            process_body = []
                        process_text = ' '.join(process_body)
                        target = has_git_commit(process_text, cwd, depth + 1) if process_text else None
                        if target:
                            return target
                        process_output = process_substitution_literal_output(process_body, shell_vars, cwd)
                        if process_output is UNKNOWN_SHELL_STDIN:
                            process_output = ''
                        target = has_git_commit(process_output, cwd, depth + 1) if process_output else None
                        if target:
                            return target
                    script_file = source_script_file_arg(tokens, command_index)
                    generated_body = generated_script_for_path(
                        generated_scripts, script_file, shell_vars, cwd) if script_file else None
                    if generated_body is UNKNOWN_SHELL_STDIN:
                        generated_body = None
                    target = has_git_commit(generated_body, cwd, depth + 1) if generated_body else None
                    if target:
                        return target
                    script_body = shell_file_body_status(script_file, shell_vars, cwd)[0] if script_file else ''
                    target = has_git_commit(script_body, cwd, depth + 1) if script_body else None
                    if target:
                        return target
                if command_name in EVAL_COMMANDS:
                    script = expand_executable_script(' '.join(tokens[command_index + 1:]), shell_vars)
                    if script is UNKNOWN_SHELL_STDIN:
                        script = ''
                    target = has_git_commit(script, cwd, depth + 1) if script else None
                    if target:
                        return target
                env_payload = env_split_payload(tokens, command_index, shell_vars)
                if env_payload is UNKNOWN_SHELL_STDIN:
                    env_payload = ''
                target = has_git_commit(env_payload, cwd, depth + 1) if env_payload else None
                if target:
                    return target
                for _kind, script, from_file in interpreter_code_payloads(
                        tokens, command_index, index, generated_scripts, shell_vars, cwd):
                    if script is UNKNOWN_SHELL_STDIN:
                        continue
                    target = code_git_commit_target(script, cwd, depth + 1, whole_file=from_file)
                    if target:
                        return target
                target = xargs_commit_target(tokens, command_index, index, cwd, shell_vars, depth)
                if target:
                    return target
                target = find_exec_commit_target(tokens, command_index, cwd, depth)
                if target:
                    return target
                for runner_script in runner_shell_payloads(tokens, command_index, shell_vars):
                    if runner_script is UNKNOWN_SHELL_STDIN:
                        continue
                    if is_inline_command_substitution(runner_script):
                        script_output = literal_command_substitution_output(runner_script, shell_vars, cwd)
                        if script_output is UNKNOWN_SHELL_STDIN:
                            script_output = ''
                        target = has_git_commit(script_output, cwd, depth + 1) if script_output else None
                        if target:
                            return target
                    else:
                        target = has_git_commit(runner_script, cwd, depth + 1) if runner_script else None
                        if target:
                            return target
                target = direct_script_commit_target(
                    [command_token] + tokens[command_index + 1:], 0, cwd, generated_scripts, shell_vars, depth)
                if target:
                    return target
                if command_name == 'cd':
                    target = cd_target(tokens, command_index, cwd, shell_vars)
                    if os.path.isdir(target):
                        cwd = target
                if command_name == 'git':
                    sub_index, git_cwd = git_subcommand_info(tokens, command_index, cwd)
                    if sub_index < len(tokens) and token_basename(tokens[sub_index]) == 'commit' \
                            and git_commit_creates_commit(tokens, sub_index):
                        return git_cwd
        command_position = False
        index += 1
    return None


def main():
    target = has_git_commit(os.environ.get('DX_HOOK_COMMAND', ''), os.getcwd())
    if not target:
        return 1
    print(target)
    return 0


# Guarded so the parser can be imported by tests without running or exiting.
if __name__ == '__main__':
    sys.exit(main())