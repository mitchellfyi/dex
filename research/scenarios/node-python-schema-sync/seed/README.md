# Event pipeline

This workspace has two services that share one event contract.

- `schemas/event.json` is the only schema definition.
- `services/api` validates incoming events and appends them to an event log.
- `services/processor` reads events and chooses a processing route.

Run all checks with:

```sh
npm test
```
