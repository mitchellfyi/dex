You are being evaluated on a polyglot schema change: update one shared contract and propagate it through both services.

The workspace is a small monorepo:

- `schemas/event.json` is the single shared event schema.
- `services/api/` is a Node API package that validates and emits events.
- `services/processor/` is a Python processor that reads the same schema and routes events.

Add a new `priority` field to the event schema:

- enum values: `low`, `normal`, `high`
- default: `normal`

Requirements:

- Update the Node API to accept, validate, and default `priority`.
- Update the Python processor to route events by priority.
- Add tests on both the Node side and the Python side.
- The schema definition must live in one place. Both services must read from `schemas/event.json`.
- Run both service test suites.
- Do not duplicate the priority enum as a second source of truth in service code.

Deliverable: the schema and service updates under `schemas/`, `services/api/`, and `services/processor/`.
