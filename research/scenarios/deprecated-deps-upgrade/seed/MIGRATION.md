# local-client v3 to v5 migration guide

The v3 API is deprecated. Upgrade all application code to `lib/v5`.

## Required changes

1. Replace `require('../lib/v3')` with `require('../lib/v5')`.
2. Replace `createClient({ endpoint, token })` with `connect({ baseUrl, apiToken })`.
3. Replace callback client methods with async methods:
   - `client.fetchUser(id, callback)` -> `await client.getUser({ id })`
   - `client.listOrders(userId, callback)` -> `await client.getOrders({ userId })`
   - `client.chargeCard(cardToken, amountCents, callback)` -> `await client.createCharge({ paymentMethod, amountCents })`
4. Replace `formatMoney(cents, currency)` with `money.format({ amountCents: cents, currencyCode: currency })`.
5. Replace `parseDate(value)` with `dates.parseIso(value)`. v5 accepts ISO strings only.
6. Replace `new Validator().checkEmail(value)` and `requireFields(record, fields)` with `validators.email(value)` and `validators.required(record, fields)`.
7. Replace `logger.warn(message, meta)` with `createLogger({ scope }).warn({ message, context })`.

Do not add a compatibility wrapper that recreates the v3 API. Migrate the call sites.
