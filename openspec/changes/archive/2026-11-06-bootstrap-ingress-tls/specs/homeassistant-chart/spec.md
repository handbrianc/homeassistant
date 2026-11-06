# homeassistant-chart Delta

## MODIFIED Requirements

### Requirement: Optional ingress

The chart MUST render an Ingress only when enabled.
Ingress is opt-in and standard.

#### Scenario: Ingress disabled by default
- **WHEN** `ingress.enabled=false` (the default)
- **THEN** no Ingress is rendered

#### Scenario: Ingress enabled
- **WHEN** `ingress.enabled=true`
- **THEN** an Ingress is rendered with `className`, `annotations`, `hosts` and
  optional `tls` from values

#### Scenario: Catch-all rule without a host
- **WHEN** a `hosts` entry has an empty or absent `host`
- **THEN** the rendered rule omits the `host` key entirely (never
  `host: ""`), so the rule matches any hostname reaching the ingress
  controller

#### Scenario: TLS block from values
- **WHEN** `ingress.tls` is a non-empty list of entries (e.g.
  `secretName` with an optional `hosts` list)
- **THEN** the Ingress renders the `tls` block verbatim from values

### Requirement: First-boot bootstrap configuration

The chart MUST seed a working configuration on first boot and MUST NOT overwrite an existing configuration.
A freshly provisioned `/config` must yield a working Home Assistant without
manual YAML editing, without ever overwriting an existing configuration.

#### Scenario: Empty config volume
- **WHEN** the pod starts and `/config/configuration.yaml` does not exist
- **THEN** a minimal working `configuration.yaml` (from the chart's
  `bootstrapConfig.configuration`, rendered via a ConfigMap) is copied into
  `/config` by an init container, and the config documents the `!env_var`
  pattern for secrets

#### Scenario: Existing configuration
- **WHEN** `/config/configuration.yaml` already exists
- **THEN** the init container leaves `/config` untouched

#### Scenario: Trusted-proxy seed behind an ingress
- **WHEN** ingress is enabled and `ingress.trustedProxies` is a non-empty
  list of CIDRs
- **THEN** the seeded configuration also contains
  `http.use_x_forwarded_for: true` and `http.trusted_proxies` with those
  CIDRs, so logins through the reverse proxy are accepted

#### Scenario: No trusted proxies without ingress
- **WHEN** ingress is disabled or `ingress.trustedProxies` is empty
- **THEN** no `http:` section is added to the seeded configuration
