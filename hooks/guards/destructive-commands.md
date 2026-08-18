---
name: block-destructive-commands
enabled: true
event: bash
detector: destructive-commands
action: block
---

BLOCKED: Destructive system command detected.

This command could cause irreversible data loss. Please verify the exact path and use a safer approach.

Caught patterns: `rm -rf /`, `rm -rf /*`, `rm -rf ~`, `rm -rf ~/.`, `rm -rf ~/*`, `rm -rf ~/`, `rm -rf ~+`, `rm -rf ~+/*`, `rm -rf $HOME`, `rm -rf $HOME/.`, `rm -rf $HOME/*`, `rm -rf $PWD`, `rm -rf $PWD/.`, `rm -rf $PWD/*`, `rm -rf .`, `rm -rf ./`, `rm -rf ./.`, `rm -rf *`, `rm -rf ./*`, and variants with parameter expansion or reordered flags (`-fr`, etc.), including BusyBox, common wrappers, shell-nested `bash -c`/`eval` payloads, command substitutions whose output resolves to one of these commands, and literal process-launch calls from Python, Node.js, Ruby, or Perl. Paths with subdirectories (e.g., `rm -rf ./build`, `rm -rf /tmp`) are NOT blocked — only the root/home/cwd targets themselves. Dex also blocks raw-device `dd` writes, destructive `diskutil` operations, `mkfs`, and `format X:`.
