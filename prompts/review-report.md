# Publish one review report

After reviewing and verifying the full supplied scope, write this version-1
JSON report outside the checkout. Replace the example text with your actual
observations. Do not claim passing checks or satisfied requirements without
evidence.

```json
{
  "version": 1,
  "result": "CLEAN",
  "context": {
    "scope": "The current files and direct consumers inspected, with their risks.",
    "checks": "Commands run or reused through the runner, their results, and relevant output.",
    "coverage": "Each required domain, the code inspected, and any justified N/A surfaces.",
    "verification": "Candidates investigated, repro results or exact static traces, and conclusions."
  },
  "criteria": {
    "objectives": [],
    "acceptance_criteria": [],
    "verification_requirements": []
  },
  "deterministic_checks": "pass",
  "coverage": ["correctness", "security", "contracts", "tests", "architecture"],
  "verifier": "pass",
  "findings": [],
  "fixes_applied": 0
}
```

For standalone review, leave the three criteria arrays empty. Otherwise each
array must contain one entry per supplied criterion in its original order:

```json
{
  "outcome": "met",
  "evidence": [
    {"kind": "test", "detail": "tests/example-test.sh passed the empty-input regression case."}
  ]
}
```

Outcomes: `met`, `not_met`, `blocked`, `not_applicable`. Each item needs one to
eight evidence entries. Kinds: `analysis`, `command`, `file`, `test`. Details
are concrete observations of 12–500 characters on one line, without `|`.
Do not insert your own `Evidence-Ref:` markers; the publisher generates them.

`findings` contains one stable, concrete description per verified root cause,
including findings fixed during this wave. Each is a single line of 12–4000
characters. The publisher derives the verified count and churn fingerprint.
Rejected candidates belong in the verification notes, not this array.

Check states: `pass`, `partial`, `fail`, `unavailable`. Verifier states: `pass`,
`fail`, `not-run`. Thorough clean/fixed waves include all nine coverage values:
the five core domains above plus `frontend`, `devops`, `performance`, and
`observability`. Standard/light waves include core and any targeted domains
actually reviewed. Record justified N/A surfaces in the coverage notes.

Allowed results remain those in `prompts/review-wave.md`. Counts must agree.
`CLEAN` and `FINDINGS_FIXED:N` require passing checks and verifier, full required
coverage, and every supplied criterion `met`. Lifecycle `FINDINGS:N` needs at
least one `not_met` or `blocked` item; lifecycle `BLOCKED:reason` needs a
`blocked` item. Never report `CLEAN` after a fix.

Publish with the exact generation supplied in this wave's prompt:

```bash
bash "$DEX_DIR/bin/review-result.sh" /absolute/path/report.json <authorized-generation>
```

The helper derives the version-3 evidence, context, result, and findings file
and validates them through the existing gates. Only then does it write the
completion receipt. Do not look up a newer generation to satisfy a stale
command. A rejected report publishes no completion receipt. A generation with
an existing receipt cannot be republished; the caller owns any new generation.

This helper replaces manual artifact assembly and the separate receipt command.
The older artifact interface remains accepted for compatibility. If the caller
did not supply review bindings and an authorized generation, report the result
to that caller without manufacturing completion state.
