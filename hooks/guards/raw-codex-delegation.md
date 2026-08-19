---
name: warn-raw-codex-delegation
enabled: true
event: bash
detector: raw-codex-delegation
action: warn
case_sensitive: false
env_var: DX_PROVIDER_ENGINE
env_value: codex-plugin
---

Raw Codex CLI delegation while Dex is using Claude as a Codex-provider proxy.

Use `bin/dxcodex.sh` so Dex can enforce subscription-safe Codex flags, sandbox settings, and provider environment cleanup. This guard flags raw Codex agent work such as `codex`, `codex exec`, `codex e`, `codex review`, direct `dx_provider_codex` helper delegation, literal variable-expanded and escape-decoded generated/heredoc/direct executable shell payloads, Python/Node/Ruby/Perl interpreter payloads that launch Codex, launch wrappers such as `nice`, `timeout`, `xargs`, and `find -exec`, package-runner forms such as `npx codex`, `npx -c "codex exec ..."`, and `npm exec --call "codex exec ..."`, and fail-closed shell execution from unresolved/unreadable script paths or unknown stdin/process-substitution producers.
