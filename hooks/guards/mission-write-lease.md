---
name: mission-write-lease
enabled: true
event: file
detector: mission-write-lease
action: warn
match: path
env_var: DX_MISSION_ACTIVE
env_value: "1"
---

Inside a mission one holder at a time changes source, and this edit is not
from the holder. The lease and who has it are in the mission ledger
(`bin/mission.sh <session-id> lease show`).

If you are a helper: do not edit while someone else holds the lease. Finish
your investigation, run read-only checks, and return your proposed change in
your `dx-result` block for the lead to apply.

If you are the lead: an implementer is working in this tree right now. Wait
for its result, or stop it, before editing. Two writers in one tree is how a
helper's change gets lost or half-applied.

This guard advises and records the attempt; it does not stop the edit.
