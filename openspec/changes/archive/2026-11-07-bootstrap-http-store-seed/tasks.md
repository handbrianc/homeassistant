# Tasks

## 1. Chart changes

- [x] 1.1 Add `homeassistant.httpStoreSeedEnabled` helper in `charts/homeassistant/templates/_helpers.tpl` — true when `image.tag` is non-semver, or semver ≥ 2026.11.0; verify with `helm template` on `--set image.tag=2026.10.0` / `2026.11.0` / `latest` renders
- [x] 1.2 Extend `charts/homeassistant/templates/configmap.yaml` with the `storage-http` key (store-v3 JSON, stable slot with proxy trust, no pending, `yaml_migration_done: false`), rendered only when `bootstrapConfig.enabled` without `existingConfigMap`, ingress enabled, `trustedProxies` non-empty, and the version gate passes; verify the seed JSON parses with `jq` from a rendered manifest
- [x] 1.3 Extend the init container in `charts/homeassistant/templates/statefulset.yaml` — per-file seeding: copy `configuration.yaml` when missing (unchanged), copy `storage-http` to `/config/.storage/http` (with `mkdir -p /config/.storage`) only when the seed key exists in the ConfigMap and the target file is missing; verify rendered script contains both guards

## 2. Tests (tests/test-chart.sh)

- [x] 2.1 Add chart render tests: seed key present with stable proxy content for `2026.11.0` and `latest`; absent for `2026.10.0`; absent when ingress disabled or `trustedProxies` empty; seed JSON parses via `jq` (version 3, stable.use_x_forwarded_for true, trusted_proxies list, pending null); run `tests/test-chart.sh` green
- [x] 2.2 Add init-script contract tests: rendered StatefulSet contains the `mkdir -p /config/.storage` + skip-if-exists guard for the store and keeps the skip-if-exists guard for `configuration.yaml`; run `tests/test-chart.sh` green

## 3. Full validation

- [x] 3.1 shellcheck clean on all changed shell scripts (`shellcheck tests/*.sh scripts/*.sh scripts/lib/*.sh`)
- [x] 3.2 Full suite green (all test areas): `tests/run-tests.sh` — 578 pass / 0 fail under helm v4.3.1 (no v3 binary remains on the box; the new template constructs are sprig features available in v3 as well), no regressions against the 554-pass baseline
- [x] 3.3 `openspec validate --all` passes (delta requirements + scenario titles intact)

## 4. Live-cluster verification (read-only cluster objects + user-visible behavior)

- [x] 4.1 Dry-run render against live values (`DRY_RUN=1 bash scripts/install.sh` or `helm template` with the same values): new ConfigMap key + init script present, release objects otherwise unchanged
- [x] 4.2 Apply via `bash scripts/update.sh` on the live release; verify pod rolls, comes Ready, release revision increments, and the existing `/config/.storage/http` is untouched (file mtime/stable content unchanged, init skipped seeding)
- [x] 4.3 End-to-end: `https://homeassistant.internal.earthenwire.com/` answers 302 → onboarding (no 400), no `forwarded` errors in the pod log, Certificate still Ready
