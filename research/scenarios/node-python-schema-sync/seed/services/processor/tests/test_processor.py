import sys
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from processor import process_event
from schema_loader import load_event_schema
from jsonschema import ValidationError


def event(**overrides):
    base = {
        "event_id": "evt_1",
        "user_id": "user_1",
        "type": "user.created",
        "payload": {"plan": "pro"},
        "occurred_at": "2026-01-01T00:00:00.000Z",
    }
    base.update(overrides)
    return base


class ProcessorTests(unittest.TestCase):
    def test_loads_shared_schema(self):
        schema = load_event_schema()

        self.assertEqual(schema["title"], "Event")
        self.assertEqual(schema["properties"]["event_id"]["type"], "string")

    def test_routes_user_events(self):
        result = process_event(event())

        self.assertEqual(result["event_id"], "evt_1")
        self.assertEqual(result["route"], "users")

    def test_rejects_unknown_fields(self):
        with self.assertRaisesRegex(ValidationError, "unexpected is not allowed"):
            process_event(event(unexpected=True))


if __name__ == "__main__":
    unittest.main()
