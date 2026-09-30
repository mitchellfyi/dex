Add an optional `queryOrder` option to `buildUrl` in `src/url-builder.js`. `buildSignedUrl` passes its options through to `buildUrl`, so it gets the option too.

- `'sorted'` is the default and keeps today's behaviour: query keys in sorted order.
- `'insertion'` keeps query keys in the order they appear in the `query` object.
- Any other value throws a `TypeError`.
- Arrays still produce one `key=value` pair per item, in array order, whichever ordering is used.
- A `URLSearchParams` query is passed through unchanged, as it is today.

Keep the existing behaviour and tests working, and add tests for the new option.
