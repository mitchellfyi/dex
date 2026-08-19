---
name: warn-hardcoded-secrets
enabled: true
event: file
pattern: (?<![A-Z0-9_])['"]?(?:[A-Z0-9]+_)*(API_KEY|SECRET_KEY|PRIVATE_KEY|ACCESS_KEY|ENCRYPTION_KEY|AUTH_TOKEN|JWT_SECRET|PASSWORD|TOKEN)(?:_[A-Z0-9]+)*['"]?\s*[=:]\s*(?:['"][^'"]{8,}['"]?|[^\s#;,'"}]{8,})
allow_pattern: [=:]\s*['"]?(?:os\.(?:environ|getenv)|process\.env|Deno\.env|Bun\.env|ENV\[|getenv\s*\(|\$\{?[A-Z_][A-Z0-9_]*\}?|\$\(|[A-Za-z_][A-Za-z0-9_]*(?:[.:]{1,2}[A-Za-z_][A-Za-z0-9_]*)*\s*[(\[])
action: warn
---

WARNING: Possible hardcoded credential detected.

Use environment variables instead of hardcoded secrets.
Store sensitive values in `.env` files (which should be in `.gitignore`).

Caught patterns: `API_KEY`, `SECRET_KEY`, `PRIVATE_KEY`, `ACCESS_KEY` (AWS), `ENCRYPTION_KEY`, `AUTH_TOKEN`, `JWT_SECRET`, `PASSWORD`, `TOKEN` — optionally quoted and with underscore-delimited prefixes/suffixes, followed by `=` or `:` and a quoted or unquoted value of 8+ characters.

Not caught, because a hardcoded secret is a literal: a value read from the
environment, produced by a command substitution, or returned by a call or a
subscript. `token = build_token(seed)` and `password: hash(raw)` are ordinary
code, and warning on them is how a guard stops being read.
