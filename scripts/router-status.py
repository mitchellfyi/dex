#!/usr/bin/env python3
"""Read the optional route cache for the status line without starting Node."""
import json
import os
from pathlib import Path
import re
import stat
import time


def read_private(file):
    descriptor = os.open(file, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor) as handle:
        info = os.fstat(handle.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_size > 8 * 1024 * 1024:
            raise ValueError("Unsafe route cache")
        return json.load(handle)


def main():
    session_id = os.environ.get("DX_ROUTER_SESSION_ID", "")
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_.-]{0,179}", session_id):
        return
    root = Path(os.environ.get("DEX_ROUTER_HOME", str(Path.home() / ".dex/router")))
    session = read_private(root / "sessions" / f"{session_id}.json")
    accounts = read_private(root / "accounts.json")["accounts"]
    account = next((item for item in accounts if item["id"] == session.get("current_account")), {})
    if session.get("paused_reason"):
        result = "routing paused; dx accounts"
    else:
        result = session.get("current_model", "route pending")
        if account:
            result += f" / {account['name']}"
            usage = account.get("usage", {})
            windows = [item for item in usage.get("windows", []) if not item.get("model_pool")]
            if windows and time.time() * 1000 - usage.get("observed_at", 0) < 120000 and not account.get("usage_error"):
                result += " / " + ", ".join(f"{item['name']} {round(item['remaining_ratio'] * 100)}%" for item in windows)
            else:
                result += " / quota unknown" if not windows else " / quota stale"
    print(re.sub(r"[\x00-\x1f\x7f-\x9f]", " ", result)[:160])


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError):
        pass
