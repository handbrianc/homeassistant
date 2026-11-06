# Tasks: add-test-suite

## 1. Harness

- [x] 1.1 `tests/lib.sh` helpers; `tests/stubs/` mocks (helm/kubectl/ssh/scp) + `tests/fixtures/k3s.yaml`
- [x] 1.2 `tests/run-tests.sh`: static gate, subset selection, aggregation, repo-leak check

## 2. Tests

- [x] 2.1 `test-common.sh`: unit tests for every common.sh function (validation, env, values render, secret apply, helm args, rollout)
- [x] 2.2 `test-install.sh`: dry-run suite (no tools/cluster) + mock e2e (v2/v4, unreachable, failure, access URLs, secret hygiene)
- [x] 2.3 `test-update.sh`: dry-run + mock e2e with rollback hints
- [x] 2.4 `test-bootstrap.sh`: ported 69-check e2e on repo copies (LB/NodePort/review-only/backup/fallback/idempotency)
- [x] 2.5 `test-install-prereqs.sh`: flags/--check, offline fake downloads + checksum abort, opt-in network test
- [x] 2.6 `test-chart.sh`: lint/template contract, skips without helm
- [x] 2.7 `tests/README.md` + root README pointer

## 3. Verification & close-out

- [x] 3.1 Full suite green locally (incl. HELM_BIN v3 and v4 chart runs; `HC_TEST_NETWORK=1` once)
- [x] 3.2 `openspec validate --all`; change archived; committed
