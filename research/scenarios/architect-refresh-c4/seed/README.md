# Orderly

Small ordering platform. Customers place orders via the API; the worker handles
fulfilment notifications and other async work via the shared queue.

## Layout

- `services/api/` — public HTTP API (Express)
- `services/worker/` — background job processor
- `packages/shared/` — shared types + queue client used by both services

## Run

```
docker compose up
```

## Infrastructure

- PostgreSQL — primary data store
- Redis — job queue backing store
