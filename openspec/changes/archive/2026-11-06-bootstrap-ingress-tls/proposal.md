# Proposal: bootstrap-ingress-tls

## Why

`bootstrap-cluster.sh` detects an ingress controller but deliberately leaves
`INGRESS_ENABLED=false` ("opt-in"), so on every k3s cluster (Traefik ships by
default) the user must hand-edit `.env` to use the ingress. When they do, TLS
is unsupported by the installer lane (the chart passes `ingress.tls` through,
but nothing renders it from the environment), and Home Assistant itself
rejects `X-Forwarded-For` from a proxy that is not in `http.trusted_proxies`
(logins through the ingress fail with HTTP 400) — the bootstrap config never
writes that section.

## What Changes

- `scripts/bootstrap-cluster.sh`:
  - `review_ingress_class` defaults `INGRESS_ENABLED=true` when an ingress
    class is detected (Traefik preferred, as before) and pre-fills the TLS
    defaults (`INGRESS_TLS_ENABLED=true`,
    `INGRESS_TLS_SECRET_NAME=<release>-tls`,
    `INGRESS_TRUSTED_PROXIES=10.42.0.0/16` — the k3s default pod CIDR).
  - Detects the cert-manager CRD (`certificates.cert-manager.io`) and reports
    whether automatic certificates (issuer) or user-provided cert/key files
    are the path forward. No controller → everything stays disabled.
- `scripts/lib/common.sh`:
  - New env contract: `INGRESS_TLS_ENABLED`, `INGRESS_TLS_SECRET_NAME`,
    `INGRESS_TLS_CERT_FILE`, `INGRESS_TLS_KEY_FILE`, `INGRESS_TLS_ISSUER`,
    `INGRESS_TRUSTED_PROXIES` (defaults, YAML-safety, bool/int parsing).
  - `render_values_file` renders `ingress.annotations`
    (`cert-manager.io/cluster-issuer`), a hostless catch-all rule when
    `INGRESS_HOST` is empty, the `tls` block (secretName + host list) and
    `ingress.trustedProxies`.
  - New `create_or_update_tls_secret`: applies cert/key files as the
    `kubernetes.io/tls` Secret via the same client-side dry-run pipeline as
    the app Secret; values never printed. Warns (does not die) when TLS is
    enabled without cert files or an issuer; dies on a half-specified or
    unreadable file pair.
- `scripts/install.sh` / `scripts/update.sh`: apply the TLS Secret, extended
  config line, and install prints the ingress access URL.
- Chart: `ingress.yaml` omits `host` for hostless rule entries (catch-all);
  `configmap.yaml` appends the `http.trusted_proxies`/`use_x_forwarded_for`
  seed when ingress is enabled and `ingress.trustedProxies` is set;
  `values.yaml` gains `ingress.trustedProxies` (contract key).
- `.env.example` + README document the new variables and new bootstrap
  defaults.

## Capabilities

### installer-cli

MODIFIED: "Cluster bootstrap" (cluster review defaults the ingress on with TLS
and trusted proxies, detects cert-manager) and "Secret handling" (TLS Secret
from cert/key files, same no-print guarantee, warn-when-unprovisioned).

### homeassistant-chart

MODIFIED: "Optional ingress" (hostless catch-all rule, TLS rendering) and
"First-boot bootstrap configuration" (trusted-proxy seed for proxied setups).

## Impact

- Affected specs: `installer-cli` (2 requirements), `homeassistant-chart`
  (2 requirements).
- Affected code: bootstrap, common.sh, install.sh, update.sh, chart
  (2 templates + values), `.env.example`, README, three test files plus
  `tests/stubs/kubectl` (cert-manager CRD knob).
- Helm 3/4 behavior unchanged; no cluster-mutating behavior outside the
  existing dry-run-piped Secret apply pattern.
