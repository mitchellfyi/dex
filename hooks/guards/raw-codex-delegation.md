---
name: block-raw-codex-delegation
enabled: true
event: bash
detector: raw-codex-delegation
action: block
case_sensitive: false
env_var: DK_PROVIDER_ENGINE
env_value: codex-plugin
---

BLOCKED: Raw Codex CLI delegation is disabled while Doyaken is using Claude as a Codex-provider proxy.

Use `bin/dkcodex.sh` so Doyaken can enforce subscription-safe Codex flags, sandbox settings, and provider environment cleanup. This guard blocks raw Codex agent work such as `codex`, `codex exec`, `codex e`, `codex review`, direct `dk_provider_codex` helper delegation, literal variable-expanded and escape-decoded generated/heredoc/direct executable shell payloads, Python/Node/Ruby/Perl interpreter payloads that launch Codex, launch wrappers such as `nice`, `timeout`, `xargs`, and `find -exec`, package-runner forms such as `npx codex`, `npx -c "codex exec ..."`, and `npm exec --call "codex exec ..."`, and fail-closed shell execution from unresolved/unreadable script paths or unknown stdin/process-substitution producers.
