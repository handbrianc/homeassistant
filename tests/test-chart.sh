#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2181,SC2319,SC1091
# Harness idiom: `[ cmd ]; chk $? "msg"`.
# =============================================================================
# tests/test-chart.sh — chart contract tests (charts/homeassistant)
#
# helm lint/template render locally and NEVER contact a cluster. Without helm
# (set HELM_BIN=/path/to/helm) the render sections SKIP with a notice; the
# helm-free checks — the bash<->chart value contract — always run.
# `--kube-version 1.31.0` is always passed: helm 4 enforces the chart's
# kubeVersion (>=1.25) and lint/template must not probe the local cluster.
# macOS note: portable; helm is the only dependency.
# =============================================================================
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHART="$REPO_ROOT/charts/homeassistant"
OUT="$TESTS_TMP/chart"
mkdir -p "$OUT"

if [ -n "${HELM_BIN:-}" ]; then
  HELM="$HELM_BIN"
else
  HELM="$(command -v helm 2>/dev/null || true)"
fi

if [ -z "$HELM" ]; then
  skip_note "chart render tests (no helm on PATH and no HELM_BIN set)"
elif [ ! -x "$HELM" ]; then
  fail "HELM_BIN='$HELM_BIN' is not executable"
else
  section "helm lint"
  "$HELM" lint "$CHART" --kube-version 1.31.0 >"$OUT/lint.out" 2>&1
  [ $? = "0" ]; chk $? "helm lint passes ($("$HELM" version --short 2>/dev/null || true))"
  chk_regex "$OUT/lint.out" '[0-9]+ chart\(s\)' "lint summary printed"

  section "helm template (default values)"
  "$HELM" template ha "$CHART" --kube-version 1.31.0 >"$OUT/default.yaml" 2>&1
  [ $? = "0" ]; chk $? "default template renders"
  chk_grep "$OUT/default.yaml" "kind: StatefulSet" "StatefulSet rendered"
  chk_grep "$OUT/default.yaml" "kind: Service" "Service rendered"
  chk_grep "$OUT/default.yaml" "kind: PersistentVolumeClaim" "PVC rendered"
  chk_grep "$OUT/default.yaml" "kind: ConfigMap" "bootstrap ConfigMap rendered"
  chk_grep "$OUT/default.yaml" "replicas: 1" "single replica"
  chk_grep "$OUT/default.yaml" \
    'image: "ghcr.io/home-assistant/home-assistant:2026.11.0"' "pinned image tag"
  chk_grep "$OUT/default.yaml" "terminationGracePeriodSeconds: 60" "graceful shutdown budget"
  chk_grep "$OUT/default.yaml" "homeassistant-secrets" "default envFrom secret wired"
  chk_grep "$OUT/default.yaml" 'path: "/"' "unauthenticated probe path"
  chk_nogrep "$OUT/default.yaml" "kind: Ingress" "no Ingress by default"
  chk_nogrep "$OUT/default.yaml" "kind: Certificate" "no Certificate by default"
  chk_nogrep "$OUT/default.yaml" "kind: Secret" "no chart-managed Secret by default"
  chk_nogrep "$OUT/default.yaml" "nodePort:" "no nodePort by default"
  chk_nogrep "$OUT/default.yaml" "loadBalancerIP:" "no loadBalancerIP by default"
  chk_nogrep "$OUT/default.yaml" "ClusterFirstWithHostNet" "no hostNet dnsPolicy by default"

  section "helm template (edge values)"
  _tpl() { # _tpl OUT [SET...] — template with --set extras
    local _o="$1"
    shift
    "$HELM" template ha "$CHART" --kube-version 1.31.0 "$@" >"$_o" 2>&1
  }

  _tpl "$OUT/nodeport.yaml" --set service.type=NodePort --set service.nodePort=30812
  [ $? = "0" ]; chk $? "NodePort values render"
  chk_grep "$OUT/nodeport.yaml" "type: NodePort" "NodePort service type"
  chk_grep "$OUT/nodeport.yaml" "nodePort: 30812" "nodePort rendered"

  _tpl "$OUT/ingress.yaml" --set ingress.enabled=true --set ingress.className=traefik \
    --set ingress.hosts[0].host=ha.example.com
  [ $? = "0" ]; chk $? "Ingress values render"
  chk_grep "$OUT/ingress.yaml" "kind: Ingress" "Ingress rendered"
  chk_grep "$OUT/ingress.yaml" "ha.example.com" "Ingress host"
  chk_grep "$OUT/ingress.yaml" "ingressClassName: traefik" "Ingress class"

  _tpl "$OUT/ingress-catchall.yaml" --set ingress.enabled=true --set ingress.className=traefik \
    --set-json 'ingress.hosts=[{"paths":[{"path":"/","pathType":"Prefix"}]}]'
  [ $? = "0" ]; chk $? "catch-all Ingress values render"
  chk_grep "$OUT/ingress-catchall.yaml" "kind: Ingress" "catch-all Ingress rendered"
  chk_grep "$OUT/ingress-catchall.yaml" "backend:" "catch-all rule serves the release"
  chk_nogrep "$OUT/ingress-catchall.yaml" "host:" "catch-all rule omits the host key"

  _tpl "$OUT/ingress-tls.yaml" --set ingress.enabled=true \
    --set ingress.hosts[0].host=ha.example.com --set ingress.tls[0].secretName=ha-tls \
    --set ingress.tls[0].hosts[0]=ha.example.com
  [ $? = "0" ]; chk $? "TLS values render"
  chk_grep "$OUT/ingress-tls.yaml" "secretName: ha-tls" "TLS secretName rendered"
  chk_grep "$OUT/ingress-tls.yaml" "tls:" "TLS block rendered"

  _tpl "$OUT/certificate.yaml" --set ingress.certificate.enabled=true \
    --set ingress.certificate.issuerRef.name=letsencrypt-prod \
    --set 'ingress.certificate.dnsNames={ha.example.com}'
  [ $? = "0" ]; chk $? "cert-manager Certificate values render"
  chk_grep "$OUT/certificate.yaml" "kind: Certificate" "Certificate rendered"
  chk_grep "$OUT/certificate.yaml" "name: letsencrypt-prod" "issuerRef.name rendered"
  chk_grep "$OUT/certificate.yaml" "kind: ClusterIssuer" "issuerRef.kind rendered"
  chk_grep "$OUT/certificate.yaml" 'secretName: "ha-homeassistant-tls"' \
    "default secretName is <fullname>-tls"
  chk_grep "$OUT/certificate.yaml" '- "ha.example.com"' "explicit dnsNames quoted"

  _tpl "$OUT/certificate-fallback.yaml" --set ingress.certificate.enabled=true \
    --set ingress.certificate.issuerRef.name=letsencrypt-prod \
    --set ingress.hosts[0].host=ha.example.com
  [ $? = "0" ]; chk $? "Certificate dnsNames fallback renders"
  chk_grep "$OUT/certificate-fallback.yaml" '- "ha.example.com"' \
    "dnsNames default to the ingress hosts"
  chk_grep "$OUT/certificate-fallback.yaml" 'secretName: "ha-homeassistant-tls"' \
    "fallback secretName is <fullname>-tls"

  _tpl "$OUT/certificate-wildcard.yaml" --set ingress.certificate.enabled=true \
    --set ingress.certificate.issuerRef.name=letsencrypt-prod \
    --set 'ingress.certificate.dnsNames={*.example.com,example.com}'
  [ $? = "0" ]; chk $? "Wildcard dnsNames values render"
  chk_grep "$OUT/certificate-wildcard.yaml" '- "*.example.com"' "wildcard dnsNames rendered quoted"
  chk_grep "$OUT/certificate-wildcard.yaml" '- "example.com"' "apex dnsNames rendered"
  chk_grep "$OUT/certificate-wildcard.yaml" 'secretName: "ha-homeassistant-tls"' \
    "wildcard secretName is <fullname>-tls"

  _tpl "$OUT/certificate-shared.yaml" --set ingress.enabled=true \
    --set ingress.certificate.enabled=true \
    --set ingress.certificate.issuerRef.name=letsencrypt-prod \
    --set ingress.tls[0].secretName=ha-homeassistant-tls
  [ $? = "0" ]; chk $? "Certificate + Ingress tls values render"
  [ "$(grep -c 'secretName:.*ha-homeassistant-tls' "$OUT/certificate-shared.yaml")" = "2" ]
  chk $? "Certificate and Ingress reference the same Secret (2 refs)"
  chk_grep "$OUT/certificate-shared.yaml" 'secretName: "ha-homeassistant-tls"' \
    "Certificate secretName quoted, matching the Ingress tls reference"

  _tpl "$OUT/cert-noissuer.yaml" --set ingress.certificate.enabled=true
  [ $? != "0" ]; chk $? "empty issuerRef.name fails the render"
  chk_grep "$OUT/cert-noissuer.yaml" "issuerRef.name is required" \
    "required-issuer error surfaced in the render output"

  _tpl "$OUT/cm-proxies.yaml" --set ingress.enabled=true \
    --set 'ingress.trustedProxies={10.42.0.0/16}'
  [ $? = "0" ]; chk $? "trustedProxies values render"
  chk_grep "$OUT/cm-proxies.yaml" "use_x_forwarded_for: true" "X-Forwarded-For trust seeded"
  chk_grep "$OUT/cm-proxies.yaml" "trusted_proxies:" "trusted_proxies list rendered"
  chk_grep "$OUT/cm-proxies.yaml" '- "10.42.0.0/16"' "trusted proxy CIDR quoted"
  chk_nogrep "$OUT/default.yaml" "trusted_proxies" "no trusted_proxies in default render"

  # HTTP config store seed: HA >= 2026.11 keeps HTTP settings in
  # /config/.storage/http (stable/pending trial promotion; the YAML http:
  # block is migrated once, then ignored — an unpromoted trial is reverted
  # and the install answers HTTP 400 behind the ingress forever). The chart
  # seeds the store's stable slot directly; version-gated.
  chk_grep "$OUT/cm-proxies.yaml" "  storage-http: |" \
    "HTTP config store seed rendered with trustedProxies (2026.11.0)"
  awk '/^  storage-http: \|/{f=1;next} f{if ($0 !~ /^    /) exit; print substr($0,5)}' \
    "$OUT/cm-proxies.yaml" >"$OUT/seed.json"
  [ -s "$OUT/seed.json" ]; chk $? "store seed JSON extracted from the render"
  jq -e '.version == 3 and .minor_version == 1 and .key == "http"' \
    "$OUT/seed.json" >/dev/null; chk $? "store seed matches store version 3.1 shape"
  jq -e '.data.stable.use_x_forwarded_for == true and .data.stable.trusted_proxies == ["10.42.0.0/16"]' \
    "$OUT/seed.json" >/dev/null; chk $? "store seed stable slot carries reverse-proxy trust"
  jq -e '.data.pending == null and .data.yaml_migration_done == false' \
    "$OUT/seed.json" >/dev/null; chk $? "store seed stages no pending trial"
  jq -e '.data.stable.server_port == 8123 and .data.stable.ssl_profile == "intermediate_v6" and .data.stable.cors_allowed_origins == ["https://cast.home-assistant.io"]' \
    "$OUT/seed.json" >/dev/null; chk $? "store seed mirrors HA HTTP_STORAGE_SCHEMA defaults"
  chk_grep "$OUT/cm-proxies.yaml" \
    '[ -f /bootstrap-config/storage-http ] && [ ! -f /config/.storage/http ]' \
    "store seed copy runs only when the seed exists and the store is missing"
  chk_grep "$OUT/cm-proxies.yaml" "mkdir -p /config/.storage" \
    "init container creates /config/.storage"
  chk_grep "$OUT/cm-proxies.yaml" "cp /bootstrap-config/storage-http /config/.storage/http" \
    "store seed copied into the HA config volume"
  chk_grep "$OUT/cm-proxies.yaml" '[ ! -f /config/configuration.yaml ]' \
    "configuration.yaml seeding keeps its skip-if-exists guard"
  chk_grep "$OUT/cm-proxies.yaml" "already exists; leaving it untouched" \
    "existing configuration.yaml is never overwritten"

  _tpl "$OUT/seed-old.yaml" --set ingress.enabled=true \
    --set 'ingress.trustedProxies={10.42.0.0/16}' --set image.tag=2026.10.0
  [ $? = "0" ]; chk $? "pre-store HA version renders"
  chk_nogrep "$OUT/seed-old.yaml" "  storage-http: |" \
    "no store seed for HA < 2026.11.0 (its storage loader would reject it)"
  chk_grep "$OUT/seed-old.yaml" "use_x_forwarded_for: true" \
    "YAML http: block remains the seeding mechanism pre-store"

  _tpl "$OUT/seed-latest.yaml" --set ingress.enabled=true \
    --set 'ingress.trustedProxies={10.42.0.0/16}' --set image.tag=latest
  [ $? = "0" ]; chk $? "non-semver image tag renders"
  chk_grep "$OUT/seed-latest.yaml" "  storage-http: |" \
    "non-semver tags are assumed current and seed the store"

  _tpl "$OUT/seed-noproxy.yaml" --set ingress.enabled=true --set ingress.className=traefik
  [ $? = "0" ]; chk $? "ingress without trustedProxies renders"
  chk_nogrep "$OUT/seed-noproxy.yaml" "use_x_forwarded_for" \
    "no http: block without trustedProxies"
  chk_nogrep "$OUT/seed-noproxy.yaml" "  storage-http: |" \
    "no store seed without trustedProxies"

  _tpl "$OUT/hostnet.yaml" --set hostNetwork=true
  [ $? = "0" ]; chk $? "hostNetwork values render"
  chk_grep "$OUT/hostnet.yaml" "hostNetwork: true" "hostNetwork on"
  chk_grep "$OUT/hostnet.yaml" "dnsPolicy: ClusterFirstWithHostNet" "dnsPolicy with hostNetwork"

  _tpl "$OUT/noenvfrom.yaml" --set envFromSecret=
  [ $? = "0" ]; chk $? "empty envFromSecret renders"
  chk_nogrep "$OUT/noenvfrom.yaml" "secretRef" "no envFrom secretRef when disabled"

  _tpl "$OUT/secret.yaml" --set secretEnv.MQTT_PASSWORD=demo-not-real
  [ $? = "0" ]; chk $? "chart-managed secretEnv renders"
  chk_grep "$OUT/secret.yaml" "kind: Secret" "chart-managed Secret rendered"
  chk_grep "$OUT/secret.yaml" "MQTT_PASSWORD" "secret key present"

  _tpl "$OUT/lbip.yaml" --set service.loadBalancerIP=192.168.1.50
  [ $? = "0" ]; chk $? "loadBalancerIP values render"
  chk_grep "$OUT/lbip.yaml" 'loadBalancerIP: "192.168.1.50"' "loadBalancerIP rendered"

  _tpl "$OUT/existing.yaml" --set persistence.existingClaim=ha-existing
  [ $? = "0" ]; chk $? "existingClaim values render"
  chk_nogrep "$OUT/existing.yaml" "kind: PersistentVolumeClaim" \
    "no new PVC when existingClaim set"

  _tpl "$OUT/storageclass.yaml" --set persistence.storageClass=longhorn
  [ $? = "0" ]; chk $? "storageClass values render"
  chk_grep "$OUT/storageclass.yaml" 'storageClassName: "longhorn"' "storageClass rendered"
