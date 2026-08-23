#!/usr/bin/env python3
"""A function whose answer is its stdout must say everything else on stderr.

lib/output.sh splits the helpers by stream on purpose: dx_error and dx_warn go
to stderr, while dx_info, dx_ok, dx_done and dx_skip go to stdout because most
of their callers are printing progress a user should see.

The two do not mix. When a function returns its value by printing it, every
caller reads it through `$( )` — and a dx_info written on that path is captured
along with the value and thrown away. `dx --agent gpt4` reported "Unsupported
agent: gpt4" and stopped there, because the next line, the one naming the
agents that do work, went into the command substitution instead of the
terminal.

Nothing else notices: the value is still correct, the exit status is still
right, and the missing line looks like a line nobody wrote. So the rule is
structural — inside a function that some caller captures, a stdout helper needs
an explicit `>&2`.
"""

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

STDOUT_HELPERS = ("dx_info", "dx_ok", "dx_done", "dx_skip")
FUNCTION_RE = re.compile(r"^([a-zA-Z_][a-zA-Z0-9_]*)\(\) *\{\s*$")


def tracked_shell_files():
    listed = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=ROOT, capture_output=True, text=True, check=True,
    ).stdout.split("\0")
    return sorted(
        name for name in listed
        if name and (name.endswith(".sh") or name == "dx.sh")
        and not name.startswith(("tests/", "research/"))
        and (ROOT / name).is_file()
    )


def functions(name, text):
    """Yield (function_name, first_body_line_number, body_lines)."""
    lines = text.splitlines()
    start = function = None
    for index, line in enumerate(lines):
        if start is None:
            match = FUNCTION_RE.match(line)
            if match:
                start, function = index, match.group(1)
            continue
        if line == "}":
            yield function, start + 2, lines[start + 1:index]
            start = None


# The check above rests on lib/output.sh splitting its helpers by stream. If
# dx_error ever stopped writing to stderr, every guarded call site would start
# contaminating its own return value and this file would still pass — so the
# premise is asserted rather than assumed.
#
# research/ has the same arrangement reached differently: every log_* helper
# routes through one _log, which writes to stderr. That is why research is not
# scanned above — nothing there prints guidance to stdout — and it is only true
# while _log keeps the redirect.
STREAM_PREMISES = (
    ("lib/output.sh", "dx_error", True),
    ("lib/output.sh", "dx_warn", True),
    ("lib/output.sh", "dx_info", False),
    ("lib/output.sh", "dx_ok", False),
    ("lib/output.sh", "dx_done", False),
    ("lib/output.sh", "dx_skip", False),
    ("research/lib/common.sh", "_log", True),
)


def helper_body(text, helper):
    """The lines of a shell function definition, or None."""
    lines = text.splitlines()
    for index, line in enumerate(lines):
        if not line.startswith(helper + "()"):
            continue
        if line.rstrip().endswith("}"):
            return [line]          # a one-liner, as lib/output.sh writes them
        body = []
        for follow in lines[index + 1:]:
            if follow == "}":
                return body
            body.append(follow)
        return body
    return None


def check_premises():
    """The helper definitions must still write where this check assumes."""
    problems = []
    for name, helper, to_stderr in STREAM_PREMISES:
        text = (ROOT / name).read_text(encoding="utf-8", errors="replace")
        body = helper_body(text, helper)
        if body is None:
            problems.append(f"{name}: cannot find {helper}; update tests/captured-stdout.py")
            continue
        if (">&2" in "\n".join(body)) != to_stderr:
            expected = "stderr" if to_stderr else "stdout"
            problems.append(
                f"{name}: {helper} no longer writes to {expected}; the rule this file "
                f"enforces rests on that"
            )
    return problems


def main():
    files = tracked_shell_files()
    corpus = {name: (ROOT / name).read_text(encoding="utf-8", errors="replace")
              for name in files}
    everything = "\n".join(corpus.values())

    failures = []
    for name, text in corpus.items():
        for function, first_line, body in functions(name, text):
            captured = re.search(r"\$\(\s*" + re.escape(function) + r"(?![\w-])", everything)
            if not captured:
                continue
            for offset, source in enumerate(body):
                stripped = source.strip()
                if stripped.startswith("#") or ">&2" in source:
                    continue
                for helper in STDOUT_HELPERS:
                    if re.search(r"(^|[;&|(\s])" + helper + r"(?![\w-])", source):
                        failures.append(
                            f"{name}:{first_line + offset}: {function} returns its value on "
                            f"stdout and callers capture it, so this {helper} line is "
                            f"swallowed; add >&2"
                        )

    failures.extend(check_premises())

    if failures:
        for failure in failures:
            print(failure, file=sys.stderr)
        return 1
    print(
        "captured stdout: helpers write where they should, and no value-returning "
        "function writes guidance onto its own answer"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
