# Design

## Context

Verified against the running HA 2026.11.0 (in-pod source, `/usr/src/homeassistant/homeassistant/components/http/config.py`):

- HTTP settings live in `Store` key `http`, `version 3`, `minor_version 1`,
  shape `{stable, pending, yaml_migration_done}`.
- `async_load_config` prefers a `pending` config **without** a recorded error;
  a pending config runs as a trial with a 5-minute auto-revert
  (`async_schedule_revert_to_stable` → marks `not_promoted` and calls
  `homeassistant.restart`). Promotion (`async_promote_pending`) is a websocket
  command the UI drives — unreachable in a headless install.
- `async_migrate_yaml` stages a pending config **only** when the schema-
  validated YAML differs from the stable slot (`_strip_meta` comparison). If
  they are equal, no pending is staged, the store flips
  `yaml_migration_done` to true and HA activates the stable slot directly.
- `HTTP_STORAGE_SCHEMA` fills defaults for everything the YAML omits:
  `server_port=8123`, `cors_allowed_origins=["https://cast.home-assistant.io"]`,
  `login_attempts_threshold=-1`, `ip_ban_enabled=true`,
  `ssl_profile="intermediate_v6"` (current default), `use_x_frame_options=true`.
  `trusted_proxies` entries are normalized through `ip_network()` to their
  canonical string form (a `/16` CIDR passes through unchanged).
- `Store.async_load` **raises** `UnsupportedStorageVersionError` when the file's
  version exceeds `max_readable_version` (default: the app's own version) —
  callers in the http component do not catch it. A store file must therefore
  never be older-chart-seeded onto an HA that does not support its version.

## Goals / Non-Goals

- Goals: fresh installs on HA ≥ 2026.11.0 get a proxy-trusted HTTP server from
  the first request; no trial window, no UI confirmation, no restart cycle.
- Non-Goals: repairing stores on volumes that already have one (manual
  procedure, already applied live); managing HTTP settings via Helm beyond the
  initial seed (the store is user-owned after first boot); UI-based promotion
  automation.

## Decisions

1. **Seed the store with a stable slot that equals HA's schema output for our
   YAML.** Content (matching `HTTP_STORAGE_SCHEMA` defaults + our proxy
   settings, `pending: null`, `yaml_migration_done: false` so HA itself flips
   it by running its migration as a no-op):
   `{server_port: 8123, cors_allowed_origins: ["https://cast.home-assistant.io"],
   use_x_forwarded_for: true, trusted_proxies: <chart values>,
   login_attempts_threshold: -1, ip_ban_enabled: true,
   ssl_profile: "intermediate_v6", use_x_frame_options: true}`.
   The store loader reads the file raw (no schema re-validation), so a
   hand-written file with exactly these keys loads; omitting the
   `created_at`/`error` metadata keys is safe — `_strip_meta` tolerates their
   absence and HA's first persist canonicalizes the file.
   *Alternative considered*: leaving the YAML trial to auto-revert → broken
   (revert target lacks proxy trust; that is the bug being fixed).

2. **Version-gate the seed** (template helper `homeassistant.httpStoreSeedEnabled`):
   semver tag ≥ `2026.11.0` → seed; non-semver tag (`latest`, `stable`) → seed
   (assumed current); semver below → no seed, YAML block remains the mechanism.
   *Alternative considered*: always seed → would hand HA versions without store
   v3 an unreadable file (`UnsupportedStorageVersionError` → http setup fails),
   strictly worse than today. Pinning the exact store-introduction version was
   not possible offline; 2026.11.0 is the verified floor.

3. **Keep the YAML `http:` block always.** Needed by HA versions without the
   store; on store versions it is ignored and triggers HA's
   `yaml_still_present_after_migration` repair warning — accepted as cosmetic.
   *Alternative considered*: omitting the YAML block when seeding → silently
   loses proxy trust on a rollback to a pre-store HA (where the seed file is
   simply ignored).

4. **Per-file init-container checks.** Each seed target is written only when
   missing: `configuration.yaml` (unchanged behavior) and
   `/config/.storage/http` (new). This also covers installs that already have
   a configuration but no store file (pre-2026.11 chart → 2026.11 chart
   upgrade). The seed key is optional in the ConfigMap, so custom
   `existingConfigMap` users are unaffected when their ConfigMap lacks it.
   *Alternative considered*: gate everything on an empty `/config` → the store
   seed could never reach an existing volume.

5. **No new values.** The seed reuses `ingress.enabled` +
   `ingress.trustedProxies` and the same render conditions as the YAML block.

## Risks / Trade-offs

- [Downgrading HA below 2026.11 after the store file exists] → HA's storage
  loader raises `UnsupportedStorageVersionError` and http setup fails.
  Mitigation: documented in proposal and chart comments (remove
  `/config/.storage/http` or wipe the volume before downgrading); the init
  container never deletes user data.
- [HA changes schema defaults (e.g. new ssl profile or port) in a future
  release] → seeded stable no longer equals the schema output → the YAML
  migration stages a pending trial → 5-minute auto-revert to *stable* — which
  still carries proxy trust, so the failure mode degrades to one extra restart
  5 minutes after first boot, not to a broken install.
- [Store file shape drift (future major version)] → HA migrates older store
  files on load; our seed targets verified store version 3 and is gated to the
  versions known to read it.
- [`trusted_proxies` normalization] → CIDRs are passed through `ip_network()`
  unchanged; host addresses without a mask would be canonicalized by HA, so
  the chart documents CIDR form (existing behavior).

## Migration Plan

1. Ship the chart change; `helm upgrade` renders the new ConfigMap key and
   init-container script. Existing volumes are untouched (store file exists).
2. Fresh installs: the init container seeds both files; first boot verifies
   via the frontend answering through the ingress (no 400s) and
   `/config/.storage/http` containing the stable slot with proxy trust.
3. Rollback: `helm rollback` restores the previous chart; a previously seeded
   store keeps working (it is user data from HA's perspective).

## Open Questions

None — the store behavior was verified against the installed HA 2026.11.0
source in the live pod; the seed shape was validated by repairing the live
install manually with exactly this mechanism.
