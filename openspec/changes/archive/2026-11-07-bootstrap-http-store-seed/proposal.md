# Proposal

## Why

Home Assistant 2026.11 moved HTTP integration settings out of `configuration.yaml`
into a dedicated on-disk store, `/config/.storage/http`, with a
stable/pending trial-promotion model:

- The YAML `http:` block is migrated **once** into a *pending* config that runs
  as a **5-minute trial**. If it is not promoted (a UI confirmation) within
  `AUTO_REVERT_DELAY = 5 min`, HA marks it `not_promoted`, **restarts itself**,
  and permanently falls back to the last-known-good *stable* config. A failed
  pending config "is kept for inspection but never applied again".
- After that first migration, `yaml_migration_done: true` makes every later
  boot **ignore the YAML `http:` block entirely** (HA raises a repair issue
  saying so).

This breaks the chart's YAML-only reverse-proxy seeding: on a headless install
nobody can click the promotion confirmation, so a fresh install briefly works
(during the 5-minute trial) and then serves HTTP 400 for every proxied request
forever — exactly what happened on the first live install, where the pod was
restarted inside the trial window and the pending config was marked
`not_promoted`. Verified live: `/config/.storage/http` held a stable slot with
no proxy settings (runtime default `use_x_forwarded_for=False` → 400) and a
failed pending slot with the correct settings; the correct-looking
`configuration.yaml` changed nothing across restarts.

## What Changes

- The bootstrap init container additionally seeds `/config/.storage/http`
  (HA's HTTP config store) alongside `configuration.yaml` on first boot, so HA
  starts directly in the *stable* slot with reverse-proxy trust applied — no
  pending trial, no 5-minute revert window, no UI confirmation needed.
- The seed is written so that HA's own YAML migration is a no-op: the seeded
  stable config equals what HA's `HTTP_STORAGE_SCHEMA` produces from the YAML
  `http:` block, so `async_migrate_yaml` stages no pending config at all.
- The seed is **version-gated**: it is rendered only when the pinned HA image
  version is ≥ 2026.11.0 (the verified store version 3) or the tag is
  non-semver (`latest`, `stable`). HA raises `UnsupportedStorageVersionError`
  when a store file is newer than the running version supports, so seeding
  unconditionally would break older HA versions' http setup.
- The bootstrap init container check becomes per-file (write each seed only
  when its target file is missing) instead of gating the whole bootstrap on
  `configuration.yaml` — this also lets the store seed reach installs that
  already have a `configuration.yaml` but no store file (e.g. upgrades of
  pre-2026.11 installs).
- `configuration.yaml` keeps the YAML `http:` block (needed by HA versions
  without the store, and harmless — if ignored with a repair warning — on
  versions with it).

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `homeassistant-chart`: "First-boot bootstrap configuration" requirement —
  the bootstrap seed now also covers HA's HTTP config store
  (`/config/.storage/http`), version-gated, per-file, never overwriting an
  existing store.

## Impact

- **Code**: `charts/homeassistant/templates/configmap.yaml` (new ConfigMap key
  with the store seed JSON, gated on ingress + trustedProxies + HA version),
  `charts/homeassistant/templates/statefulset.yaml` (init container copies the
  seed into `/config/.storage/http` when missing), `charts/homeassistant/values.yaml`
  (comments only).
- **New template helper**: version gate (`homeassistant.httpStoreSeedEnabled`)
  in `_helpers.tpl`.
- **Tests**: `tests/test-chart.sh` — seed rendering, version gating, no-overwrite
  guards, JSON validity.
- **Behavior on HA ≥ 2026.11.0 fresh installs**: proxy-trusted HTTP works from
  the very first request with no trial/restart cycle.
- **Downgrade caveat (documented)**: once the store file exists on the volume,
  downgrading HA to a version whose http store version is < 3 makes HA's
  `Store.async_load` raise `UnsupportedStorageVersionError` (http setup fails).
  Chart users must not downgrade HA across the store-version boundary without
  removing `/config/.storage/http`.
- **Live cluster**: a `helm upgrade` applies the new chart; the existing store
  file is never touched (the live install was already repaired manually).
