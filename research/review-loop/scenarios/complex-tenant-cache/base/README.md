# Tenant-scoped authorization cache

`canRead(request, loadMembership)` may cache authorization decisions, but a
decision belongs to one tenant, user, and resource. A cached allow decision
must never authorize another principal, even when resource identifiers match.

Run the visible checks with:

```sh
node --test tests/visible.test.js
```
