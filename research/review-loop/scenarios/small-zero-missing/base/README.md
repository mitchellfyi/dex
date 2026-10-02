# Quota defaults

`effectiveLimit(config, defaultLimit)` returns an explicitly configured quota.
The value `0` disables access and must be preserved. The default applies only
when `config.limit` is missing.

Run the visible checks with:

```sh
node --test tests/visible.test.js
```
