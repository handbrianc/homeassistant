# Design: cert-manager-certificate

## Decision

An explicit `cert-manager.io/v1 Certificate` resource in the chart, values-gated,
wired to the existing ingress TLS contract:

1. **Chart template** (`templates/certificate.yaml`, new): rendered when
   `ingress.certificate.enabled`. `spec.secretName` =
   `ingress.certificate.secretName`, default `<fullname>-tls`;
   `spec.issuerRef` = name/kind from values with kind emitted explicitly
   (default `ClusterIssuer` — cert-manager's own `issuerRef.kind` default is a
   namespaced `Issuer`, confirmed via docs, so it must never be omitted);
   `spec.dnsNames` from `ingress.certificate.dnsNames`, falling back to the
   non-empty `ingress.hosts` entries. `issuerRef.name` is `required` so a
   half-configured chart fails loudly at render time.

2. **Shared secret name.** The Ingress `tls` block and the Certificate's
   `secretName` must be the same Secret. The installer lane already renders
   `ingress.tls[0].secretName = <release>-tls` (via `ingress_tls_secret_name`);
   in certificate mode it additionally emits
   `ingress.certificate.secretName` with the same value, keeping one source of
   truth in the lane and one default in the chart. Pure-helm users set both in
   values (documented in `values.yaml`).

3. **No shim/CR duplication.** In certificate mode the lane suppresses the
   `cert-manager.io/cluster-issuer` Ingress annotation it used to render —
   otherwise cert-manager's ingress shim would create a second Certificate for
   the same secret. Annotation path (previous behavior) remains the default
   when the issuer is set without `INGRESS_TLS_CERTIFICATE`.

4. **Installer env contract.** `INGRESS_TLS_CERTIFICATE` (bool, default false;
   strict parse like the other TLS bools) and `INGRESS_TLS_ISSUER_KIND` (empty
   → `ClusterIssuer` at render; kept empty in defaults so the chart default
   stays the single source). `create_or_update_tls_secret` messaging: issuer +
   certificate mode → "Certificate resource will be rendered"; certificate mode
   without issuer → warning that no Certificate is rendered until
   `INGRESS_TLS_ISSUER` is set (consistent with the existing
   warn-and-continue pattern for TLS without a source); cert files set in
   certificate mode → files still applied (explicit user intent) with an
   overwrite warning when an issuer is also configured (cert-manager renewals
   overwrite the Secret).

5. **Bootstrap defaulting.** When the `certificates.cert-manager.io` CRD is
   present (the user's cluster runs cert-manager), the generated `.env` sets
   `INGRESS_TLS_CERTIFICATE=true`; the issuer name is cluster-specific and
   stays empty, so install warns until the user sets `INGRESS_TLS_ISSUER`.
   CRD absent → stays `false` (file path hint unchanged).

6. **dnsNames.** A Certificate needs at least one DNS name. The lane emits
   `ingress.certificate.dnsNames=[INGRESS_HOST]` when the host is set; with a
   catch-all rule (host empty) the Certificate still renders (issuer may be a
   non-ACME issuer) but ACME issuance would need a name — covered by the
   missing-issuer/`INGRESS_HOST` guidance in the values comments and warning
   text.

## Storage class (no change)

`review_storage_class` already reads the
`storageclass.kubernetes.io/is-default-class` annotation and writes
`STORAGE_CLASS` to `.env`; `render_values_file` emits `storageClass` only when
set, and the chart treats empty as "cluster default" — the requested behavior
is the shipped one (suite-asserted: T4 `STORAGE_CLASS="local-path"`).

## Alternatives rejected

- Keep relying on the ingress-shim annotation only: the Certificate is
  invisible to `kubectl get certificate` and its settings can't be tuned from
  the chart; the user explicitly asked for chart-included certificate creation.
- Chart-side `Capabilities.APIVersions.Has` gate on the Certificate: helm
  template cannot see third-party CRDs reliably; the values gate is the
  contract (documented: enabling requires the cert-manager CRDs).
- Emitting `group: cert-manager.io` in issuerRef: unnecessary (cert-manager
  defaults it); only kind/name are meaningful for in-cluster issuers.
