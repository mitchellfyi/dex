---
name: warn-destructive-commands
enabled: true
event: bash
detector: destructive-commands
action: warn
allow_pattern: (?i)\beval\s+"?\$\((?:[a-z0-9_.-]*/)?(?:direnv|rbenv|pyenv|nodenv|jenv|goenv|tfenv|asdf|mise|rtx|nvm|fnm|volta|starship|zoxide|atuin|mcfly|thefuck|navi|brew|ssh-agent|gpg-agent|keychain|docker-machine|minikube|kubectl|helm|gh|hub|aws|gcloud|az|op|dotenv|terraform|tofu|vault|doppler|sops|aws-vault|chamber|infisical|teller|envchain|pipenv|poetry|conda|micromamba|rustup|cargo|deno|bun|pnpm|yarn|npm|node|python3?|ruby|perl|luarocks|opam|sdk|jabba|tmuxifier|fzf|dircolors|lesspipe|register-python-argcomplete|_[A-Z0-9_]+_COMPLETE)\b[^()]*\)"?
---

Destructive system command detected.

This looks like it could cause irreversible data loss: a delete, device write
or format aimed at a root, home or current-directory target, or a payload the
detector could not read (a script, heredoc or interpreter argument counts as
one it cannot vouch for). Check the exact path before running it, and prefer a
scoped target such as `./build` or a temp directory. This guard advises and
does not deny; the full list of caught shapes and the detector's reading rules
are in docs/guards.md under `warn-destructive-commands`.
