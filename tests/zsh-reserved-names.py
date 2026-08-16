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

Covered shapes: declarations (local/typeset/declare/export/readonly), plain
and arithmetic assignments, command-prefix assignment runs (`a=1 b=2 cmd`),
`for` loop variables, and `read` targets. Known limitation: assignments inside
a double-quoted command substitution (`x="$(path=/y; ...)"`) are not seen.

`hooks/` and `bin/` are executed with a bash shebang and are deliberately not
scanned.

Usage: python3 tests/zsh-reserved-names.py [--list]
"""

from __future__ import annotations

import pathlib
import re
import shlex
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

DECL = re.compile(r"^\s*(?:local|typeset|declare|export|readonly)\s+(.*)$")
NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
NAME_AT = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)(?:\+|\[[^\]]*\])?=(?!=)")
# A real heredoc opener. The lookarounds keep `<<<word` here-strings from
# matching as `<<word`, which used to swallow every following line while the
# scanner waited for a terminator that never came.
HEREDOC = re.compile(r"(?<!<)<<-?(?!<)\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
FOR_VAR = re.compile(r"(?:^|[;&|{(]|\bdo\b|\bthen\b|\belse\b)\s*for\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:\bin\b|;|$)")
ARITH_ASSIGN = re.compile(r"\(\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*(?:[-+*/%&|^]|<<|>>)?=(?!=)")
READ_CMD = re.compile(
    r"(?:^\s*|[;&|{(]\s*|\b(?:do|then|else|while|until)\s+)(?:IFS=\S*\s+)?read\s+(.*)$"
)
KEYWORDS = {"then", "do", "else", "elif", "if", "while", "until", "{"}


def strip_quotes(line: str) -> str:
    """Blank out single- and double-quoted regions, preserving length."""
    out: list[str] = []
    in_single = in_double = False
    index = 0
    while index < len(line):
        char = line[index]
        if char == "\\" and not in_single and index + 1 < len(line):
            out.append("  ")
            index += 2
            continue
        if char == "'" and not in_double:
            in_single = not in_single
            out.append(" ")
        elif char == '"' and not in_single:
            in_double = not in_double
            out.append(" ")
        elif in_single or in_double:
            out.append(" ")
        else:
            out.append(char)
        index += 1
    return "".join(out)


def assignments(line: str) -> list[str]:
    """Names assigned where a command could start, ignoring quoted text.

    `dx_log "...; status=${phase_status}; ..."` assigns nothing — the text is
    an argument. A run of prefix assignments (`a=1 b=2 cmd`) flags every name
    in the run, not only the first.
    """
    names: list[str] = []
    stripped = strip_quotes(line)
    statement_start = True
    index = 0

    while index < len(stripped):
        char = stripped[index]
        if char in ";&|(":
            statement_start = True
            index += 1
            continue
        if char.isspace():
            index += 1
            continue
        # A word begins here.
        end = index
        while end < len(stripped) and not stripped[end].isspace() and stripped[end] not in ";&|(":
            end += 1
        word = stripped[index:end]
        if statement_start:
            match = NAME_AT.match(word)
            if match:
                names.append(match.group(1))
                # Stay in prefix position: `status=1 path=/x cmd` assigns both.
                index = end
                continue
            if word in KEYWORDS:
                index = end
                continue
            statement_start = False
        index = end

    return names


def declaration_names(remainder: str) -> list[str]:
    """Names declared by a local/typeset/declare/export/readonly line.

    Quoted values are stripped first so `local msg="the status is fine"` does
    not flag the word inside the string.
    """
    names: list[str] = []
    for token in strip_quotes(remainder).split():
        if token.startswith("-"):
            continue
        candidate = token.split("=", 1)[0]
        if NAME.match(candidate):
            names.append(candidate)
    return names


def read_targets(remainder: str) -> list[str]:
    # Only the current command's arguments; shlex keeps empty quoted values
    # ("" as -d's argument) as real tokens where naive quote-stripping lost
    # them and let the option eat the following name.
    remainder = re.split(r"[;|&]", remainder, maxsplit=1)[0]
    try:
        # comments=True drops a trailing " # …" so its words are not targets.
        tokens = shlex.split(remainder, comments=True)
    except ValueError:
        return []
    names: list[str] = []
    index = 0
    value_options = {"-d", "-n", "-N", "-p", "-t", "-u", "-i", "-k"}
    while index < len(tokens):
        token = tokens[index]
        if token in value_options:
            index += 2
            continue
        if token == "-a" and index + 1 < len(tokens):
            names.append(tokens[index + 1])
            index += 2
            continue
        if token.startswith("-"):
            index += 1
            continue
        if NAME.match(token):
            names.append(token)
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

        found: list[str] = []
        declaration = DECL.match(raw)
        if declaration:
            found.extend(declaration_names(declaration.group(1)))
        found.extend(assignments(raw))

        stripped = strip_quotes(raw)
        for match in FOR_VAR.finditer(stripped):
            found.append(match.group(1))
        for match in ARITH_ASSIGN.finditer(stripped):
            found.append(match.group(1))
        read_match = READ_CMD.search(raw)
        if read_match:
            found.extend(read_targets(read_match.group(1)))

        seen: set[str] = set()
        for name in found:
            if name in RESERVED and name not in seen:
                seen.add(name)
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
