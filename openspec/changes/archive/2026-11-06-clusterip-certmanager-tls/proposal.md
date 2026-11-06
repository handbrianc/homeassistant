# Proposal: clusterip-certmanager-tls

## Why

Three follow-ups to the ingress/TLS work, from actual usage intent:

1. **The ingress fronts the pod through a Service, and that service should be
   ClusterIP only.** Today bootstrap derives `SERVICE_TYPE=LoadBalancer` (or a
   NodePort fallback) even when it also enables the ingress — exposing the same
   pod twice. When an ingress controller fronts Home Assistant, LoadBalancer /
   NodePort exposure is redundant.
2. **cert-manager is a standing assumption on this cluster.** The current TLS
   contract carries two extra mechanisms "for the no-cert-manager case": a PEM
   cert/key pair applied as a Secret, and the `INGRESS_TLS_CERTIFICATE` toggle
   choosing between them and the chart's Certificate resource. With cert-manager
   always available, both extra mechanisms and every "self-signed until you
   provision something" message are dead weight — and a user-applied TLS Secret
   would be overwritten by cert-manager renewals anyway.
3. **Wildcard certificates should be selectable.** A wildcard (`*.example.com`)
   is the common cert-manager pattern for a home cluster; today the certificate's
   DNS names are hard-wired to `INGRESS_HOST`.

## What Changes

- **ClusterIP enforcement (installer)**: when `INGRESS_ENABLED=true`,
  `render_values_file` renders `service.type: "ClusterIP"` (always, even when
  `SERVICE_TYPE` is empty — the chart default is LoadBalancer) and aborts when a
  non-ClusterIP `SERVICE_TYPE` is explicitly configured. Bootstrap defaults
  `SERVICE_TYPE=ClusterIP` (clearing the NodePort fallback) when it detects an
  ingress controller; the LoadBalancer/NodePort derivation now only applies when
  no ingress controller exists.
- **cert-manager-only TLS (installer)**: `INGRESS_TLS_CERT_FILE`,
  `INGRESS_TLS_KEY_FILE` and `INGRESS_TLS_CERTIFICATE` are removed from the env
  contract. `INGRESS_TLS_ENABLED=true` now REQUIRES `INGRESS_TLS_ISSUER` (abort
  with a message naming the variable — the chart's `issuerRef.name` is required,
  so there is no renderable half-state anyway); the rendered values ALWAYS enable
  the chart's Certificate (`ingress.certificate`) with the issuerRef and share
  the Ingress `tls` Secret; the `cert-manager.io/cluster-issuer` annotation is
  never rendered; `create_or_update_tls_secret` (the file→Secret pipeline) is
  deleted. All "self-signed certificate" references disappear from the scripts.
- **Wildcard-capable DNS names (installer)**: new `INGRESS_TLS_DNS_NAMES`
  (comma-separated; empty → `[INGRESS_HOST]`, as before) overrides the
  Certificate's `dnsNames`, e.g. `*.example.com,example.com` for a wildcard.
- **Chart**: values comments updated (wildcards allowed in `dnsNames`; ClusterIP
  note on `service.type`); one chart test locks wildcard dnsNames rendering.
- **Bootstrap**: cert-manager CRD probe now only reports/warns (no var to set);
  `.env` block, safety asserts and the summary report updated; the generated
  `.env` carries `INGRESS_TLS_DNS_NAMES=""`.
- **Env-var review**: `INGRESS_TLS_ENABLED` stays (opt-out), as do
  `INGRESS_TLS_SECRET_NAME`, `INGRESS_TLS_ISSUER`, `INGRESS_TLS_ISSUER_KIND`,
  `INGRESS_TRUSTED_PROXIES`, and the exposure vars (`SERVICE_TYPE`,
  `SERVICE_PORT`, `LOADBALANCER_IP`, `NODE_PORT` — all still apply when the
  ingress is off). Removed: the three TLS vars above. Added:
  `INGRESS_TLS_DNS_NAMES`.

## Capabilities

### installer-cli

- REMOVED + ADDED: "Secret handling" is replaced by "Credential handling"
  (app credentials, unchanged behavior) and "Ingress TLS certificate issuance"
  (cert-manager is the only TLS source; issuer required; wildcard dnsNames; no
  shim annotation; file-pair scenarios gone).
- MODIFIED: "Cluster bootstrap" (ingress detection also defaults
  `SERVICE_TYPE=ClusterIP`; CRD presence is reported/warned without a var).
- MODIFIED: "Generated values safety" (ingress forces ClusterIP; TLS requires
  an issuer — both enforced at render time).

### homeassistant-chart

- MODIFIED: "Cert-manager TLS certificate" (wildcard dnsNames documented and
  tested; values comments mention ClusterIP-only when ingress-fronted).

## Impact

- Affected specs: `installer-cli` (3 requirements), `homeassistant-chart`
  (1 requirement).
- Affected code: `common.sh` (contract + render; one function deleted),
  `install.sh`, `update.sh`, `bootstrap-cluster.sh`, `.env.example`, README,
  chart values comments, four test files + chart test. No chart template change
  (the Certificate already takes any dnsNames list).
