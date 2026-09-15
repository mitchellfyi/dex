#!/usr/bin/env python3
"""Install and restore the settings owned by native subscription routing."""

import json
import os
from pathlib import Path
import re
import sys
import tempfile

try:
    import tomllib
except ImportError:
    sys.exit("Native routing setup requires Python 3.11 or newer.")


def read(file):
    return file.read_text() if file.exists() else ""


def atomic_write(file, content):
    file.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{file.name}.", dir=file.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, file)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def set_root(source, key, value):
    """Change one root TOML value while retaining unrelated text and tables."""
    tomllib.loads(source)
    lines = source.splitlines(keepends=True)
    pieces, pending = [], ""
    for index, line in enumerate(lines):
        if not pending and re.match(r"\s*\[", line):
            pieces.append("".join(lines[index:]))
            break
        pending += line
        try:
            statement = tomllib.loads(pending)
        except tomllib.TOMLDecodeError:
            continue
        if key not in statement:
            pieces.append(pending)
        pending = ""
    else:
        if pending:
            raise ValueError("Could not safely edit the Codex root settings.")
    result = "".join(pieces)
    if value is not None:
        result = f"{key} = {json.dumps(value)}\n" + result
    tomllib.loads(result)
    return result


def get_field(document, field):
    current = document
    for name in field:
        if not isinstance(current, dict) or name not in current:
            return {"present": False}
        current = current[name]
    return {"present": True, "value": current}


def put_field(document, field, saved):
    current = document
    for name in field[:-1]:
        current = current.setdefault(name, {})
    if saved["present"]:
        current[field[-1]] = saved["value"]
    else:
        current.pop(field[-1], None)


def sync_context_field(document, entries, field, value, label):
    entry = next(item for item in entries if item["field"] == field)
    names = field if isinstance(field, list) else [field]
    current = get_field(document, names)
    if current != {"present": True, "value": entry["installed"]}:
        raw = current.get("value")
        if (isinstance(raw, (int, str)) and not isinstance(raw, bool)
                and re.fullmatch(r"[1-9][0-9]*", str(raw)) and int(raw) <= int(value)):
            return False
        raise ValueError(f"{label} was edited and exceeds the route budget. Set it to a positive value at most {value} before changing routes.")
    put_field(document, names, {"present": True, "value": value})
    entry["installed"] = value
    return current.get("value") != value


