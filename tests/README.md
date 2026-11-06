# Test suite

`tests/run-tests.sh` verifies every script in this repository and the chart
contract. **The suite never touches a cluster** — it is dry-run and mock based
only — and the runner fails when any test leaks artifacts (`.env`,
`secrets.env`, backups) into the real repo tree.

## Running

```bash
tests/run-tests.sh                          # everything: syntax gate, shellcheck, all tests
tests/run-tests.sh bootstrap                # subset by name (see list below)
HELM_BIN=/path/to/helm tests/run-tests.sh chart   # chart tests with a specific helm
HC_TEST_NETWORK=1 tests/run-tests.sh install-prereqs   # also runs the real-download test
```

Test names: `common`, `install`, `update`, `bootstrap`, `install-prereqs`,
`chart`. Requirements: bash 3.2+ (Linux and macOS), nothing else. `shellcheck`
and `helm` are optional; affected sections SKIP with a notice when absent.

## How cluster-safety is enforced

1. **Dry-run first.** `install.sh`/`update.sh` are exercised through their
   built-in `--dry-run` mode: the real scripts run but print values/commands
   and touch nothing — no `helm`/`kubectl` on PATH, no network, no cluster.
2. **Mandatory mocks.** Tests that exercise real-mode behavior build their
   environment with `env -i` (the caller's `PATH`/`KUBECONFIG` cannot leak in)
   and put `tests/stubs` FIRST on `PATH`. The committed stub `helm`, `kubectl`,
   `ssh` and `scp` log every invocation to `$HC_STUB_LOG`; tests assert against
   that log as proof the mock — never a real binary — served the call. Even on
   a machine with a live cluster, real tools are unreachable.
3. **Throwaway repo copies.** Scripts that write repo-root artifacts
   (`bootstrap-cluster.sh` writes `.env`) run against a copy under `$TESTS_TMP`
   (`fresh_repo` in `lib.sh`), never the real tree.
4. **Leak check.** `run-tests.sh` snapshots repo-root `.env*`/`secrets.env*`
   files before the suite and fails if new ones appear after.
5. **Network is opt-in.** The only real-network test (the prerequisites
   installer's genuine upstream download) runs solely with `HC_TEST_NETWORK=1`.
   Offline, that installer is tested against fake tarballs served by a `curl`
   mock that is the only `curl` on PATH (see `test-install-prereqs.sh`).

## Mock knobs (`HC_STUB_*`)

| Knob | Stub | Effect |
| --- | --- | --- |
| `HC_STUB_HELM_VERSION` | helm | version reported (default `v3.22.1`) |
| `HC_STUB_HELM_FAIL=1` | helm | `upgrade` fails |
| `HC_STUB_NO_RELEASE=1` | helm/kubectl | no existing release |
| `HC_STUB_HIST_ONE=1` / `HC_STUB_HIST_EMPTY=1` | helm | release history shapes |
| `HC_STUB_ARCHS` | kubectl | node architectures served |
| `HC_STUB_NO_LB` / `HC_STUB_NO_INGRESS` / `HC_STUB_NO_PVC` / `HC_STUB_NO_STS` | kubectl | resource-absent shapes |
| `HC_STUB_NODES_FAIL=1` / `HC_STUB_ROLLOUT_FAIL=1` | kubectl | injected failures |
| `HC_STUB_SVC_MODE=lb\|pending\|nodeport\|none` | kubectl | Service shape served |
| `HC_STUB_SSH_BATCH_FAIL=1` | ssh | batch auth fails (drives interactive retry) |
| `HC_STUB_SCP_FAIL=1` | scp | copy fails (drives `sudo cat` fallback) |
| `HC_STUB_AK` / `HC_STUB_KUBECONFIG` | ssh/scp | authorized_keys + kubeconfig fixtures |
| `HC_STUB_BAD_SHA=1` | curl (prereqs) | poisons the helm checksum fixture |

## Notes

- macOS: the suite is audited for bash 3.2+/BSD portability; sections relying
  on GNU tools (`stat -c`, `sha256sum`-based checksum fixtures) are
  Linux-gated and skip elsewhere. Executed-verification here happens on Linux.
- Test files run without `set -e` (failures are counted, not fatal) and with
  `set -u`; `lib.sh` holds the shared helpers.
- The chart tests use `--kube-version 1.31.0` on every helm call so helm 4
  accepts the chart and nothing probes a local cluster.
