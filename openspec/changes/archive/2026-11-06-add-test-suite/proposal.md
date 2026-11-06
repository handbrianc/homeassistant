# Proposal: add-test-suite

## Why

All verification so far ran ad-hoc from `/tmp` (throwaway stubs, throwaway
assertion scripts) — nothing is committed, so regressions ship silently and
new contributors have no way to test. The suite must also be **safe by
construction**: the target cluster is a real home-assistant cluster, so tests
must never modify it — they verify behavior through the scripts' dry-run
modes and through hermetic mocks.

## What Changes

- Add a committed `tests/` tree with a single entry point:
  `tests/run-tests.sh [names...]`.
- **Dry-run tests** for `install.sh`/`update.sh`: exercise the real scripts'
  `--dry-run` mode — no cluster access, no toolchain required.
- **Mock-based end-to-end tests** for every script: committed stub
  `helm`/`kubectl`/`ssh`/`scp` binaries (logged, env-knobbed) are placed
  FIRST on `PATH` inside `env -i` environments, so real cluster tools can
  never be invoked. Stub logs double as proof that mocks — not real tools —
  ran.
- **Unit tests** for `scripts/lib/common.sh` (logging, validation, env
  loading, values rendering, secret apply, helm args, rollout wait).
- **Chart contract tests** (helm lint + template, edge renders) — skipped
  with a notice when helm is absent (use `HELM_BIN` to point at one).
- **Prerequisite installer tests**: offline fake-download path via a `curl`
  mock serving locally built tarballs with correct checksums (plus a
  checksum-mismatch abort case); real network install only behind
  `HC_TEST_NETWORK=1` (default off).
- **Hermeticity enforcement**: tests run against throwaway repo copies;
  `run-tests.sh` fails if any test leaks artifacts into the real repo tree.
- Root README gains a "Testing" pointer.

## Capabilities

### test-suite

New capability: the committed, cluster-safe test suite for all scripts and
the chart contract.

## Impact

- Affected specs: `test-suite` (new capability spec).
- Affected code: new `tests/` tree (runner, lib, stubs, fixtures, six test
  files); one README section. No changes to any production script — tests
  observe existing behavior only.
