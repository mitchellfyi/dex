#!/usr/bin/env python3
"""Summarise what Dex-launched sessions cost this host right now.

Invoked by `dx status`. Reads one `ps` listing, groups every process under
the `claude` or `codex` session that started it, and reports the totals a
person needs before deciding how many lifecycles this machine can carry.
Everything is best-effort: a host that cannot answer prints nothing rather
than an error.
"""

import os
import re
import subprocess
import sys
from collections import defaultdict

SESSION = re.compile(r"(^|/)(claude|codex)(\s|$)")
SIDECAR = re.compile(r"mcp|browser-mcp|language-server|tsserver|pyright|rust-analyzer|gopls|codegraph", re.I)
BROWSER = re.compile(r"chrom(e|ium)|Chrome for Testing", re.I)
TEST_RUNNER = re.compile(
    r"\b(jest|vitest|pytest|unittest|cargo test|go test|rspec|mocha|playwright test|next dev|vite\b|webpack|tsc\b)",
    re.I,
)


def processes():
    """Return {pid: (ppid, rss_mb, command)} from one ps listing."""
    output = subprocess.run(
        ["ps", "-axo", "pid=,ppid=,rss=,args="],
        capture_output=True, text=True, check=True,
    ).stdout
    table = {}
    for line in output.splitlines():
        parts = line.split(None, 3)
        if len(parts) < 4:
            continue
        try:
            pid, ppid, rss = int(parts[0]), int(parts[1]), int(parts[2])
        except ValueError:
            continue
        table[pid] = (ppid, rss // 1024, parts[3])
    return table


def descendants(table, root):
    children = defaultdict(list)
    for pid, (ppid, _, _) in table.items():
        children[ppid].append(pid)
    stack, seen = [root], []
    while stack:
        pid = stack.pop()
        for child in children.get(pid, []):
            if child not in seen:
                seen.append(child)
                stack.append(child)
    return seen


def session_roots(table):
    """Session processes whose parent is not itself a session process."""
    roots = []
    for pid, (ppid, _, command) in table.items():
        if not SESSION.search(command.split()[0] if command else ""):
            continue
        parent = table.get(ppid)
        if parent and SESSION.search(parent[2].split()[0] if parent[2] else ""):
            continue
        roots.append(pid)
    return sorted(roots)


def main():
    try:
        table = processes()
    except (OSError, subprocess.SubprocessError):
        return 0
    roots = session_roots(table)
    session_mb = sidecar_mb = browser_mb = runner_mb = 0
    sidecars = browsers = runners = 0
    for root in roots:
        session_mb += table[root][1]
        for pid in descendants(table, root):
            _, rss, command = table[pid]
            if BROWSER.search(command):
                browsers += 1
                browser_mb += rss
            elif SIDECAR.search(command):
                sidecars += 1
                sidecar_mb += rss
            elif TEST_RUNNER.search(command):
                runners += 1
                runner_mb += rss
            else:
                session_mb += rss
    # Browsers left behind by a session that has since exited.
    orphan_browsers = sum(
        1 for pid, (ppid, _, command) in table.items()
        if BROWSER.search(command) and "Helper" not in command
        and ppid in (0, 1)
    )
    total_mb = session_mb + sidecar_mb + browser_mb + runner_mb
    print(f"  Sessions:   {len(roots)} provider session(s) using {total_mb} MB in total")
    print(f"  Sidecars:   {sidecars} MCP/LSP process(es), {sidecar_mb} MB")
    print(f"  Browsers:   {browsers} process(es), {browser_mb} MB"
          + (f"; {orphan_browsers} orphaned" if orphan_browsers else ""))
    if runners:
        print(f"  Runners:    {runners} test/build process(es), {runner_mb} MB")
    free = os.environ.get("DX_HOST_MEMORY_FREE_PERCENT", "")
    jobs = os.environ.get("DX_HOST_BUDGET_JOBS", "")
    if free:
        print(f"  Memory:     {free}% free (floor {os.environ.get('DEX_MIN_FREE_MEMORY_PERCENT', '10')}%)")
    if jobs:
        print(f"  Budget:     {jobs} test job(s) per session, "
              f"{os.environ.get('DEX_REVIEW_MAX_ACTIVE_WAVES', '3')} review wave(s) at once")
    return 0


if __name__ == "__main__":
    sys.exit(main())
