# Tasks: clusterip-certmanager-tls

## 1. Installer lane

- [x] 1.1 `common.sh`: remove `INGRESS_TLS_CERT_FILE`/`INGRESS_TLS_KEY_FILE`/`INGRESS_TLS_CERTIFICATE` from the contract (defaults, asserts, header comment); add `INGRESS_TLS_DNS_NAMES`; delete `create_or_update_tls_secret`; `render_values_file` enforces ClusterIP-with-ingress, issuer-required TLS, always-on certificate block, DNS-names override
- [x] 1.2 `install.sh`/`update.sh`: drop the TLS-secret call; config line loses `cert=`
- [x] 1.3 `bootstrap-cluster.sh`: ingress detection sets `SERVICE_TYPE=ClusterIP` (+ clears `NODE_PORT`); CRD probe only reports/warns; `.env` block, asserts, report line updated

## 2. Docs & chart

- [x] 2.1 `.env.example`: TLS block rewritten (issuer required, DNS names, no files/toggle); ClusterIP note on the exposure block
- [x] 2.2 README: ingress/TLS bullets rewritten (no self-signed references); Service table row + troubleshooting consistent
- [x] 2.3 chart `values.yaml` comments (wildcard dnsNames, ClusterIP note); `tests/test-chart.sh` wildcard dnsNames case

## 3. Tests

- [x] 3.1 `test-common.sh`: render asserts (certificate always, no annotation, DNS_NAMES wildcard/coerce, ClusterIP enforcement dies, issuer-required dies); `create_or_update_tls_secret` section replaced
- [x] 3.2 `test-install.sh`/`test-update.sh`: dry-run asserts updated (no TLS-secret pipeline, ClusterIP config); ingress e2e updated
- [x] 3.3 `test-bootstrap.sh`: T1 (ClusterIP service, DNS_NAMES var, no file/toggle vars), T4 (ingress overrides NodePort fallback), T4b (NodePort fallback without ingress), T4c (cert-manager warning), T9 issuer append

## 4. Verification & close-out

- [x] 4.1 Full suite green (chart suite under helm v3 + v4)
- [x] 4.2 `openspec validate --all`; change archived; committed
