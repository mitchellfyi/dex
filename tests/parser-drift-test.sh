#!/usr/bin/env bash
set -euo pipefail

# Dex reads a shell command twice, for two different questions:
#
#   hooks/guard-handler.py      does this command do something worth flagging?
#   hooks/git-commit-target.py  did this command create a commit, and where?
#
# The reading itself is one implementation, hooks/shell_parse.py. It used to be
# copied into both hooks, and the copies drifted: one learned to expand
# `${VAR:+…}`, to track `export`/`declare` assignments, to keep a backslash
# inside double quotes, and to hand an xargs item over as a single argument,
# while the other kept the older answers. Nothing announced the divergence,
# because both files still parsed and both suites still passed.
#
# This test keeps them from growing apart again. A hook that redefines a name
# shell_parse.py already owns shadows the shared one for itself alone, which is
# how a second copy starts. If a primitive genuinely needs to differ per hook,
# it needs a different name and a reason.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT" <<'PY'
import ast
import sys
from pathlib import Path

root = Path(sys.argv[1])
shared_path = root / "hooks/shell_parse.py"
hooks = {
    "hooks/guard-handler.py": root / "hooks/guard-handler.py",
    "hooks/git-commit-target.py": root / "hooks/git-commit-target.py",
}

shared_source = shared_path.read_text(encoding="utf-8")
shared_tree = ast.parse(shared_source)


def top_level_names(tree):
    names = set()
    for node in tree.body:
        if isinstance(node, ast.FunctionDef):
            names.add(node.name)
        elif isinstance(node, ast.Assign):
            names.update(t.id for t in node.targets if isinstance(t, ast.Name))
    return names


shared_defined = top_level_names(shared_tree)
shared_all = set()
for node in shared_tree.body:
    if isinstance(node, ast.Assign) and any(
        isinstance(t, ast.Name) and t.id == "__all__" for t in node.targets
    ):
        shared_all = {
            element.value
            for element in node.value.elts
            if isinstance(element, ast.Constant)
        }

problems = []

# __all__ is what `from shell_parse import *` actually exports, so a name that
# is defined but unlisted is invisible to the hooks even though it looks shared.
missing_from_all = sorted(shared_defined - shared_all - {"__all__"})
if missing_from_all:
    problems.append(
        "hooks/shell_parse.py defines these but does not export them in __all__,\n"
        "so `import *` will not reach them:\n  " + "\n  ".join(missing_from_all)
    )
exported_but_undefined = sorted(shared_all - shared_defined)
if exported_but_undefined:
    problems.append(
        "hooks/shell_parse.py lists these in __all__ but does not define them:\n  "
        + "\n  ".join(exported_but_undefined)
    )

for label, path in hooks.items():
    tree = ast.parse(path.read_text(encoding="utf-8"))
    shadowed = sorted(top_level_names(tree) & shared_all)
    if shadowed:
        problems.append(
            f"{label} redefines names hooks/shell_parse.py already owns. That copy\n"
            "only applies to this hook, which is how the two parsers drifted apart\n"
            "before. Use the shared one, or rename and say why it must differ:\n  "
            + "\n  ".join(shadowed)
        )
    imports_shared = any(
        isinstance(node, ast.ImportFrom) and node.module == "shell_parse"
        for node in ast.walk(tree)
    )
    if not imports_shared:
        problems.append(f"{label} no longer imports from hooks/shell_parse.py")

if problems:
    for problem in problems:
        print(f"parser drift: {problem}", file=sys.stderr)
    raise SystemExit(1)

print(f"parser-drift: {len(shared_all)} shared names, no local copies")
PY
