# Tasks: uninstall-script

## 1. Implementation

- [x] 1.1 `scripts/uninstall.sh`: flags (`--dry-run`/`--namespace`/`--release`/`--purge-data`/`--keep-secrets`/`--delete-namespace` + env equivalents), installer-style config resolution, dry-run gating, PVC protect/uninstall/purge, Secret cleanup, optional namespace removal
- [x] 1.2 `tests/stubs/helm`: `uninstall` case with `HC_STUB_UNINSTALL_FAIL`; `tests/stubs/kubectl`: `get pvc -o name` case (honors `HC_STUB_NO_PVC`)

## 2. Tests & docs

- [x] 2.1 `tests/test-uninstall.sh`: help/flag errors, dry-run without toolchain, e2e default (annotate+keep+secrets deleted), purge, keep-secrets, delete-namespace, release-absent idempotency, purge-with-release-absent, uninstall failure aborts, no-PVC case
- [x] 2.2 `tests/run-tests.sh`: coverage pair `uninstall:test-uninstall`
- [x] 2.3 README: rewrite the Uninstalling section around the script (correct the plain-`helm uninstall` data-loss claim)

## 3. Verification & close-out

- [ ] 3.1 Full suite green
- [x] 3.2 `openspec validate --all`; change archived; committed
