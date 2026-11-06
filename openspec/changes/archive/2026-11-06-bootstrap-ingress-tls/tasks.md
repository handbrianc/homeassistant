# Tasks: bootstrap-ingress-tls

## 1. Chart

- [x] 1.1 `templates/ingress.yaml`: omit the `host` key for hostless rule entries
- [x] 1.2 `templates/configmap.yaml`: append `http.trusted_proxies` seed when ingress enabled + `ingress.trustedProxies` set
- [x] 1.3 `values.yaml`: `ingress.trustedProxies` contract key + hostless note
- [x] 1.4 `tests/test-chart.sh`: hostless rule, TLS block, trusted-proxy seed (and absence) renders

## 2. Installer lane

- [x] 2.1 `common.sh`: defaults + YAML-safety for the 6 new env vars; `render_values_file` renders annotations/catch-all hosts/tls/trustedProxies; `create_or_update_tls_secret`
- [x] 2.2 `install.sh` + `update.sh`: apply TLS Secret, extended config line, install ingress URL hint
- [x] 2.3 `bootstrap-cluster.sh`: ingress defaults on with TLS + trusted proxies, cert-manager detection, `.env` block + report
- [x] 2.4 `.env.example` + README: document the new variables and bootstrap defaults

## 3. Tests

- [x] 3.1 `tests/stubs/kubectl`: `certificates.cert-manager.io` case with a disable knob
- [x] 3.2 `test-common.sh`: rendering + TLS secret function (dry-run/warn/die paths)
- [x] 3.3 `test-install.sh`: dry-run regex, e2e mock log proves TLS secret apply, ingress URL
- [x] 3.4 `test-bootstrap.sh`: T1 defaults (enabled + TLS + proxies), no-controller run stays disabled, cert-manager hint

## 4. Verification & close-out

- [x] 4.1 Full suite green (v3 + v4 chart runs); bootstrap→install dry-run chain intact
- [x] 4.2 `openspec validate --all`; change archived; committed
