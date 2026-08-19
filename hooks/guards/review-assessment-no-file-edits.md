---
name: warn-review-assessment-file-edits
enabled: true
event: file
pattern: (?s).+
action: warn
env_var: DEX_REVIEW_ASSESSMENT_ACTIVE
env_value: "1"
---

This session is selecting a Dex review risk tier. Risk assessment is read-only, so editing files here makes the assessment unverifiable.

Use the prebuilt context supplied by the caller and return the requested structured decision. The review waves own any later fixes.
