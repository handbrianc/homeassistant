# Proposal: helm4-rollback-flag

## Why

Helm 4 renamed `--atomic` to `--rollback-on-failure` (helm/helm#13629): on
`helm upgrade` the old flag still works but prints a deprecation warning on
every run, and on `helm install` it hard-fails. The scripts build the shared
`helm upgrade --install` argument list with a hardcoded `--atomic`
(`scripts/lib/common.sh` `helm_release_args`, used by both `install.sh` and
`update.sh`), so every helm-4 run warns. Helm 3 does not know the new flag
name, so the flag must be chosen per detected helm generation.

## What Changes

- `scripts/lib/common.sh`:
  - `require_helm` caches the detected helm major version (`HC_HELM_MAJOR`).
  - New `helm_major_version` helper (cached value, else live `helm version`
    detection; empty when helm is absent — the dry-run/preview case).
  - `helm_release_args` emits `--atomic` for helm 3 and
    `--rollback-on-failure` for helm 4+; when no helm is detectable (dry-run
    without a toolchain), it previews the helm 4 name.
- `scripts/install.sh` usage comment updated accordingly.
- Tests: version-aware arg assertions (absent → preview default, v3 →
  `--atomic`, v4 → `--rollback-on-failure`) and e2e mock-log proof that the
  v3 run passes `--atomic` and the v4 run passes `--rollback-on-failure`.

## Capabilities

### installer-cli

MODIFIED requirement: "Idempotent install" — the rollback-on-failure flag is
now chosen by detected helm generation instead of hardcoded `--atomic`.

## Impact

- Affected specs: `installer-cli` (one scenario restated).
- Affected code: `scripts/lib/common.sh` (two functions), one comment in
  `scripts/install.sh`, test assertions in `tests/test-common.sh` and
  `tests/test-install.sh`. Behavior on helm 3 is unchanged.
