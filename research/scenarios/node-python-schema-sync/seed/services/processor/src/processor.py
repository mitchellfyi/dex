from __future__ import annotations

from jsonschema import validate

from schema_loader import apply_defaults, load_event_schema


def process_event(event: dict) -> dict:
    schema = load_event_schema()
    normalized = apply_defaults(event, schema)
    validate(instance=normalized, schema=schema)

    route = route_for(normalized)
    return {
        "event_id": normalized["event_id"],
        "route": route,
        "user_id": normalized["user_id"],
    }


def route_for(event: dict) -> str:
    event_type = event["type"]
    if event_type.startswith("billing."):
        return "billing"
    if event_type.startswith("user."):
        return "users"
    return "general"
