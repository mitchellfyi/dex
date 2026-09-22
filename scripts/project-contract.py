#!/usr/bin/env python3
"""Read one key out of a fenced YAML block in a `.dex/dex.md` section.

A project declares machine-readable facts about itself — which environment
variable its test runner reads for parallelism, which of its gates are heavy,
how to run a targeted test — in a fenced block under a named `##` heading.
Dex reads those declarations; it never writes them.

    ## Resources

    ```yaml
    parallelism_env: [PARALLEL_WORKERS]
    heavy_commands:
      - make check
      - bin/rails test
    targeted_tests: "bin/rails test {files}"
    ```

Only a flat mapping of scalars and lists has to work, which is why this is
forty lines of stdlib rather than a YAML dependency: nesting, anchors, block
scalars and multi-document streams are not part of the contract, and a block
that uses them is reported as malformed rather than half-understood.

    project-contract.py <dex-md> <section> <key>

Prints the value — one line per item for a list — and exits 0. Exit 1 means
the file, the section, the block or the key is absent, which every caller
treats as "this project declared nothing" and carries on. Exit 2 means the
block is there but is not a flat mapping, which is worth telling someone
about.
"""

import re
import sys
from pathlib import Path

HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*$")
FENCE = re.compile(r"^\s*(`{3,}|~{3,})\s*([A-Za-z0-9_+-]*)\s*$")
KEY_LINE = re.compile(r"^([A-Za-z_][A-Za-z0-9_-]*):\s*(.*)$")
ITEM_LINE = re.compile(r"^\s*-\s*(.*)$")

ABSENT = 1
MALFORMED = 2


def section_lines(text, section):
    """The lines under `## <section>`, up to the next heading of that depth.

    Fence state is tracked from the top of the file, because a `# comment`
    inside a fenced block is not a heading — and reading it as one ended the
    section mid-block, left the fence unterminated, and reported the whole
    contract as absent. The shipped `.dex/dex.md` template comments each key,
    so that was every generated contract.
    """
    wanted = section.strip().casefold()
    collected = None
    depth = 0
    fence = None
    for line in text.splitlines():
        marker = FENCE.match(line)
        if marker is not None:
            if fence is None:
                fence = marker.group(1)[0] * 3
            elif marker.group(1).startswith(fence):
                fence = None
            if collected is not None:
                collected.append(line)
            continue
        if fence is None:
            heading = HEADING.match(line)
            if heading:
                if collected is not None and len(heading.group(1)) <= depth:
                    break
                if collected is None and heading.group(2).strip().casefold() == wanted:
                    collected = []
                    depth = len(heading.group(1))
                    continue
        if collected is not None:
            collected.append(line)
    return collected


def fenced_block(lines):
    """The first fenced block in those lines."""
    fence = None
    body = []
    for line in lines:
        marker = FENCE.match(line)
        if fence is None:
            if marker:
                fence = marker.group(1)[0] * 3
            continue
        if marker and marker.group(1).startswith(fence):
            return body
        body.append(line)
    return None


def unquote(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    # An unquoted value may carry a trailing comment; a quoted one may not,
    # because the quotes already said where the value ends.
    return value.split(" #", 1)[0].rstrip()


def inline_list(value):
    inner = value[1:-1].strip()
    if not inner:
        return []
    return [unquote(item) for item in inner.split(",") if unquote(item)]


def parse_mapping(body):
    """A flat mapping of scalars and lists, or None when the block is not one."""
    mapping = {}
    pending = None
    for raw in body:
        line = raw.rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        item = ITEM_LINE.match(line)
        if item is not None:
            if pending is None:
                return None
            value = unquote(item.group(1))
            if value:
                mapping[pending].append(value)
            continue
        if line != line.lstrip():
            # Indented and not a list item: nesting, which the contract does
            # not cover.
            return None
        key = KEY_LINE.match(line)
        if key is None:
            return None
        name, value = key.group(1), key.group(2).strip()
        if not value:
            mapping[name] = []
            pending = name
            continue
        pending = None
        if value.startswith("[") and value.endswith("]"):
            mapping[name] = inline_list(value)
            continue
        cleaned = unquote(value)
        if cleaned == "":
            return None
        mapping[name] = cleaned
    return mapping


def main(argv):
    if len(argv) != 4:
        print(
            "Usage: project-contract.py <dex-md> <section> <key>",
            file=sys.stderr,
        )
        return MALFORMED
    contract_file, section, key = argv[1:]
    try:
        text = Path(contract_file).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ABSENT
    lines = section_lines(text, section)
    if lines is None:
        return ABSENT
    body = fenced_block(lines)
    if body is None:
        return ABSENT
    mapping = parse_mapping(body)
    if mapping is None:
        print(
            f"{contract_file}: the fenced block under '## {section}' is not a "
            "flat mapping of scalars and lists",
            file=sys.stderr,
        )
        return MALFORMED
    if key not in mapping:
        return ABSENT
    value = mapping[key]
    if isinstance(value, list):
        if not value:
            return ABSENT
        for item in value:
            print(item)
        return 0
    print(value)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
