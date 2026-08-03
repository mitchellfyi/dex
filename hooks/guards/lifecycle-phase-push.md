---
name: block-pre-phase4-push
enabled: true
event: bash
pattern: \bgit\s+(?:-{1,2}[\w-]+(?:=\S*)?\s+|-C\s+\S+\s+|-c\s+\S+\s+)*push\b|\bgh\s+pr\s+(?:create|merge|ready|edit|close|reopen)\b
action: block
env_var: DX_LIFECYCLE_PUSH_FORBIDDEN
env_value: "1"
---

BLOCKED: This Dex lifecycle session is in a pre-push phase (Phase 1-3: Plan, Implement, or Review). Pushing and PR operations are owned by Phase 4 (Verify & Commit via dxcommit) and Phase 5 (PR via dxpr). Phase 0 setup (branch bootstrap push) is exempt.

Finish the current phase and let the Stop hook advance the lifecycle. This guard reads the session environment set at launch, so an inline `DX_LIFECYCLE_PUSH_FORBIDDEN=0` prefix on the command has no effect. If a genuinely stuck session needs this override, stop and report the blocker; the user can relaunch the session with DX_LIFECYCLE_PUSH_FORBIDDEN=0 exported.
