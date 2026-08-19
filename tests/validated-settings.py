#!/usr/bin/env python3
"""Every knob with a validator must be read through it.

Some environment settings are dangerous when read raw. `--max-time 0` tells
curl to apply no limit at all, so a `DEXCODE_HTTP_TIMEOUT_SECONDS=0` that
reaches curl unchecked converts a nonsense setting into a request that hangs
forever. Dex already has the accessor that rejects that value; the bug is not
a missing check but a call site that went around it.

That is invisible to shellcheck and to the suite, because the raw read works
perfectly for every sane value. So the rule is structural: name the accessor,
name the variable it owns, and no other line may mention that variable.
"""

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# variable -> (accessor function, file that may define and read it)
OWNED_SETTINGS = {
    'DEXCODE_HTTP_TIMEOUT_SECONDS': ('dx_dexcode_http_timeout', 'lib/dexcode.sh'),
    'DEXCODE_UPLOAD_TIMEOUT_SECONDS': ('dx_dexcode_http_timeout', 'lib/dexcode.sh'),
    'DX_RTK_HTTP_TIMEOUT_SECONDS': ('dx_rtk_http_timeout', 'lib/rtk.sh'),
}


def tracked_shell_files():
    listed = subprocess.run(
        ['git', 'ls-files', '-z'],
        cwd=ROOT, capture_output=True, text=True, check=True,
    ).stdout.split('\0')
    files = []
    for name in listed:
        if not name:
            continue
        path = ROOT / name
        if not path.is_file():
            continue
        if name.endswith('.sh') or name in {'dx.sh'}:
            files.append(name)
    return sorted(files)


def main():
    failures = []
    for name in tracked_shell_files():
        # The test that proves the accessor works has to reach the variable.
        if name.startswith('tests/'):
            continue
        text = (ROOT / name).read_text(encoding='utf-8', errors='replace')
        for variable, (accessor, owner) in OWNED_SETTINGS.items():
            if name == owner or variable not in text:
                continue
            for number, line in enumerate(text.splitlines(), start=1):
                if variable not in line or line.lstrip().startswith('#'):
                    continue
                failures.append(
                    f'{name}:{number}: reads {variable} directly; '
                    f'call {accessor} so the value is validated first'
                )

    # And the accessor's own file must not read it outside the accessor.
    for variable, (accessor, owner) in OWNED_SETTINGS.items():
        text = (ROOT / owner).read_text(encoding='utf-8', errors='replace')
        body = re.search(
            rf'^{re.escape(accessor)}\(\) \{{\n(.*?)^\}}$',
            text, re.MULTILINE | re.DOTALL,
        )
        if not body:
            failures.append(f'{owner}: cannot find {accessor}; update tests/validated-settings.py')
            continue
        start = text[:body.start()].count('\n')
        end = start + text[body.start():body.end()].count('\n')
        for number, line in enumerate(text.splitlines(), start=1):
            if variable not in line or line.lstrip().startswith('#'):
                continue
            if start < number <= end + 1:
                continue
            failures.append(
                f'{owner}:{number}: reads {variable} outside {accessor}; '
                f'the accessor is the only place that value is checked'
            )

    if failures:
        for failure in sorted(failures):
            print(failure, file=sys.stderr)
        return 1
    print(f'validated settings: {len(OWNED_SETTINGS)} knob(s) read only through their accessor')
    return 0


if __name__ == '__main__':
    sys.exit(main())
