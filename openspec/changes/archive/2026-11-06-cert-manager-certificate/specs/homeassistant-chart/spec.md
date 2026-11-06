# homeassistant-chart Delta

## ADDED Requirements

### Requirement: Cert-manager TLS certificate

The chart MUST be able to create the ingress TLS certificate via cert-manager,
and the Ingress MUST reference the Secret cert-manager maintains.
Certificate issuance and renewal are delegated to cert-manager through an
explicit `Certificate` resource; the chart renders it only when opted in.

#### Scenario: Certificate disabled by default
- **WHEN** `ingress.certificate.enabled=false` (the default)
- **THEN** no Certificate resource is rendered

#### Scenario: Certificate rendered
- **WHEN** `ingress.certificate.enabled=true` with
  `ingress.certificate.issuerRef.name` set
- **THEN** a `cert-manager.io/v1` Certificate is rendered with
  `spec.secretName` (`ingress.certificate.secretName`, default
  `<fullname>-tls`), `spec.issuerRef` (name and kind; kind defaults to
  `ClusterIssuer`, never cert-manager's own namespaced-`Issuer` default) and
  `spec.dnsNames` from `ingress.certificate.dnsNames`, falling back to the
  non-empty `ingress.hosts` entries

#### Scenario: Issuer name required
- **WHEN** `ingress.certificate.enabled=true` without
  `ingress.certificate.issuerRef.name`
- **THEN** rendering fails with an error naming the missing value

#### Scenario: Ingress uses the certificate Secret
- **WHEN** the Certificate's `secretName` and an Ingress `tls` entry name the
  same Secret
- **THEN** the Ingress `tls` block references that Secret, so cert-manager's
  issuance and renewal serve the ingress directly
