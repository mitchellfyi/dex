---
name: block-review-assessment-bash
enabled: true
event: bash
pattern: (?s).*
action: block
env_var: DEX_REVIEW_ASSESSMENT_ACTIVE
env_value: "1"
---

BLOCKED: This session is selecting a Dex review risk tier. The assessor must not run shell commands.

Use the prebuilt context supplied by the caller and return the requested structured decision.
