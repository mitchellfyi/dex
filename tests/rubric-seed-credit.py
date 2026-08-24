#!/usr/bin/env python3
"""A rubric may not award points for something its own seed already has.

`grep -R "activity" "$ws/src"` reads as "did the agent write this". If the seed
already contains the word, the tree has been answering yes since before the
agent started, and those points are a fixed offset paid to every run — visible
in results/scores.tsv as a dimension that never moves. memory-respect's
correctness sat at 65 for all six of its recorded runs with 20 of that coming
from a string in the seed's own db.js, and its issue_detection paid 15 for a
tryOrLog call the seed's server.js already made.

The rule is only about *positive* checks. A negative one — `if ! grep -R "as
any"` — is asking whether the agent introduced something, and holding on a
clean seed is exactly right; those dimensions are built to fall. Seven of the
rubrics' greps are that shape and are left alone.

When a probe trips this, the fix is usually to ask the diff instead:

    if grep -q "activity" <<< "$(cd "$ws" && git diff HEAD -- src)"; then

which credits the word where it was added rather than where it was found.
"""

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCENARIOS = ROOT / "research/scenarios"

# if [!] grep -R "PATTERN" "$ws/SUBDIR"
GREP = re.compile(r'if\s+(!\s+)?grep\s+-R\s+"([^"]+)"\s+"\$ws/([^"]+)"')


def shell_unescape(pattern):
    r"""What grep receives after the shell reads the double-quoted argument.

    The rubrics write "a\\|b", which reaches grep as a\|b — BRE alternation.
    Collapsing it to a bare | instead makes grep hunt for a literal pipe, match
    nothing, and report every one of these probes as safe.
    """
    return pattern.replace("\\\\", "\\")


def main():
    if not SCENARIOS.is_dir():
        print("rubric seed credit: no scenarios to check")
        return 0

    failures = []
    checked = 0
    for rubric in sorted(SCENARIOS.glob("*/rubric.sh")):
        scenario = rubric.parent.name
        for number, line in enumerate(rubric.read_text().splitlines(), 1):
            match = GREP.search(line)
            if not match:
                continue
            negated, pattern, subdir = match.groups()
            if negated:
                continue
            target = rubric.parent / "seed" / subdir
            if not target.exists():
                continue
            checked += 1
            found = subprocess.run(
                ["grep", "-R", "-l", shell_unescape(pattern), str(target)],
                capture_output=True, text=True,
            )
            if found.returncode == 0:
                where = found.stdout.split("\n")[0]
                where = Path(where).relative_to(SCENARIOS) if where else subdir
                failures.append(
                    f"research/scenarios/{scenario}/rubric.sh:{number}: awards points for "
                    f"'{pattern}' in {subdir}, which the seed already has ({where}); "
                    f"ask the diff instead"
                )

    if failures:
        for failure in failures:
            print(failure, file=sys.stderr)
        return 1
    print(f"rubric seed credit: {checked} positive seed-relative check(s) ask for "
          f"something the seed does not already have")
    return 0


if __name__ == "__main__":
    sys.exit(main())
