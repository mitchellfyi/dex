#!/usr/bin/env python3
"""A pipeline's exit status is not the answer when a later stage stops early.

Under `set -o pipefail`, `echo "$out" | grep -q PATTERN` does not report
whether the pattern was found. grep -q exits at the first match; the producer
is left writing into a closed pipe, dies of EPIPE with status 141, and pipefail
reports that. The pipeline says "no" about a value that matched — decided by
whether the write happened to finish first.

It reproduces reliably whenever the match is early and the payload is large,
which is the normal shape of the thing being asked: does this --help mention a
flag, does this test output say "pass". Dex shipped two of these. One made `dx`
refuse to run against a Codex CLI that had the flag it said was missing. The
other let a research rubric score a passing scenario as failing.

So the rule is structural. In a file that sets pipefail — or in one sourced
into a shell that does — a stream that can still be writing may not feed a
stage that can exit before it finishes, when the pipeline's status is what the
line is asking about. Use a here-string, or take the first line by trimming.

Intermediate filters are followed through: `echo "$x" | sed … | head -1` is the
same hazard as the two-stage form, because sed is still relaying when head
leaves. Producers that stop on their own after one line, like `find -print
-quit`, are not flagged — there is no remaining write to fail.
"""

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# A stage that can exit before what feeds it has finished.
EARLY_EXIT = re.compile(
    r"""^(?:grep\s+(?:-[a-zA-Z]*[qm][a-zA-Z]*\b|-[a-zA-Z]+\s+-[qm]\b)|head\b(?!\s*-c\s*0))"""
)

# A source that can still be writing: an in-memory value, or a whole file.
UNBOUNDED_SOURCE = re.compile(
    r"""^(?:echo\s+"?\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"?"""
    r"""|printf\s+'%s(?:\\n)?'\s+"?\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"?"""
    r"""|cat\s+["$]"""
    # head/tail read a file and emit several lines; they are as able to be
    # mid-write as cat is when something downstream leaves.
    r"""|head\s+-[0-9n]|tail\s+-[0-9n]"""
    r"""|grep\s+(?:-[a-zA-Z]+\s+)*(?:--\s+)?(?:'[^']*'|"[^"]*"|[^\s|'"]+)\s+["$])"""
)

# Filters that relay a stream rather than ending it, so the hazard passes through.
RELAY = re.compile(r"""^(?:sed\b|awk\b|tr\b|cut\b|sort\b|uniq\b|grep\b|rev\b|tail\b)""")

# Only matters where the pipeline's status is what the line is asking.
STATUS_IS_THE_ANSWER = re.compile(r"^\s*(?:if|elif|while|until)\s|^\s*!\s|&&\s*!\s|\|\|\s*!\s")

# Files with no `set` line of their own that still run under pipefail: lib/ is
# sourced by every entry point, and research/run.sh sets pipefail and then
# sources lib/score.sh, which sources each scenario's rubric.
INHERITS_PIPEFAIL = (
    lambda name: name.startswith("lib/")
    or name.startswith("research/lib/")
    or (name.startswith("research/scenarios/") and name.endswith("rubric.sh"))
)


def split_stages(line):
    """Split a line into pipeline stages, ignoring `||` and quoted bars."""
    stages = []
    current = []
    quote = None
    index = 0
    while index < len(line):
        char = line[index]
        if quote:
            current.append(char)
            if char == quote:
                quote = None
        elif char in "'\"":
            quote = char
            current.append(char)
        elif char == "|":
            if index + 1 < len(line) and line[index + 1] == "|":
                # `||` is not a pipe; it also ends the current pipeline.
                stages.append("".join(current))
                current = []
                index += 2
                continue
            stages.append("".join(current))
            current = []
        else:
            current.append(char)
        index += 1
    stages.append("".join(current))
    return [stage.strip() for stage in stages if stage.strip()]


def hazardous(line):
    """True when an unbounded source reaches a stage that can exit early."""
    stages = split_stages(line)
    if len(stages) < 2:
        return False
    # Drop a leading keyword so the first stage reads as a command.
    first = re.sub(r"^(?:if|elif|while|until)\s+|^!\s*", "", stages[0]).strip()
    carrying = bool(UNBOUNDED_SOURCE.match(first))
    for stage in stages[1:]:
        stage = re.sub(r"^!\s*", "", stage).strip()
        if carrying and EARLY_EXIT.match(stage):
            return True
        if not RELAY.match(stage):
            # Something that is not a pass-through filter ends the chain.
            carrying = False
    return False


def tracked_shell_files():
    listed = subprocess.run(
        ["git", "ls-files", "-z"], cwd=ROOT, capture_output=True, text=True, check=True
    ).stdout.split("\0")
    return sorted(
        name for name in listed
        if name and (name.endswith(".sh") or name.endswith(".zsh"))
        and (ROOT / name).is_file()
    )


def main():
    failures = []
    for name in tracked_shell_files():
        text = (ROOT / name).read_text(encoding="utf-8", errors="replace")
        if "pipefail" not in text and not INHERITS_PIPEFAIL(name):
            continue
        for number, line in enumerate(text.splitlines(), start=1):
            if line.lstrip().startswith("#"):
                continue
            if STATUS_IS_THE_ANSWER.search(line) and hazardous(line):
                failures.append(
                    f"{name}:{number}: this pipeline's status is read as an answer, but a "
                    f"later stage can exit first and leave the producer to die of EPIPE "
                    f"under pipefail; use a here-string instead\n      {line.strip()[:100]}"
                )

    if failures:
        for failure in failures:
            print(failure, file=sys.stderr)
        return 1
    print("pipefail epipe: no early-exit pipeline decides a question under pipefail")
    return 0


if __name__ == "__main__":
    sys.exit(main())
