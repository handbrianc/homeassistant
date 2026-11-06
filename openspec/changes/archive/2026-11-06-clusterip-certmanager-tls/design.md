# Design: clusterip-certmanager-tls

## Decision

### 1. ClusterIP is enforced at render time, not derived twice

`render_values_file` is the single choke point both installers use (dry-run
renders it too), so the service contract lives there:

```bash
if [ "$_rvf_ingress_enabled" = "true" ]; then
  if [ -n "$SERVICE_TYPE" ] && [ "$SERVICE_TYPE" != "ClusterIP" ]; then
    die "INGRESS_ENABLED=true requires SERVICE_TYPE=ClusterIP — ..."
  fi
  _rvf_service_type="ClusterIP"   # never the chart's LoadBalancer default
else
  _rvf_service_type="$SERVICE_TYPE"
fi
```

Empty `SERVICE_TYPE` with the ingress on coerces to ClusterIP rather than
dying: the chart's own default is `LoadBalancer`, so emitting nothing would
re-introduce the double exposure silently. An explicit non-ClusterIP type dies
with a message that names both knobs (set ClusterIP, or turn the ingress off).

Bootstrap mirrors the contract: `review_lb_capability` keeps its
LoadBalancer/NodePort derivation, but `review_ingress_class` (which runs after
it) sets `SERVICE_TYPE=ClusterIP`, clears `NODE_PORT`, and logs the override.
The NodePort fallback therefore only fires when no ingress controller exists.
The generated `.env` still carries `SERVICE_TYPE=` so `install.sh`'s render
re-verifies it — a hand-edited `.env` with ingress+LoadBalancer dies loudly.

The installer's built-in default for `SERVICE_TYPE` becomes empty (was
`LoadBalancer`) so an explicitly configured value stays distinguishable from
no value: without `.env` the chart's LoadBalancer default still applies
(ingress off), while an explicit `.env SERVICE_TYPE=LoadBalancer` with the
ingress on dies instead of being silently coerced. `.env.example` keeps
documenting `LoadBalancer` for the no-ingress path.

### 2. cert-manager is the only TLS mechanism

With cert-manager assumed present:

- `INGRESS_TLS_CERT_FILE` / `INGRESS_TLS_KEY_FILE` and the whole
  `create_or_update_tls_secret` function are removed — a user-applied TLS
  Secret would be overwritten by cert-manager renewals, so keeping the path
  was a footgun, not a feature.
- `INGRESS_TLS_CERTIFICATE` is removed: there is nothing left to toggle
  between. The rendered values ALWAYS emit `ingress.certificate` when TLS is
  on, and the `cert-manager.io/cluster-issuer` annotation is never rendered
  (it would make cert-manager create a second Certificate via the ingress
  shim).
- `INGRESS_TLS_ENABLED=true` with an empty `INGRESS_TLS_ISSUER` dies in
  `render_values_file` naming the variable. The chart's `required` on
  `issuerRef.name` fails the helm render anyway, so the early die only makes
  the message useful. This replaces the old "warn and continue with a
  self-signed certificate" path — no script references a self-signed
  certificate anymore.
- Kept: `INGRESS_TLS_ENABLED` (the opt-out), `INGRESS_TLS_SECRET_NAME`
  (naming control), `INGRESS_TLS_ISSUER`, `INGRESS_TLS_ISSUER_KIND`,
  `INGRESS_TRUSTED_PROXIES`.
- Bootstrap still probes the CRD, but only to report (detected) or warn
  (absent) — no var to set.

### 3. Wildcards via an explicit DNS-names list

One new variable, `INGRESS_TLS_DNS_NAMES` (comma-separated, YAML-safe-checked
like the rest):

- set → rendered verbatim as the Certificate's `dnsNames`
  (`"*.example.com,example.com"` → two entries, quoted so `*` stays legal
  YAML);
- empty → `[INGRESS_HOST]` when set (previous behavior), omitted otherwise.

A list beats a boolean wildcard toggle: it also covers apex+wildcard combos
and multi-domain certificates with no second variable. The Ingress rule itself
keeps matching on `INGRESS_HOST` (a wildcard cert legitimately serves
host-specific rules). The chart needs no template change — `dnsNames` is
already a plain list; only its values comment gains a wildcard note.

### 4. Env-var review outcome

Removed: `INGRESS_TLS_CERT_FILE`, `INGRESS_TLS_KEY_FILE`,
`INGRESS_TLS_CERTIFICATE`. Added: `INGRESS_TLS_DNS_NAMES`. Everything else in
`.env.example` survives review: the exposure vars (`SERVICE_TYPE`,
`SERVICE_PORT`, `LOADBALANCER_IP`, `NODE_PORT`) all still apply when the
ingress is off (ClusterIP+port-forward, LB, NodePort paths remain); the
ingress/TLS vars above stay for the reasons listed. `--purge-data`-style
uninstall switches are deliberately not part of the contract (prior change).

## Alternatives rejected

- Die on empty `SERVICE_TYPE` with the ingress on: punishes the common
  "just let it render" case for a value the chart would silently default to
  LoadBalancer; coercion + doc note is the safer surprise.
- Keep the file-based TLS Secret as an escape hatch: contradicts
  "cert-manager always available"; two writers for one Secret is the exact
  bug class this removes.
- `INGRESS_TLS_WILDCARD=true` boolean: cannot express apex+wildcard or
  multi-domain without more variables; the DNS-names list is one variable
  with full expressiveness.
- Enforce ClusterIP in the chart (reject non-ClusterIP when ingress enabled):
  the chart serves pure-helm users too, where ingress+LB can be legitimate;
  enforcement belongs to the opinionated installer lane.
