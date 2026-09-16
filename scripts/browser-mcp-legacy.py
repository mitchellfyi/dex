#!/usr/bin/env python3
"""Recognize only the bare browser defaults installed by older Dex versions."""
import json
import os
from pathlib import Path
import sys


def legacy(client, name, package):
    if client == "claude":
        directory = Path(os.environ.get("CLAUDE_CONFIG_DIR", Path.home() / ".claude"))
        file = directory / ".claude.json" if "CLAUDE_CONFIG_DIR" in os.environ else Path.home() / ".claude.json"
        entry = json.loads(file.read_text()).get("mcpServers", {}).get(name, {})
    else:
        import tomllib
        file = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex")) / "config.toml"
        entry = tomllib.loads(file.read_text()).get("mcp_servers", {}).get(name, {})
    return (entry.get("command") == "npx" and entry.get("args") == ["-y", package]
            and not entry.get("env") and entry.get("type", "stdio") == "stdio"
            and not set(entry) - {"command", "args", "env", "type"})


if __name__ == "__main__":
    try:
        sys.exit(0 if legacy(*sys.argv[1:]) else 1)
    except (OSError, ValueError, ImportError):
        sys.exit(1)
