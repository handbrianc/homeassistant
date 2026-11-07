# Spec Delta — homeassistant-chart

## MODIFIED Requirements

### Requirement: First-boot bootstrap configuration

The chart MUST seed a working configuration on first boot and MUST NOT overwrite an existing configuration.
A freshly provisioned `/config` must yield a working Home Assistant without
manual YAML editing, without ever overwriting an existing configuration.
Because HA 2026.11 moved HTTP settings into the `/config/.storage/http` store
(stable/pending trial promotion; the YAML `http:` block is migrated once and
then ignored), the bootstrap seed MUST also cover that store so reverse-proxy
trust is active from the very first request without a UI confirmation step.

#### Scenario: Empty config volume
- **WHEN** the pod starts and `/config/configuration.yaml` does not exist
- **THEN** a minimal working `configuration.yaml` (from the chart's
  `bootstrapConfig.configuration`, rendered via a ConfigMap) is copied into
  `/config` by an init container, and the config documents the `!env_var`
  pattern for secrets

#### Scenario: Existing configuration
- **WHEN** `/config/configuration.yaml` already exists
- **THEN** the init container leaves it untouched; seeding is per file, so
  each seed artifact is written only when its own target file is missing

#### Scenario: Trusted-proxy seed behind an ingress
- **WHEN** ingress is enabled and `ingress.trustedProxies` is a non-empty
  list of CIDRs
- **THEN** the seeded configuration also contains
  `http.use_x_forwarded_for: true` and `http.trusted_proxies` with those
  CIDRs, so logins through the reverse proxy are accepted

#### Scenario: No trusted proxies without ingress
- **WHEN** ingress is disabled or `ingress.trustedProxies` is empty
- **THEN** no `http:` section is added to the seeded configuration and no
  HTTP config store is seeded

#### Scenario: HTTP config store seed for versions with the store
- **WHEN** the HA image version supports the HTTP config store (semantic
  version ≥ 2026.11.0, or a non-semver tag such as `latest`) and ingress is
  enabled with a non-empty `trustedProxies` list
- **THEN** the init container seeds `/config/.storage/http` (when missing)
  with a store file whose stable config carries `use_x_forwarded_for: true`
  and the `trusted_proxies` CIDRs and which stages no pending config, so HA
  boots directly into the stable slot with reverse-proxy trust — no 5-minute
  trial, no automatic revert-and-restart, no `not_promoted` failure

#### Scenario: No HTTP config store seed for versions without the store
- **WHEN** the HA image version is a semantic version below 2026.11.0
- **THEN** no HTTP config store seed is rendered (a store file newer than the
  running HA supports makes its storage loader reject it and its http
  integration fail); the YAML `http:` block remains the seeding mechanism

#### Scenario: Existing HTTP config store is never overwritten
- **WHEN** `/config/.storage/http` already exists
- **THEN** the init container leaves it untouched; the user's live HTTP
  settings (including changes made through the Home Assistant UI) win
