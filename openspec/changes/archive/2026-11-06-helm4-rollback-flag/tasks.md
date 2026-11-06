# Tasks: helm4-rollback-flag

## 1. Implementation

- [x] 1.1 `common.sh`: `require_helm` caches `HC_HELM_MAJOR`; add `helm_major_version`; `helm_release_args` emits `--atomic` (v3) / `--rollback-on-failure` (v4+, or undetectable preview)

## 2. Tests

- [x] 2.1 `test-common.sh`: version-aware arg assertions (absent → preview default, v3 stub → `--atomic`, v4 stub → `--rollback-on-failure`)
- [x] 2.2 `test-install.sh`: dry-run regex uses the preview default; e2e mock log proves `--atomic` on the v3 run and `--rollback-on-failure` on the v4 run

## 3. Verification & close-out

- [x] 3.1 Full suite green (HELM_BIN v3 chart run; v4 chart run unaffected)
- [x] 3.2 `openspec validate --all`; change archived; committed
