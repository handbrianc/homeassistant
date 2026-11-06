# Design: add-test-suite

## Layout

```
tests/
  run-tests.sh              runner: static gate + test files + summary + leak check
  lib.sh                    shared helpers (counters, chk/expect_fail, repo copies)
  stubs/{helm,kubectl,ssh,scp}   logged, env-knobbed mock binaries
  fixtures/k3s.yaml         canned k3s kubeconfig with 127.0.0.1 server URL
  test-common.sh            unit tests for scripts/lib/common.sh
  test-install.sh           install.sh: dry-run + mock e2e
  test-update.sh            update.sh: dry-run + mock e2e (rollback hints)
  test-bootstrap.sh         bootstrap-cluster.sh end-to-end (ported 69-check suite)
  test-install-prereqs.sh   prereqs: flags/--check, offline fake downloads, opt-in network
  test-chart.sh             chart contract (helm lint/template) — skips without helm
  README.md                 how to run; hermeticity guarantees
```

## Cluster-safety strategy (the core constraint)

Three independent layers:

1. **Dry-run first.** `install.sh`/`update.sh` are tested primarily through
   their `--dry-run` mode: the real scripts run, but print values/commands
   and touch nothing — no tools, no cluster.
2. **Mandatory mocks.** Tests that exercise real-mode paths construct the
   environment themselves with `env -i` (wiping the caller's `PATH`,
   `KUBECONFIG`, and env) and put `tests/stubs` FIRST on `PATH`. The stubs
   log every invocation to `$HC_STUB_LOG`; assertions check that log, which
   proves the mock — never a real binary — served the call. The stub `PATH`
   entry also shadows any real `helm`/`kubectl` that might exist on a host,
   so even a machine with a live cluster cannot be reached by the suite.
3. **Repo copies.** Scripts that write repo-root artifacts
   (`bootstrap-cluster.sh` writes `.env`; prereqs installs binaries) run
   against a throwaway copy of `scripts/`, `charts/` and the example files
   under a `mktemp -d` tree. `run-tests.sh` snapshots repo-root artifacts
   before the suite and fails if new ones appear after.

## Mocks

Each stub is POSIX-sh, logs `"<name> $*"`, and branches on env knobs
(`HC_STUB_*`): helm serves version/list/history/upgrade with a
`HC_STUB_HELM_VERSION` knob (v2-rejection, v4-acceptance, failure-injection);
kubectl serves canned `go-template`/`jsonpath` outputs (node archs, storage
classes, LoadBalancer state, PVC, secret key names, StatefulSet image) plus
exit-code knobs (`HC_STUB_NODES_FAIL`, `HC_STUB_NO_RELEASE`, ...); ssh/scp
simulate key installation (idempotent, via an `authorized_keys` fixture
file), timezone probing, `sudo cat` fallback, and scp failure.

## Offline prerequisite downloads

`test-install-prereqs.sh` builds local fake payloads (tiny `helm`/`kubectl`
shell scripts, tarred) and a `curl` mock that serves the fake tarballs, their
real sha256 checksums, the GitHub "latest release" JSON and `stable.txt`.
This drives the installer's entire Linux binary path — resolution, download,
checksum verify, extract, install, PATH hint, idempotent re-run — with zero
network; a knob flips one checksum to prove the mismatch abort. Gated to
Linux (sha256sum/tar semantics); the real-download test runs only with
`HC_TEST_NETWORK=1`.

## Test harness

`tests/lib.sh`: per-file PASS/FAIL/SKIP counters, `chk`-style assertions,
`expect_fail` (asserts exit 1 and keeps stderr for grep), `section`,
`finish` (summary + exit status). No `set -e` in tests (failures must be
counted, not fatal); `set -u` everywhere; bash 3.2+ only.

`run-tests.sh`: `bash -n` gate over all scripts and tests; `shellcheck -x`
when available (SKIP notice otherwise); runs `tests/test-*.sh` (all, or the
subset named on the command line); aggregates results; enforces the
repo-leak check; exits nonzero on any failure.

## Non-goals

- Testing real clusters or real SSH endpoints (the user's cluster is
  production for them; mocks only).
- Coverage tooling/metrics — assertion-count based.
- Testing macOS-only branches by execution (audited for portability; stated
  in each test file, since CI here is Linux).
