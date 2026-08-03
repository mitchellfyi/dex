---
name: block-review-pass-push
enabled: true
event: bash
pattern: \bgit\s+(?:-{1,2}[\w-]+(?:=\S*)?\s+|-C\s+\S+\s+|-c\s+\S+\s+)*push\b|\bgh\s+pr\s+(?:create|merge|ready|edit|close|reopen)\b
action: block
env_var: DEX_REVIEW_PASS_ACTIVE
env_value: "1"
---

BLOCKED: This session is a Dex review-wave pass. Review waves review and fix only — they never commit, push, or create/modify PRs.

Write your review result signal (`CLEAN`, `FINDINGS_FIXED:N`, `FINDINGS:N`, `BLOCKED:reason`, or `ESCALATE_THOROUGH:reason`) and stop. Pushing and PR operations belong to Phase 4+ of the lifecycle that launched this wave.
