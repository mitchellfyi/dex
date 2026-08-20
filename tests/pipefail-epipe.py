#!/usr/bin/env python3
"""A pipeline's exit status is not the answer when its consumer stops early.

Under `set -o pipefail`, `echo "$out" | grep -q PATTERN` does not report
whether the pattern was found. grep -q exits at the first match; the producer
is left writing into a closed pipe, dies of EPIPE with status 141, and pipefail
reports that. The pipeline says "no" about a value that matched — decided by
whether the write happened to finish first.

It reproduces reliably whenever the match is early and the payload is large,
which is the normal shape of the thing being asked: does this --help mention a
flag, does this test output say "pass". Dex shipped two of these. One made
`dx` refuse to run against a Codex CLI that had the flag it said was missing.
The other let a research rubric score a passing scenario as failing.

So the rule is structural. In a file that sets pipefail — or in lib/, which is
sourced into shells that do — a producer that reads a variable or a file may
not be piped into a consumer that can exit before it finishes. Use a
here-string: `grep -q PATTERN <<< "$out"` asks the same question with nothing
to kill.

Producers that stop on their own after one line, like `find -print -quit`, are
not flagged: there is no remaining write to fail.
"""

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Consumers that can exit before the producer is done writing.
EARLY_EXIT = r"""(?:grep\s+-[a-zA-Z]*[qm][a-zA-Z]*\b|head\b(?!\s*-c\s*0))"""

# Producers that keep writing: an in-memory value, or a whole file.
UNBOUNDED = r"""(?:echo\s+"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"|printf\s+'%s(?:\\n)?'\s+"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"|cat\s+"[^"]+"|grep\s+(?:-[a-zA-Z]+\s+)*(?:--\s+)?(?:'[^']*'|"[^"]*")\s+"\$[A-Za-z_][A-Za-z0-9_]*")"""

PIPELINE = re.compile(UNBOUNDED + r"\s*\|\s*" + EARLY_EXIT)

# Only matters where the pipeline's status is read as a boolean.
STATUS_IS_THE_ANSWER = re.compile(r"^\s*(?:if|elif|while|until)\s|^\s*!\s|&&\s*!\s|\|\|\s*!\s")


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
        # A file need not set pipefail to run under it. lib/ is sourced by every
        # entry point, and research/run.sh sets pipefail and then sources
        # lib/score.sh, which sources each scenario's rubric — so a rubric's
        # pipelines run under pipefail without saying so anywhere in the file.
        # That is where the mis-scoring lived.
        sourced_into_pipefail = (
            name.startswith("lib/")
            or name.startswith("research/lib/")
            or (name.startswith("research/scenarios/") and name.endswith("rubric.sh"))
        )
        if "pipefail" not in text and not sourced_into_pipefail:
            continue
        for number, line in enumerate(text.splitlines(), start=1):
            if line.lstrip().startswith("#"):
                continue
            if PIPELINE.search(line) and STATUS_IS_THE_ANSWER.search(line):
                failures.append(
                    f"{name}:{number}: this pipeline's status is read as an answer, but its "
                    f"consumer can exit first and leave the producer to die of EPIPE under "
                    f"pipefail; use a here-string instead\n      {line.strip()[:100]}"
                )

    if failures:
        for failure in failures:
            print(failure, file=sys.stderr)
        return 1
    print("pipefail epipe: no early-exit pipeline decides a question under pipefail")
    return 0


if __name__ == "__main__":
    sys.exit(main())