def apply(request):
    action = request["action"]
    backup_file = Path(request["backup"])
    saved = json.loads(read(backup_file) or "null")
    if action == "disable" and saved is None:
        return {"changed": False, "preserved": []}
    if action == "sync-context" and saved is None:
        raise ValueError("Native routing ownership is missing. Enable native routing before syncing context settings.")
    claude_file = Path(request["claude_file"]).resolve()
    codex_file = Path(request["codex_file"]).resolve()
    sources = {file: read(file) for file in [claude_file, codex_file]}
    claude = json.loads(sources[claude_file] or "{}")
    codex = tomllib.loads(sources[codex_file])
    fields = request.get("claude_fields", [])
    codex_fields = request.get("codex_fields", [])
    if saved is None:
        if "dex-ccr" in codex.get("model_providers", {}):
            raise ValueError("The dex-ccr Codex provider already exists and is not owned by Dex.")
        saved = {
            "claude_file": str(claude_file), "codex_file": str(codex_file),
            "claude": [{"field": entry["field"], "original": get_field(claude, entry["field"]), "installed": entry["value"]} for entry in fields],
            "codex": [{"field": entry["field"], "original": get_field(codex, [entry["field"]]), "installed": entry["value"]} for entry in codex_fields],
            "provider_content": "", "had_env": "env" in claude,
        }
    if saved["claude_file"] != str(claude_file) or saved["codex_file"] != str(codex_file):
        raise ValueError("Disable native routing before changing the client configuration paths.")
    preserved = []
    claude_source = None
    if action == "sync-context":
        codex_source = sources[codex_file]
        claude_source = sources[claude_file]
        if codex.get("model_provider") == "dex-ccr":
            if not saved["provider_content"] or saved["provider_content"] not in codex_source:
                raise ValueError("Native Codex provider settings were edited; context settings were not changed.")
            for field, value in [("model_context_window", request["codex_context"]),
                                 ("model_auto_compact_token_limit", request["codex_context"] * 8 // 10)]:
                if sync_context_field(codex, saved["codex"], field, value, f"codex.{field}"):
                    codex_source = set_root(codex_source, field, value)
        base = next(item for item in saved["claude"] if item["field"] == ["env", "ANTHROPIC_BASE_URL"])
        if get_field(claude, base["field"]) == {"present": True, "value": base["installed"]}:
            if sync_context_field(claude, saved["claude"], ["env", "CLAUDE_CODE_MAX_CONTEXT_TOKENS"],
                                  str(request["claude_context"]), "claude.CLAUDE_CODE_MAX_CONTEXT_TOKENS"):
                claude_source = json.dumps(claude, indent=2) + "\n"
    elif action == "disable":
        for entry in saved["claude"]:
            if get_field(claude, entry["field"]) == {"present": True, "value": entry["installed"]}:
                put_field(claude, entry["field"], entry["original"])
            else:
                preserved.append("claude." + ".".join(entry["field"]))
        if not saved["had_env"] and claude.get("env") == {}:
            del claude["env"]
        codex_source = sources[codex_file]
        for entry in saved["codex"]:
            if get_field(codex, [entry["field"]]) == {"present": True, "value": entry["installed"]}:
                codex_source = set_root(codex_source, entry["field"], entry["original"].get("value"))
            else:
                preserved.append("codex." + entry["field"])
        if saved["provider_content"] in codex_source:
            codex_source = codex_source.replace(saved["provider_content"], "", 1)
        else:
            preserved.append("codex.model_providers.dex-ccr")
    else:
        if saved["provider_content"]:
            if saved["provider_content"] not in sources[codex_file]:
                raise ValueError("Native Codex settings were edited. Disable native routing before enabling it again.")
            for entry in saved["codex"]:
                if get_field(codex, [entry["field"]]) != {"present": True, "value": entry["installed"]}:
                    raise ValueError("Native Codex settings were edited. Disable native routing before enabling it again.")
            for entry in saved["claude"]:
                if get_field(claude, entry["field"]) != {"present": True, "value": entry["installed"]}:
                    raise ValueError("Native Claude settings were edited. Disable native routing before enabling it again.")
        for entry in fields:
            put_field(claude, entry["field"], {"present": True, "value": entry["value"]})
            next(item for item in saved["claude"] if item["field"] == entry["field"])["installed"] = entry["value"]
        codex_source = sources[codex_file]
        if saved["provider_content"]:
            codex_source = codex_source.replace(saved["provider_content"], "", 1)
        for entry in codex_fields:
            codex_source = set_root(codex_source, entry["field"], entry["value"])
            next(item for item in saved["codex"] if item["field"] == entry["field"])["installed"] = entry["value"]
        saved["provider_content"] = request["provider_content"]
        codex_source = codex_source.rstrip() + "\n\n" + saved["provider_content"]
    tomllib.loads(codex_source)
    updates = {claude_file: claude_source if claude_source is not None else json.dumps(claude, indent=2) + "\n", codex_file: codex_source}
    for file, source in sources.items():
        if read(file) != source:
            raise ValueError("Client settings changed during setup. Retry the command.")
    original_backup = read(backup_file)
    existed = {file: file.exists() for file in updates}
    try:
        if action != "disable":
            atomic_write(backup_file, json.dumps(saved, indent=2) + "\n")
        for file, content in updates.items():
            if content == sources[file]:
                continue
            if content is None:
                file.unlink(missing_ok=True)
            else:
                atomic_write(file, content)
        if action == "disable":
            backup_file.unlink(missing_ok=True)
    except Exception:
        for file in updates:
            if existed[file]:
                atomic_write(file, sources[file])
            else:
                file.unlink(missing_ok=True)
        if original_backup:
            atomic_write(backup_file, original_backup)
        else:
            backup_file.unlink(missing_ok=True)
        raise
    return {"changed": any(sources[file] != content for file, content in updates.items()), "preserved": preserved}


if __name__ == "__main__":
    try:
        print(json.dumps(apply(json.load(sys.stdin))))
    except (OSError, ValueError, KeyError, StopIteration) as error:
        sys.exit(f"Native client setup failed: {error}")
