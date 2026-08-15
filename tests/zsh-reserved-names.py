#!/usr/bin/env python3
"""Reject zsh-special parameter names in the files zsh actually sources.

`dx.sh` is zsh, and it sources `lib/`, so every function in there runs under
zsh even though the files are written to be bash-compatible. zsh marks a set
of parameters special, and reusing one of those names as an ordinary variable
fails in ways bash never shows:

  local status=0      # zsh: read-only, the declaration errors outright
  local path="$1"     # zsh: `path` is tied to PATH, so this replaces PATH for
                      # the rest of the function and the next command is
                      # "command not found"

Both shipped. `dx login` printed "read-only variable: status" on every run, and
dx_lock_path_age_seconds returned 127 for every input because python3 was no
longer on its PATH. shellcheck cannot see either one — the names are perfectly
ordinary in bash — and the test suite runs under bash, so neither could it.

`hooks/` and `bin/` are executed with a bash shebang and are deliberately not
scanned.

Usage: python3 tests/zsh-reserved-names.py [--list]
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Parameters zsh treats specially. Declaring one `local`, or assigning to it,
# either fails or quietly changes how the shell resolves commands and paths.
RESERVED = {
    # read-only
    "status", "pipestatus", "ARGC", "LINENO", "ZSH_SUBSHELL", "EPOCHSECONDS",
    "TRY_BLOCK_ERROR", "zsh_eval_context", "funcstack", "functrace",
    # tied to a colon-separated path, so assigning a string rewrites it
    "path", "cdpath", "fpath", "manpath", "mailpath", "module_path",
    "fignore", "psvar", "watch",
    # special mappings and arrays the shell itself maintains
    "options", "functions", "aliases", "commands", "parameters", "signals",
    "dirstack", "jobstates", "jobtexts", "jobdirs", "nameddirs",
    "historywords", "galiases", "dis_aliases", "dis_functions",
    # magic scalars
    "RANDOM", "SECONDS", "histchars", "HISTCHARS", "langinfo", "termcap",
    "terminfo", "usergroups",
}

DECL = re.compile(r"^\s*(?:local|typeset|declare)\s+(.*)$")
# A name being declared, with or without a value: `-r foo=1 bar` -> foo, bar
DECL_NAME = re.compile(r"(?<![\w-])([A-Za-z_][A-Za-z0-9_]*)(?==|\s|$)")
NAME_AT = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)=(?!=)")
HEREDOC = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")


def assignments(line: str) -> list[str]:
    """Names assigned at the start of a statement, ignoring quoted text.

    `dx_log "...; status=${phase_status}; ..."` assigns nothing — the text is
    an argument. Only an assignment sitting where a command could start counts.
    """
    names: list[str] = []
    in_single = in_double = False
    statement_start = True
    index = 0

    while index < len(line):
        char = line[index]
        if char == "\\" and not in_single:
            index += 2
            continue
        if char == "'" and not in_double:
            in_single = not in_single
        elif char == '"' and not in_single:
            in_double = not in_double
        elif not in_single and not in_double:
            if char in ";&|(":
                statement_start = True
                index += 1
                continue
            if not char.isspace():
                if statement_start:
                    match = NAME_AT.match(line, index)
                    if match:
                        names.append(match.group(1))
                    statement_start = False
        index += 1

    return names


def scan(path: pathlib.Path) -> list[tuple[int, str, str]]:
    findings: list[tuple[int, str, str]] = []
    heredoc_end: str | None = None

    for number, raw in enumerate(path.read_text().splitlines(), 1):
        # Embedded python, awk and JSON live in heredocs and have their own
        # namespaces; `path = ...` in a python block is not a shell variable.
        if heredoc_end is not None:
            if raw.strip() == heredoc_end:
                heredoc_end = None
            continue
        opened = HEREDOC.search(raw)
        if opened:
            heredoc_end = opened.group(2)
            # The line that opens a heredoc can still assign, so fall through.

        line = raw.strip()
        if not line or line.startswith("#"):
            continue

        declaration = DECL.match(raw)
        if declaration:
            for name in DECL_NAME.findall(declaration.group(1)):
                if name in RESERVED:
                    findings.append((number, name, raw.rstrip()))

        for name in assignments(raw):
            if name in RESERVED:
                findings.append((number, name, raw.rstrip()))

    return findings


def main() -> int:
    targets = [ROOT / "dx.sh"] + sorted((ROOT / "lib").glob("*.sh"))

    if "--list" in sys.argv:
        print("\n".join(sorted(RESERVED)))
        return 0

    total = 0
    for path in targets:
        if not path.is_file():
            continue
        for number, name, text in scan(path):
            rel = path.relative_to(ROOT)
            print(f"{rel}:{number}: `{name}` is special in zsh: {text.strip()}")
            total += 1

    if total:
        print(
            f"\n{total} zsh-special parameter name(s) used as ordinary "
            f"variables.\nRename them; zsh sources these files even though "
            f"they are written for bash.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
