# Catalog dependency errors

`listCatalog(transport)` returns catalog items from the transport response.
Transport and validation failures must reject the operation so callers can
distinguish an unavailable catalog from an empty catalog.

Run the visible checks with:

```sh
node --test tests/visible.test.js
```
