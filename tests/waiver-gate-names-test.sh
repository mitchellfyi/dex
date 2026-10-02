#!/usr/bin/env bash
set -euo pipefail

# Every gate the shipped prompts, skills and docs tell an agent to waive or
# override must be one `dx control` accepts. Phase 0 once named a
# `setup.ticket-ownership` waiver that dx_override_gate_supported rejected, so
# an agent following the prompt had no way to record it.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
export DEX_DIR="$ROOT"
# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

GATES=$(python3 - "$ROOT" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
gate = r'[a-z][a-z0-9]*(?:\.[a-z0-9][a-z0-9-]*)+'
patterns = [
    re.compile(r'\bwaive\s+`?(' + gate + r')\b'),
    re.compile(r'\boverride\s+`?(' + gate + r')\b'),
    re.compile(r'`(' + gate + r')`\s+waiver'),
]
files = [root / 'AGENTS.md']
files += sorted((root / 'prompts').rglob('*.md'))
files += sorted(p for p in (root / 'skills').glob('*/SKILL.md') if p.parent.name != 'synced')
files += sorted((root / 'docs').glob('*.md'))
seen = {}
for path in files:
    for number, line in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
        for pattern in patterns:
            for match in pattern.finditer(line):
                seen.setdefault(match.group(1), f'{path.relative_to(root)}:{number}')
for name, where in sorted(seen.items()):
    print(f'{name}\t{where}')
PY
)

[[ -n "$GATES" ]] || assert_at $LINENO
# The scan has to find the gates it exists for, or it proves nothing.
[[ "$GATES" == *$'setup.ticket-ownership\t'* ]] || assert_at $LINENO
[[ "$GATES" == *$'review.clean-passes\t'* ]] || assert_at $LINENO

unsupported=0
while IFS=$'\t' read -r gate where; do
  if ! dx_override_gate_supported "$gate"; then
    printf 'unsupported gate %s named at %s\n' "$gate" "$where" >&2
    unsupported=$((unsupported + 1))
  fi
done <<< "$GATES"
[[ "$unsupported" -eq 0 ]] || assert_at $LINENO

printf '%s\n' "waiver-gate-names-test: ok"
