# Design: bootstrap-ingress-tls

## Decision

One env contract increment, applied in the shared installer lane, plus two
small chart changes:

1. **Bootstrap defaults the ingress on, safely.** When `review_ingress_class`
   finds an IngressClass (Traefik preferred, unchanged), the generated `.env`
   now carries `INGRESS_ENABLED=true`, the detected class,
   `INGRESS_TLS_ENABLED=true`, `INGRESS_TLS_SECRET_NAME=<release>-tls` and
   `INGRESS_TRUSTED_PROXIES=10.42.0.0/16` (k3s default pod CIDR). With no
   controller, everything stays off as before. The cert-manager CRD
   (`certificates.cert-manager.io`) is probed only to pick the right hint:
   issuer env var when present, cert/key files otherwise.

2. **Catch-all rule when no hostname is configured.** With `INGRESS_HOST`
   empty (the bootstrap default), `render_values_file` emits a rule entry
   without `host`, and `templates/ingress.yaml` omits the `host` key for
   such entries (`host: ""` would be ugly at best). The user reaches HA via
   any name that resolves to the ingress controller's address (on k3s: the
   node IP through ServiceLB) — a working default without inventing DNS.

3. **TLS via two orthogonal paths.**
   - File path: `INGRESS_TLS_CERT_FILE` + `INGRESS_TLS_KEY_FILE` →
     `create_or_update_tls_secret` applies them as the `kubernetes.io/tls`
     Secret using the same `kubectl create ... --dry-run=client -o yaml |
     kubectl apply -f -` pipeline as the app Secret (no values printed,
     dry-run prints the pipeline without contents). Half-specified or
     unreadable pairs are fatal; both paths missing is only a warning (the
     controller then serves its default self-signed cert).
   - Cert-manager path: `INGRESS_TLS_ISSUER` renders
     `cert-manager.io/cluster-issuer` into the Ingress annotations; no secret
     is created by the scripts.

4. **Trusted-proxy seed.** `INGRESS_TRUSTED_PROXIES` renders
   `ingress.trustedProxies`; `templates/configmap.yaml` appends
   `http.use_x_forwarded_for: true` + `http.trusted_proxies` to the seeded
   configuration when ingress is enabled and the list is non-empty. Without
   this, Home Assistant rejects `X-Forwarded-For` from the proxy and logins
   through the ingress fail with HTTP 400 — bootstrap enabling the ingress
   without it would ship a broken default. The k3s default CIDR is a guess
   and is documented as adjustable (and harmless: it only marks pod IPs
   trusted for header parsing).

## Rationale

- All new behavior lives in the env → values contract and the two existing
  Secret-apply patterns; no new cluster-mutating mechanism.
- `helm upgrade --install`-only flow is unchanged; the Ingress and TLS Secret
  are idempotent objects, so install/update converge.
- Empty `INGRESS_HOST` keeps meaning "no host-specific rule" for the
  installer lane while the chart's own default (`homeassistant.local`)
  is untouched for pure-helm users.

## Alternatives rejected

- Defaulting `INGRESS_HOST` to a synthesized `<ip>.nip.io` name: depends on
  an external DNS wildcard service; catch-all is dependency-free.
- Shipping cert-manager as a dependency: out of scope for a home-lab chart;
  the annotation + hint covers users who run it.
- Leaving TLS off until the user configures it: the user explicitly asked for
  TLS capability as part of the default; on Traefik/nginx a missing TLS
  Secret degrades to the controller's default certificate rather than
  breaking the route, and the installer warns about it.
