# Account-card refactor

The account source and card renderer are being updated together so their
internal profile field is named `displayName`. The public card output must stay
the same, including missing-account behavior and Unicode names.

Run the visible checks with:

```sh
node --test tests/visible.test.js
```
