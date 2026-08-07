---
name: block-review-assessment-file-edits
enabled: true
event: file
pattern: (?s).+
action: block
env_var: DEX_REVIEW_ASSESSMENT_ACTIVE
env_value: "1"
---

BLOCKED: This session is selecting a Dex review risk tier. Risk assessment is read-only; do not edit files.

Use the prebuilt context supplied by the caller and return the requested structured decision. The review waves own any later fixes.
