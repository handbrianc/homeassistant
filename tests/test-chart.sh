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
          'hostNetwork:' 'dnsPolicy:' 'envFromSecret:'; do
  grep -qF -- "$_k" "$CHART/values.yaml"
  chk $? "values.yaml carries contract key ($_k)"
done

finish
