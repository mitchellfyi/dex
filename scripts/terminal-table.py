#!/usr/bin/env python3
"""Shared plain-text tables for Dex's shell and Node commands."""

import json
import os
import re
import sys
import unicodedata


ANSI = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(?:\x07|\x1b\\))")


def clean_cell(value):
    text = ANSI.sub("", str(value) if value is not None else "-")
    return "".join(
        char if char == "\n" or unicodedata.category(char)[0] != "C" else " "
        for char in text
    )


def display_width(text):
    return sum(
        0 if unicodedata.combining(char) else
        2 if unicodedata.east_asian_width(char) in ("W", "F") else 1
        for char in text
    )


def wrap_cell(text, width):
    lines = []
    for paragraph in text.split("\n"):
        while display_width(paragraph) > width:
            used = 0
            end = 0
            for char in paragraph:
                size = display_width(char)
                if used + size > width:
                    break
                used += size
                end += 1
            boundary = paragraph.rfind(" ", 0, end + 1)
            if boundary > 0:
                lines.append(paragraph[:boundary])
                paragraph = paragraph[boundary + 1:]
            else:
                end = max(1, end)
                lines.append(paragraph[:end])
                paragraph = paragraph[end:]
        lines.append(paragraph)
    return lines


def render_table(headers, rows, width=None, right_align=()):
    headers = [clean_cell(value) for value in headers]
    # A null row is a rule between groups, not data: it carries no cells and is
    # skipped by every width and alignment calculation below.
    rows = [None if row is None else [clean_cell(value) for value in row] for row in rows]
    if not any(row is not None for row in rows):
        return ""
    if not headers or any(len(row) != len(headers) for row in rows if row is not None):
        raise ValueError("Table rows must match the headers.")
    if width is not None and (not isinstance(width, int) or width < 1):
        raise ValueError("Table width must be a positive integer.")

    widths = [
        max(display_width(line) for row in [headers, *(r for r in rows if r is not None)]
            for line in row[index].split("\n"))
        for index in range(len(headers))
    ]
    minimums = [min(size, max(4, min(12, display_width(label)))) for size, label in zip(widths, headers)]
    gaps = 2 * (len(headers) - 1)
    if width is not None and sum(minimums) + gaps > width:
        records = []
        for row in rows:
            if row is None:
                continue
            lines = []
            for label, value in zip(headers, row):
                if value:
                    lines.extend(wrap_cell(f"{label}: {value}" if label else value, width))
            records.append("\n".join(lines))
        return "\n\n".join(records)

    if width is not None:
        while sum(widths) + gaps > width:
            index = max((i for i in range(len(widths)) if widths[i] > minimums[i]), key=lambda i: widths[i])
            widths[index] -= 1

    def format_row(row, align=()):
        cells = [wrap_cell(value, size) for value, size in zip(row, widths)]
        lines = []
        for line_index in range(max(map(len, cells))):
            parts = []
            for index, (cell, size) in enumerate(zip(cells, widths)):
                text = cell[line_index] if line_index < len(cell) else ""
                padding = " " * (size - display_width(text))
                parts.append(padding + text if index in align else text + padding)
            lines.append("  ".join(parts).rstrip())
        return lines

    lines = format_row(headers, right_align)
    rule = "  ".join("-" * size for size in widths).rstrip()
    lines.append(rule)
    for row in rows:
        if row is None:
            # Never open or double a rule: a group break only separates rows.
            if lines and lines[-1] != rule:
                lines.append(rule)
            continue
        lines.extend(format_row(row, right_align))
    return "\n".join(lines)


def terminal_columns():
    try:
        return os.get_terminal_size(sys.stdout.fileno()).columns or None
    except OSError:
        return None


def main():
    data = json.load(sys.stdin)
    output = render_table(data["headers"], data["rows"],
                          data.get("width", terminal_columns()), data.get("right_align", ()))
    if output:
        print(output)


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        sys.exit(0)
