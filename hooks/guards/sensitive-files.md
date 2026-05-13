---
name: warn-sensitive-files
enabled: true
event: commit
pattern: (^|/)\.env($|[.-])|credentials\.(json|yml|yaml|xml)$|\.secret$|\.(key|pem|p12|pfx)$|(^|/)id_(rsa|dsa|ecdsa|ed25519)($|\s)
action: warn
---

WARNING: Potentially sensitive file detected in commit.

Ensure no credentials, API keys, or secrets are being committed.
Consider removing with: `git reset HEAD~1 --soft`
