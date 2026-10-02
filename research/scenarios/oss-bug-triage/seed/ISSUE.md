# ISSUE-214: `buildUrl` drops retry=0 when building webhook replay URLs

## Expected behavior

When I pass query parameters with numeric zero or boolean false, the URL should include those values exactly:

```js
buildUrl({
  baseUrl: 'https://api.example.test',
  path: ['webhooks', 'deliveries'],
  query: { retry: 0, include_archived: false }
})
```

Expected URL fragment:

```text
retry=0&include_archived=false
```

## Actual behavior

The generated URL omits both keys:

```text
https://api.example.test/webhooks/deliveries
```

Downstream, our replay worker treats the missing `retry` parameter as "use provider default", which retries the newest delivery instead of the first attempt.

## Repro steps

1. Install the package from this workspace.
2. Run `node` from the project root.
3. Import `buildUrl` from `./src/url-builder`.
4. Build a URL with `query: { retry: 0, include_archived: false, dry_run: true }`.
5. Observe that only `dry_run=true` is present.

## Stack trace from our failing integration assertion

```text
AssertionError [ERR_ASSERTION]: expected URL to contain retry=0
    at Object.<anonymous> (/app/integration/webhook-replay.test.js:42:10)
    at Module._compile (node:internal/modules/cjs/loader:1369:14)
    at Module._extensions..js (node:internal/modules/cjs/loader:1427:10)
    at Module.load (node:internal/modules/cjs/loader:1206:32)
```

## What I tried

- Passing the values as strings works, but then the call site has to special-case every numeric and boolean query parameter.
- Reordering the query object did not change the behavior.
- Encoding the path manually did not change the behavior.

## Environment

- package version: 1.7.3
- node: 20.12.2
- os: macOS 14.5 and Ubuntu 22.04

I'd be happy to send a PR if someone can point me at the right serializer.