fi

section "helm-free contract checks (always run)"
# values.yaml image.tag must equal Chart.yaml appVersion (pinned contract).
_tag="$(sed -n 's/^  tag: "\([^"]*\)".*/\1/p' "$CHART/values.yaml")"
_app="$(sed -n 's/^appVersion: "\([^"]*\)".*/\1/p' "$CHART/Chart.yaml")"
[ -n "$_tag" ] && [ "$_tag" = "$_app" ]; chk $? "values image.tag == Chart.yaml appVersion ($_tag)"
grep -q '^version:' "$CHART/Chart.yaml"; chk $? "Chart.yaml declares chart version"
grep -q '^kubeVersion:' "$CHART/Chart.yaml"; chk $? "Chart.yaml declares kubeVersion"
[ -n "$(find "$CHART/templates" -name '*.yaml' 2>/dev/null)" ]; chk $? "chart templates present"

# Keys that scripts render against must exist in values.yaml (shared contract).
for _k in '  tag:' 'timezone:' '  storageClass:' '  size:' '  type:' '  port:' \
          '  nodePort:' '  loadBalancerIP:' '  enabled:' '  className:' 'host:' \
          'trustedProxies:' 'hostNetwork:' 'dnsPolicy:' 'envFromSecret:'; do
  grep -qF -- "$_k" "$CHART/values.yaml"
  chk $? "values.yaml carries contract key ($_k)"
done

finish
