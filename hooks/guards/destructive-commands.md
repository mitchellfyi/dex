---
name: warn-destructive-commands
enabled: true
event: bash
detector: destructive-commands
action: warn
allow_pattern: (?i)\beval\s+"?\$\((?:[a-z0-9_.-]*/)?(?:direnv|rbenv|pyenv|nodenv|jenv|goenv|tfenv|asdf|mise|rtx|nvm|fnm|volta|starship|zoxide|atuin|mcfly|thefuck|navi|brew|ssh-agent|gpg-agent|keychain|docker-machine|minikube|kubectl|helm|gh|hub|aws|gcloud|az|op|dotenv|terraform|tofu|vault|doppler|sops|aws-vault|chamber|infisical|teller|envchain|pipenv|poetry|conda|micromamba|rustup|cargo|deno|bun|pnpm|yarn|npm|node|python3?|ruby|perl|luarocks|opam|sdk|jabba|tmuxifier|fzf|dircolors|lesspipe|register-python-argcomplete|_[A-Z0-9_]+_COMPLETE)\b[^()]*\)"?
---

Destructive system command detected.

This looks like it could cause irreversible data loss. Check the exact path
before running it — and prefer a scoped target (`./build`, a temp directory)
over a root, home, or current-directory one.

Caught patterns: `rm -rf /`, `rm -rf /*`, `rm -rf ~`, `rm -rf ~/.`, `rm -rf ~/*`, `rm -rf ~/`, `rm -rf ~+`, `rm -rf ~+/*`, `rm -rf $HOME`, `rm -rf $HOME/.`, `rm -rf $HOME/*`, `rm -rf $PWD`, `rm -rf $PWD/.`, `rm -rf $PWD/*`, `rm -rf .`, `rm -rf ./`, `rm -rf ./.`, `rm -rf *`, `rm -rf ./*`, and variants with parameter expansion or reordered flags (`-fr`, etc.), including BusyBox, common wrappers, shell-nested `bash -c`/`eval` payloads, command substitutions whose output resolves to one of these commands, and literal process-launch calls from Python, Node.js, Ruby, or Perl. Paths with subdirectories (e.g., `rm -rf ./build`, `rm -rf /tmp`) are NOT flagged — only the root/home/cwd targets themselves, which includes the ones spelled with `..`: `/etc/..` is `/`, and `$HOME/..` contains home. Climbing and then naming a child (`../sibling`, `/etc/../var/cache`) is a specific directory and is left alone. `find <root> -delete` and `find <root> -exec rm -rf {} +` are flagged for the same roots. Dex also flags raw-device `dd` writes, destructive `diskutil` operations, `mkfs`, and `format X:`.

The command word is resolved before it is judged, so a variable or a default
expansion holding the command reads the same as writing it out: `R=rm;
$R -rf /` and `${RM:-rm} -rf /` are both caught. A word that cannot be resolved
is left alone rather than warned about.

The detector is deliberately coarse where it cannot resolve a *payload* — a
script, a heredoc, an interpreter argument it cannot read counts as one it
cannot vouch for. That is a reason to look, not a reason to stop: this guard
advises and does not deny. Arithmetic is not a payload, so `$(( … ))` is read
as arithmetic and only the substitutions it really runs are judged.
