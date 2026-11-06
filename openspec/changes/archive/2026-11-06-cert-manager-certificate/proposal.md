# Proposal: cert-manager-certificate

## Why

The ingress TLS work shipped two paths: cert/key files applied as a Secret, and
the `cert-manager.io/cluster-issuer` Ingress annotation (implicit — cert-manager's
ingress shim creates the Certificate). The cluster already runs cert-manager, and
the certificate creation should be part of the chart itself: an explicit
`Certificate` resource the chart renders and helm manages, whose Secret the
Ingress uses. Explicit resources are visible in `kubectl get certificate`,
tunable, and independent of the ingress shim.

The request's second half (bootstrap should use the cluster's default storage
class) is already implemented: `review_storage_class` reads the
`storageclass.kubernetes.io/is-default-class` annotation and writes
`STORAGE_CLASS` to `.env` (suite-asserted); verified, no change needed.

## What Changes

- Chart: new `templates/certificate.yaml` rendering a `cert-manager.io/v1`
  Certificate when `ingress.certificate.enabled` — `spec.secretName` (default
  `<fullname>-tls`, overridable), `spec.issuerRef` with an explicitly emitted
  `kind` (default `ClusterIssuer`; cert-manager's own default is a namespaced
  `Issuer`), `spec.dnsNames` from `ingress.certificate.dnsNames`, falling back
  to the non-empty `ingress.hosts` entries. `values.yaml` gains the
  `ingress.certificate` contract block.
- Installer lane: new env vars `INGRESS_TLS_CERTIFICATE` (bool, default false)
  and `INGRESS_TLS_ISSUER_KIND` (empty → `ClusterIssuer` at render).
  `render_values_file` emits the `ingress.certificate` block when
  `INGRESS_TLS_CERTIFICATE=true` and `INGRESS_TLS_ISSUER` is set, and
  suppresses the `cert-manager.io/cluster-issuer` annotation in that mode (no
  duplicate Certificate via the shim); `create_or_update_tls_secret` gains
  certificate-mode messaging; install/update config lines show the mode.
- Bootstrap: when the `certificates.cert-manager.io` CRD is present the
  generated `.env` defaults `INGRESS_TLS_CERTIFICATE=true` (issuer name stays
  empty — install warns until it is set); without the CRD it stays `false`.
- `.env.example` + README document the new variables.

## Capabilities

### installer-cli

MODIFIED: "Cluster bootstrap" (cert-manager CRD defaults `INGRESS_TLS_CERTIFICATE=true`)
and "Secret handling" (certificate-mode rendering: values enable the chart
Certificate with no shim annotation; missing issuer warns).

### homeassistant-chart

ADDED requirement: "Cert-manager TLS certificate" (explicit Certificate
resource sharing its Secret with the Ingress).

## Impact

- Affected specs: `installer-cli` (2 requirements), `homeassistant-chart`
  (1 new requirement).
- Affected code: chart (1 new template + values), `common.sh`, `install.sh`,
  `update.sh`, bootstrap, `.env.example`, README, three test files. The
  Ingress template is unchanged (its `tls` block already references the
  secret).
