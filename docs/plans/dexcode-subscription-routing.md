# DexCode subscription-routing handoff

Status: future web implementation. The Dex CLI integration is optional and must
remain usable without a DexCode account or connection.

The CLI owns provider authentication, credentials, account selection, and local
session control. DexCode must never receive provider credentials, refresh
tokens, local management tokens, or authentication links/device codes.

Version the account, quota, route, and event contracts alongside the CLI.
Account data belongs to the local machine's owner. Existing organisation worker
registration does not grant organisation-wide visibility into personal account
usage. Sharing requires an explicit owner choice and server-side access checks.

The future dashboard should show redacted account labels, quota windows and
freshness, effective routes, and routing events. Preserve unknown and stale
quota states. Remote controls require an authenticated, expiring, run-scoped
capability and an acknowledgement from the local owner process.
