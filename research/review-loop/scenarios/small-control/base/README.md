# Label normalization

`normalizeLabel(value)` prepares user-entered labels for stable comparisons.
It must trim surrounding whitespace, normalize canonically equivalent Unicode
text to NFC, and lowercase with locale-independent semantics.

Run the visible checks with:

```sh
node --test tests/visible.test.js
```
