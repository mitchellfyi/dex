#!/usr/bin/env python3
"""Require every CCR node suite to sandbox the router home.

`scripts/ccr/state.cjs` resolves its root as `DEX_ROUTER_HOME` or, failing
that, `~/.dex/router`; `native.cjs` fills unset client paths from `~/.claude`
and `~/.codex`. The safe location is a default, not a requirement, so a suite
that reaches those modules without setting `DEX_ROUTER_HOME` reads and writes
the developer's live install — the router config, the ownership record, and the
two files that let them run claude and codex at all. An agent that corrupts
those takes away the ability to run any local agent, including one that could
repair the damage.

`tests/run-all.sh` hands every test a fake HOME and `tests/ccr-routing-test.sh`
pins a sandbox of its own, so both documented ways in are covered. A bare
`node --test tests/ccr-<name>.test.cjs` is not, and that is what an agent
iterating on one suite actually types.

The rule is deliberately blunt: every suite, not only the ones that touch state
today. Deciding which calls are safe means tracking a require graph and which
functions resolve a home path, and that judgement goes stale the first time a
module grows a new caller. One exported variable per file does not.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CCR = ROOT / "scripts" / "ccr"
REQUIRE = re.compile(r"""require\(\s*['"]([^'"]+)['"]\s*\)""")


def loads_router_code(source):
    return any(
        target.startswith(".") and (CCR / pathlib.PurePosixPath(target).name).is_file()
        for target in REQUIRE.findall(source)
    )


def main():
    failures = []
    for test in sorted((ROOT / "tests").glob("ccr-*.test.cjs")):
        source = test.read_text()
        if loads_router_code(source) and "DEX_ROUTER_HOME" not in source:
            failures.append(test.relative_to(ROOT))
    for path in failures:
        print(
            f"{path}: loads scripts/ccr code without setting DEX_ROUTER_HOME. Point it at "
            f"a temporary directory the way tests/ccr-native.test.cjs does, or running this "
            f"suite with `node --test` edits the live router install.",
            file=sys.stderr,
        )
    if failures:
        return 1
    print("ccr test isolation: every CCR suite sandboxes DEX_ROUTER_HOME")
    return 0


if __name__ == "__main__":
    sys.exit(main())
