# INC-5521: Oversold stock and stuck holds during the September flash sale

Reported by the checkout team after the 2026-09-12 flash sale.

## What we saw

- The `sneaker-limited` drop had 250 units. We confirmed 263 orders, and 13
  customers had to be refunded.
- The stock dashboard showed `reserved` going negative for two SKUs after the
  sale, and it has not recovered.
- Some customers who retried checkout after a timeout had units held twice for
  one order; the second hold only disappeared when the reservation expired.
- One order was rejected because a bundle item was out of stock, but the other
  item in the bundle stayed held until we restarted the worker pool.
- Finance reports `sold` counts that are higher than the number of orders we
  shipped for a few SKUs.

## Context

Every checkout worker calls `InventoryService` concurrently. During the sale
we ran 40 workers. The nightly `expire()` job ran once during the sale.

The unit tests all pass, and none of this reproduces when we click through
checkout by hand.

A service-wide lock (INC-5490) stopped the overselling in staging but cut
checkout throughput by 90% and was rolled back the same day.
