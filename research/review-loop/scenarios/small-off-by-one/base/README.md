# Retry policy

`canAttempt(attemptNumber, maxAttempts)` accepts one-based attempt numbers.
Attempts from `1` through `maxAttempts`, inclusive, are allowed. Later attempts
must be rejected.

Run the visible checks with:

```sh
node --test tests/visible.test.js
```
