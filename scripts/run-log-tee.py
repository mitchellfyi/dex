#!/usr/bin/env python3
"""Forward a stream to stdout while appending redacted lines to a run log.

Invoked by dx_run_log_tee. This must be a real script rather than a heredoc:
a heredoc occupies the interpreter's stdin, which is exactly where the stream
being teed arrives.

Environment:
    DX_RUN_LOG_FILE    destination log file (required)
    DX_RUN_LOG_SOURCE  source label for each line (default: harness)
"""

import os
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from dex_redact import log_line  # noqa: E402


def main():
    log_path = Path(os.environ["DX_RUN_LOG_FILE"])
    source = os.environ.get("DX_RUN_LOG_SOURCE", "harness")

    handle = None
    try:
        log_path.parent.mkdir(parents=True, exist_ok=True)
        handle = log_path.open("a", encoding="utf-8")
    except OSError:
        handle = None

    try:
        for raw in sys.stdin:
            line = raw.rstrip("\n")
            sys.stdout.write(line + "\n")
            sys.stdout.flush()
            if handle is None:
                continue
            try:
                handle.write(log_line("info", source, line))
                handle.flush()
            except OSError:
                # Logging is best-effort; never break the stream being teed.
                handle = None
    finally:
        if handle is not None:
            handle.close()


if __name__ == "__main__":
    main()
