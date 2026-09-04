# Verification and CI

Durable lessons about Dex's manifest-driven test suite and static checks.

## M-009: Test declarations and platform-sensitive assertions are executable contracts

Domain: verification-ci
Status: active
Scope: tests/check.sh, tests/run-all.sh, tests/manifest.tsv, tests/helpers.sh, tests/*-test.sh, .github/workflows/ci.yml
Applies to phases: implement, review, verify, maintenance
Applies to paths: tests/, .github/workflows/ci.yml
Last verified: 2026-09-03
Recheck when: the manifest schema, runner lanes, CI job matrix, assertion helper, or supported shell platforms change

Lesson:
Dex's test metadata and assertion form are part of the executable test
contract. Every `tests/*-test.sh` file must have one sorted manifest row with
its lane, platform, timeout, and isolation. `service` and `serial` tests run
exclusively; only genuine wall-clock assertions belong in `serial`. Test
assertions must use `[[ ... ]] || assert_at $LINENO` because a bare `[[ ... ]]`
does not reliably trigger `set -e` under macOS Bash 3.2. Static checks cover all
shipped shell, Python files and embedded Python, Node syntax, documentation
links, and GitHub workflows when `actionlint` is installed.

Evidence:
- Commit `a4ccca8 test(ci): make test execution manifest-driven` makes
  `tests/manifest.tsv` authoritative and rejects missing, extra, duplicate, or
  unsorted declarations.
- Commits `6f75b51 test: make 365 assertions that were inert on macOS actually
  assert` and `690c49a test: reject a [[ ... ]] assertion with no consequence`
  establish and enforce the portable assertion form.
- Commits `c984eb6 test: run the tests that measure time in a lane of their own`
  and `6d01ce8 test(ci): isolate localhost service fixtures` separate resource
  contention from ordinary slow tests.
- Commit `f5c1e5a test: close three static-coverage gaps` extends static checks
  to tests and research Python, workflow shell via optional `actionlint`, and
  documentation links.
- Current `tests/run-all.sh`, `tests/check.sh`, `tests/manifest.tsv`, and
  `.github/workflows/ci.yml` implement these constraints on Linux and macOS.

Future agent behavior:
- Add or rename a `tests/*-test.sh` file and its sorted manifest row in the same
  change. Choose `serial` only when the assertion measures elapsed time, and
  use `service` for exclusive external fixtures.
- Source `tests/helpers.sh` and write test assertions as
  `[[ ... ]] || assert_at $LINENO`; leave a bare `[[ ... ]]` only when its
  status is intentionally returned to a caller.
- Run `bash tests/check.sh` before PR handoff and the focused test while
  iterating. Use `bash tests/run-all.sh` for the full suite so its lane and
  isolation rules remain in force.
- When expanding a shipped language or generated surface, update the static
  checks and CI together so syntax errors fail at the narrowest useful gate.
