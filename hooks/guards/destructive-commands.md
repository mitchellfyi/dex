---
name: block-destructive-commands
enabled: true
event: bash
detector: destructive-commands
action: block
---

BLOCKED: Destructive system command detected.

This command could cause irreversible data loss. Please verify the exact path and use a safer approach.

Caught patterns: `rm -rf /`, `rm -rf /*`, `rm -rf ~`, `rm -rf ~/.`, `rm -rf ~/*`, `rm -rf ~/`, `rm -rf ~+`, `rm -rf ~+/*`, `rm -rf $HOME`, `rm -rf $HOME/.`, `rm -rf $HOME/*`, `rm -rf $PWD`, `rm -rf $PWD/.`, `rm -rf $PWD/*`, `rm -rf .`, `rm -rf ./`, `rm -rf ./.`, `rm -rf *`, `rm -rf ./*`, and variants with parameter expansion or reordered flags (`-fr`, etc.), including common wrappers and shell-nested `bash -c`/`eval` payloads. Paths with subdirectories (e.g., `rm -rf ./build`, `rm -rf /tmp`) are NOT blocked — only the root/home/cwd targets themselves. Also blocks `dd if=`, `mkfs`, and `format X:`.
