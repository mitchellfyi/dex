---
name: "dxqa"
description: "Exercise the running change against the approved acceptance criteria by hand, record a QA report, and route findings."
---

# Skill: dxqa

Read and follow `prompts/workflows/dxqa.md` from the Dex prompts directory
(`${DEX_DIR:-$HOME/work/dex}/prompts/workflows/dxqa.md`). It owns the manual
QA pass: start the change the way the project documents, drive every approved
acceptance criterion and verification requirement by hand, write the report
with `dx qa report`, fix what is `NOT_MET`, and route the rest.

Phase 2 of the Dex lifecycle runs it before the ready marker. It also works on
request to re-check a running change against its criteria.
