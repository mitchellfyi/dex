#!/usr/bin/env bash
set -euo pipefail

# Dex parses shell commands twice, for two different questions:
#
#   hooks/guard-handler.py      does this command do something disallowed?
#   hooks/git-commit-target.py  did this command create a commit, and where?
#
# They share ~76 helper names but are NOT interchangeable: the commit parser
# threads the working directory through its primitives so it can locate the
# repository, so several shared names take different positional arguments
# (literal_command_substitution_output(script, cwd, variables) here versus
# (script, variables, cwd) there). Unifying them means redesigning the guard
# primitives to carry cwd, not moving code.
#
# Until then the risk is silent drift: a capability taught to one parser and
# not the other. That has already happened once — guard-handler.py learned to
# honor `bash -n` while the commit parser kept treating it as executing. This
# test makes that visible by pinning which helper names each parser has.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
guard = (root / "hooks/guard-handler.py").read_text(encoding="utf-8")
commit = (root / "hooks/git-commit-target.py").read_text(encoding="utf-8")


def function_names(source):
    return set(re.findall(r"^def ([a-zA-Z_][a-zA-Z0-9_]*)\(", source, re.M))


# Helpers the commit parser owns: git-specific logic, plus its own names for
# primitives the guard parser spells differently.
COMMIT_ONLY = {
    # git-specific
    "code_git_commit_target", "collect_git_variables", "command_variable_resolves_to_git",
    "direct_script_commit_target", "executable_script_git_commit_target",
    "find_exec_commit_target", "git_assignment_name", "git_commit_creates_commit",
    "git_lookup_fragment", "git_subcommand_info", "git_variable_commit_target",
    "has_git_commit", "substitution_git_commit_target", "xargs_commit_target",
    # local spellings of shared primitives
    "assignment", "base", "command_substitution_body_parts", "extract_backticks",
    "extract_dollars", "normalize", "resolve_dir", "resolve_shell_token",
    "shell_quote_parts", "skip_prefix", "takes_value", "tokens",
}

guard_names = function_names(guard)
commit_names = function_names(commit)

unexpected = sorted((commit_names - guard_names) - COMMIT_ONLY)
resolved = sorted(name for name in COMMIT_ONLY if name in guard_names)

problems = []
if unexpected:
    problems.append(
        "the commit parser defines helpers the guard parser does not, and they are\n"
        "not on the owned list. Either give the guard parser the same capability or\n"
        "add the name to COMMIT_ONLY with a reason:\n  " + "\n  ".join(unexpected)
    )
if resolved:
    problems.append(
        "these names are listed as commit-parser-only but now exist in both.\n"
        "Drop them from COMMIT_ONLY, and check the two definitions agree:\n  "
        + "\n  ".join(resolved)
    )

# A capability taught to the guard parser that the commit parser also needs.
# Both must reason about no-execute shells, or the commit parser reports
# commits for commands that never ran.
for required in ("shell_invocation_is_noexec",):
    if required in guard_names and required not in commit_names:
        problems.append(
            f"{required} exists in the guard parser but not the commit parser; "
            "the two must agree about which shell invocations execute"
        )

if problems:
    for problem in problems:
        print(f"parser drift: {problem}", file=sys.stderr)
    raise SystemExit(1)

print(f"parser-drift: {len(guard_names & commit_names)} shared helpers, no drift")
PY
