# Order receipt contract

`summarizeOrder(items)` now exposes its final amount as `grandTotal`.
`formatReceipt(summary, currency)` must consume that summary directly while
continuing to accept legacy summaries that use `total`.

Run the visible checks with:

```sh
node --test tests/visible.test.js
```
