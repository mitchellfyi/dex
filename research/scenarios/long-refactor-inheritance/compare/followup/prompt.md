Add a fifth notification channel, `webhook`, to the library in `src/notifications/`.

- `createNotifier('webhook', options)` creates it, and `createAllNotifiers()` includes it.
- A webhook user needs a `webhookUrl` that starts with `https://`. Otherwise `send` rejects with a `TypeError` whose message mentions `webhookUrl`.
- The default hourly limit is 10, and `options.maxPerHour` overrides it. Validation, templating, throttling and the send result work exactly as they do for the other channels.
- The payload passed to `transport.webhook(payload)` holds everything the shared formatting produces (`id`, `channel`, `locale`, `title`, `body`, `preview`, `metadata`), plus:
  - `url`: the user's `webhookUrl`
  - `method`: `'POST'`
  - `headers`: `{ 'content-type': 'application/json' }`
  - `json`: `JSON.stringify({ title, body, category, userId })`, using the templated title and body, the message category (default `'general'`) and the user's id
- When `transport.webhook` is not a function, `send` rejects with an `Error` whose message is `webhook transport is not configured`.

Keep every existing channel's behaviour unchanged. Update the tests to cover the new channel.
