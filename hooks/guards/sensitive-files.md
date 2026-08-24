---
name: warn-sensitive-files
enabled: true
event: commit
pattern: (^|/)\.env($|[._-])(?!example|sample|template|dist)|(^|[/._-])credentials(\.(json|yml|yaml|xml))?$|(^|/)secrets?\.(json|ya?ml)$|(^|/)service-account[^/]*\.json$|\.secret$|\.(key|pem|p12|pfx|jks|p8)$|(^|/)id_(rsa|dsa|ecdsa|ed25519)($|\s)|(^|/)\.(netrc|npmrc|pypirc|dockercfg|git-credentials)($|\s)|(^|/)\.?htpasswd$|(^|/)\.keystore$
action: warn
---

WARNING: Potentially sensitive file detected in commit.

Ensure no credentials, API keys, or secrets are being committed.
Consider removing with: `git reset HEAD~1 --soft`

Caught: `.env` and its variants, files whose whole purpose is holding
credentials (`.netrc`, `.npmrc`, `.pypirc`, `.dockercfg`, `.git-credentials`,
an AWS-style `credentials`), private keys and stores (`.key`, `.pem`, `.p12`,
`.pfx`, `.jks`, `.p8`, `.keystore`, `id_rsa` and friends), `secrets.json` /
`secrets.yml`, a GCP `service-account*.json`, and `htpasswd`.

Not caught, because they are meant to be committed: `.env.example`,
`.env.sample`, `.env.template`, `.env.dist`, and `id_rsa.pub`. A template is
the one .env file a project is supposed to check in, and warning on it is how a
guard stops being read.
