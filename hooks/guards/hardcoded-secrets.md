---
name: warn-hardcoded-secrets
enabled: true
event: file
pattern: (?<![A-Z0-9_])['"]?(?:[A-Z0-9]+_)*[A-Z0-9]*(API_?KEY|SECRET_?KEY|PRIVATE_?KEY|ACCESS_?KEY|ENCRYPTION_?KEY|AUTH_?TOKEN|JWT_?SECRET|CLIENT_?SECRET|PASSWORD|TOKEN)(?:_[A-Z0-9]+)*['"]?\s*[=:]\s*(?:['"][^'"]{8,}['"]?|[^\s#;,'"}]{8,})
allow_pattern: [=:]\s*['"]?(?:os\.(?:environ|getenv)|process\.env|Deno\.env|Bun\.env|ENV\[|getenv\s*\(|\$\{?[A-Z_][A-Z0-9_]*\}?|\$\(|[A-Za-z_][A-Za-z0-9_]*(?:[.:]{1,2}[A-Za-z_][A-Za-z0-9_]*)*\s*[(\[])
action: warn
---

WARNING: Possible hardcoded credential detected.

Use environment variables instead of hardcoded secrets.
Store sensitive values in `.env` files (which should be in `.gitignore`).

Caught patterns: `API_KEY`, `SECRET_KEY`, `PRIVATE_KEY`, `ACCESS_KEY` (AWS), `ENCRYPTION_KEY`, `AUTH_TOKEN`, `JWT_SECRET`, `CLIENT_SECRET`, `PASSWORD`, `TOKEN` — optionally quoted, with underscore-delimited or camelCase prefixes/suffixes, followed by `=` or `:` and a quoted or unquoted value of 8+ characters. Matching ignores case and the internal underscore is optional, so `apiKey`, `api_key` and `stripeApiKey` all read the same as `API_KEY` — camelCase is how most JavaScript and TypeScript spells these, and requiring the underscore missed all of it.

Not caught, because a hardcoded secret is a literal: a value read from the
environment, produced by a command substitution, or returned by a call or a
subscript. `token = build_token(seed)` and `password: hash(raw)` are ordinary
code, and warning on them is how a guard stops being read.
