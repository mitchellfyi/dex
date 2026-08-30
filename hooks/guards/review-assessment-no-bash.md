---
name: warn-review-assessment-bash
enabled: true
event: bash
pattern: (?s).+
action: warn
env_var: DEX_REVIEW_ASSESSMENT_ACTIVE
env_value: "1"
---

This session is selecting a Dex review risk tier, and the assessor is meant to be read-only: it should not run shell commands.

Use the prebuilt context supplied by the caller and return the requested structured decision.
