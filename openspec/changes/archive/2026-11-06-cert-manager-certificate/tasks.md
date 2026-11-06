# Tasks: cert-manager-certificate

## 1. Chart

- [x] 1.1 `templates/certificate.yaml`: `cert-manager.io/v1` Certificate (secretName default `<fullname>-tls`, explicit `issuerRef.kind`, `dnsNames` fallback from ingress hosts, `required` issuer name)
- [x] 1.2 `values.yaml`: `ingress.certificate` contract block (enabled / issuerRef.name / issuerRef.kind / dnsNames / secretName)
- [x] 1.3 `tests/test-chart.sh`: rendered case, dnsNames fallback, shared secret with the Ingress `tls` entry, default absence, issuer-name-required failure

## 2. Installer lane

- [x] 2.1 `common.sh`: `INGRESS_TLS_CERTIFICATE` / `INGRESS_TLS_ISSUER_KIND` contract (defaults, YAML-safety, strict bool parse); `render_values_file` emits the certificate block and suppresses the cluster-issuer annotation in certificate mode; `create_or_update_tls_secret` certificate-mode messaging
- [x] 2.2 `bootstrap-cluster.sh`: CRD present → `INGRESS_TLS_CERTIFICATE=true`; `.env` block + report line
- [x] 2.3 `install.sh`/`update.sh`: config line shows certificate mode
- [x] 2.4 `.env.example` + README: document the new variables

## 3. Tests

- [x] 3.1 `test-common.sh`: render with/without issuer, annotation suppression, bad bool rejected
- [x] 3.2 `test-install.sh`: dry-run asserts (certificate values rendered, no annotation, config line)
- [x] 3.3 `test-bootstrap.sh`: T1 certificate=true (CRD present), T4c certificate=false (no CRD)

## 4. Verification & close-out

- [x] 4.1 Full suite green (v3 + v4 chart runs); storage-class bootstrap behavior re-verified (already implemented, no change expected)
- [x] 4.2 `openspec validate --all`; change archived; committed
