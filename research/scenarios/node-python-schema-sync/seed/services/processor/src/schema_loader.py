from __future__ import annotations

import json
from pathlib import Path


SCHEMA_PATH = Path(__file__).resolve().parents[3] / "schemas" / "event.json"


def load_event_schema() -> dict:
    with SCHEMA_PATH.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def apply_defaults(event: dict, schema: dict | None = None) -> dict:
    schema = schema or load_event_schema()
    copy = dict(event)
    for key, definition in schema.get("properties", {}).items():
        if key not in copy and "default" in definition:
            copy[key] = definition["default"]
    return copy
