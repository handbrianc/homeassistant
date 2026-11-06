#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2181,SC2319,SC1091
# Harness idiom: `[ cmd ]; chk $? "msg"` (assert the immediately preceding
# command) and literal snippets passed to librun — both trip those codes.
# =============================================================================
# tests/test-common.sh — unit tests for scripts/lib/common.sh
#
# Every die() path runs in a subshell (via librun/expect_fail) so the harness
# survives; kubectl/helm-dependent functions run with the committed mocks
# first on PATH — never real tools, never a cluster. macOS note: the suite is
# bash 3.2+ portable; Linux-only assumptions are none here.
# =============================================================================
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# librun_val VALUE SNIPPET — snippet can reference the raw value as $HC_VAL
# (avoids any quoting pitfalls when testing quote-rejection).
librun_val() {
  HC_VAL="$1" bash -c '. "$0/scripts/lib/common.sh"; eval "$1"' "$REPO_ROOT" "$2"
}

section "parse_bool"
[ "$(librun 'parse_bool true')" = "true" ]; chk $? "parse_bool true"
[ "$(librun 'parse_bool TRUE')" = "true" ]; chk $? "parse_bool TRUE"
[ "$(librun 'parse_bool False')" = "false" ]; chk $? "parse_bool False"
librun 'parse_bool maybe' >/dev/null 2>&1
[ $? = "1" ]; chk $? "parse_bool rejects 'maybe' (rc 1)"

section "assert_yaml_safe (rejects each dangerous character)"
expect_fail "rejects double quote" env HC_VAL='a"b' bash -c \
  '. "$0/scripts/lib/common.sh"; assert_yaml_safe V "$HC_VAL"' "$REPO_ROOT"
grep -q 'Unsafe value in \$V' "$TESTS_TMP/expect-fail.out"
chk $? "message names the variable"
for _case in "single quote:a'b" "backslash:a\\b" "backtick:a\`b" "dollar:a\$b"; do
  _name="${_case%%:*}"
  _val="${_case#*:}"
  expect_fail "rejects $_name" env HC_VAL="$_val" bash -c \
    '. "$0/scripts/lib/common.sh"; assert_yaml_safe V "$HC_VAL"' "$REPO_ROOT"
done
expect_fail "rejects newline" env HC_VAL="$(printf 'a\nb')" bash -c \
  '. "$0/scripts/lib/common.sh"; assert_yaml_safe V "$HC_VAL"' "$REPO_ROOT"
librun_val 'plain-value' 'assert_yaml_safe V "$HC_VAL"' >/dev/null 2>&1
[ $? = "0" ]; chk $? "accepts plain values (rc 0)"
librun_val 'with space' 'assert_yaml_safe V "$HC_VAL"' >/dev/null 2>&1
[ $? = "0" ]; chk $? "accepts spaces (rc 0)"

section "assert_int / assert_all_values_safe"
librun 'assert_int PORT 8123' >/dev/null 2>&1
[ $? = "0" ]; chk $? "assert_int accepts integer"
expect_fail "assert_int rejects 8a" env HC_VAL=8a bash -c \
  '. "$0/scripts/lib/common.sh"; assert_int P "$HC_VAL"' "$REPO_ROOT"
grep -q 'must be an integer' "$TESTS_TMP/expect-fail.out"
chk $? "assert_int message"
_ALL_OK='NAMESPACE=ns; RELEASE_NAME=r; SECRET_NAME=r-secrets; CHART_DIR=c;
HELM_TIMEOUT=10m; IMAGE_TAG=2026.11.0; TIMEZONE=UTC; NODE_ARCH=arm64;
STORAGE_CLASS=local-path; STORAGE_SIZE=5Gi; SERVICE_TYPE=LoadBalancer;
SERVICE_PORT=8123; LOADBALANCER_IP=; NODE_PORT=; INGRESS_ENABLED=false;
INGRESS_CLASS=traefik; INGRESS_HOST=ha.example.com; HOST_NETWORK=false;
SECRETS_FILE=s.env; VALUES_EXTRA=; ENV_FROM_SECRET=r-secrets;
assert_all_values_safe'
librun "$_ALL_OK" >/dev/null 2>&1
[ $? = "0" ]; chk $? "assert_all_values_safe accepts a valid set"
librun "${_ALL_OK%; assert_all_values_safe}; LOADBALANCER_IP='1.2.3\"4'; assert_all_values_safe" >/dev/null 2>&1
[ $? = "1" ]; chk $? "assert_all_values_safe rejects unsafe LOADBALANCER_IP"

section "load_env_file"
_envf="$TESTS_TMP/envfile.env"
printf 'FOO=bar\n# a comment\n\nBAZ="sp ace"\n' > "$_envf"
[ "$(librun "load_env_file '$_envf'; printf '%s|%s' \"\$FOO\" \"\$BAZ\"" | tail -n 1)" = "bar|sp ace" ]
chk $? "loads KEY=VALUE, ignores comments, keeps spaces"
[ "$(librun "load_env_file '$_envf'; sh -c 'echo \"\$FOO\"'" | tail -n 1)" = "bar" ]
chk $? "values are exported (set -a)"
librun "load_env_file '$TESTS_TMP/does-not-exist.env'" >/dev/null 2>&1
[ $? = "0" ]; chk $? "missing file warns and continues (rc 0)"

section "apply_defaults"
[ "$(librun 'unset NAMESPACE IMAGE_TAG; apply_defaults; printf "%s|%s" "$NAMESPACE" "$IMAGE_TAG"')" = "homeassistant|2026.11.0" ]
chk $? "unset vars get defaults"
[ "$(librun 'IMAGE_TAG=9.9.9; apply_defaults; printf "%s" "$IMAGE_TAG"')" = "9.9.9" ]
chk $? "preset vars are preserved"

section "resolve_repo_path"
[ "$(librun 'resolve_repo_path charts/x')" = "$REPO_ROOT/charts/x" ]
chk $? "relative resolves against REPO_ROOT"
[ "$(librun 'resolve_repo_path /abs/path')" = "/abs/path" ]
chk $? "absolute passes through"

section "cleanup files / trap"
_cf="$TESTS_TMP/cleanupme"
: > "$_cf"
librun "register_cleanup_file '$_cf'; cleanup_files" >/dev/null 2>&1
[ ! -f "$_cf" ]; chk $? "cleanup_files removes registered file"
: > "$_cf"
librun "setup_cleanup_trap; register_cleanup_file '$_cf'; exit 0" >/dev/null 2>&1
[ ! -f "$_cf" ]; chk $? "EXIT trap removes registered file"

section "helm_release_args / print_helm_cmd"
# Rollback flag is version-aware. PATH is pinned and HC_HELM_MAJOR cleared so
# "no detectable helm" is deterministic even on dev machines with helm; the
# preview default is the helm 4 flag name (what prereqs installs today).
_hra='PATH="/usr/bin:/bin"; HC_HELM_MAJOR=; NAMESPACE=homeassistant; RELEASE_NAME=homeassistant; CHART_DIR=/x/chart;
HELM_TIMEOUT=10m; VALUES_EXTRA=; ENV_FROM_SECRET=homeassistant-secrets;
IMAGE_TAG=2026.11.0; helm_release_args /tmp/gen; print_helm_cmd'
_hra_out="$(librun "$_hra")"
printf '%s' "$_hra_out" | grep -q '^helm upgrade --install homeassistant /x/chart'
chk $? "args start with upgrade --install <release> <chart>"
printf '%s' "$_hra_out" | grep -qF -- '--namespace homeassistant'
chk $? "args carry --namespace"
printf '%s' "$_hra_out" | grep -qF -- '--create-namespace'
chk $? "args carry --create-namespace"
printf '%s' "$_hra_out" | grep -qF -- '--rollback-on-failure'
chk $? "args carry --rollback-on-failure (no helm: preview default)"
! printf '%s' "$_hra_out" | grep -qF -- '--atomic'
chk $? "args never carry deprecated --atomic when helm is absent"
printf '%s' "$_hra_out" | grep -qF -- '--timeout 10m'
chk $? "args carry --timeout"
printf '%s' "$_hra_out" | grep -qF -- '-f /tmp/gen'
chk $? "args carry the generated values file"
printf '%s' "$_hra_out" | grep -qF -- 'envFromSecret=homeassistant-secrets'
chk $? "args carry envFromSecret"
printf '%s' "$_hra_out" | grep -qF -- 'image.tag=2026.11.0'
chk $? "args carry image.tag"
[ "$(librun "NAMESPACE=n; RELEASE_NAME=r; CHART_DIR=/c; HELM_TIMEOUT=10m; VALUES_EXTRA=; ENV_FROM_SECRET=; IMAGE_TAG=1; helm_release_args /g /extra; print_helm_cmd" | grep -cF -- '-f /extra')" = "1" ]
chk $? "extra values file appended as second -f"
_hpc="$(librun "RELEASE_NAME=r; CHART_DIR=/c; NAMESPACE=n; HELM_TIMEOUT=10m; VALUES_EXTRA=; ENV_FROM_SECRET=; IMAGE_TAG=1; helm_release_args /g; print_helm_cmd")"
printf '%s' "$_hpc" | grep -q '^helm upgrade --install r /c'
chk $? "print_helm_cmd renders the full command line"

# Version-aware rollback flag: detected v3 stub → --atomic, v4 stub →
# --rollback-on-failure; require_helm's cache short-circuits the live parse.
_hra_ver='HC_HELM_MAJOR=; NAMESPACE=n; RELEASE_NAME=r; CHART_DIR=/c;
HELM_TIMEOUT=10m; VALUES_EXTRA=; ENV_FROM_SECRET=; IMAGE_TAG=1;
helm_release_args /g; print_helm_cmd'
_hra_v3="$(HC_STUB_HELM_VERSION=v3.16.2 PATH="$STUBS:$BASE_PATH" librun "$_hra_ver")"
printf '%s' "$_hra_v3" | grep -qF -- '--atomic'
chk $? "helm 3 args carry --atomic"
! printf '%s' "$_hra_v3" | grep -qF -- '--rollback-on-failure'
chk $? "helm 3 args never carry --rollback-on-failure"
_hra_v4="$(HC_STUB_HELM_VERSION=v4.0.0 PATH="$STUBS:$BASE_PATH" librun "$_hra_ver")"
printf '%s' "$_hra_v4" | grep -qF -- '--rollback-on-failure'
chk $? "helm 4 args carry --rollback-on-failure"
! printf '%s' "$_hra_v4" | grep -qF -- '--atomic'
chk $? "helm 4 args never carry deprecated --atomic"
_hra_c="$(HC_HELM_MAJOR=3 librun "NAMESPACE=n; RELEASE_NAME=r; CHART_DIR=/c; HELM_TIMEOUT=10m; VALUES_EXTRA=; ENV_FROM_SECRET=; IMAGE_TAG=1; helm_release_args /g; print_helm_cmd")"
printf '%s' "$_hra_c" | grep -qF -- '--atomic'
chk $? "cached HC_HELM_MAJOR=3 forces --atomic without live helm"

section "create_or_update_secret"
secf="$TESTS_TMP/sec.env"
printf 'MQTT_PASSWORD=s3cr3tvalue\nHA_TOKEN=t0k3n\n' > "$secf"
_cus="$(HC_STUB_LOG="$TESTS_TMP/cus.log" librun_stub "SECRETS_FILE='$secf'; NAMESPACE=ns; SECRET_NAME=ns-secrets; create_or_update_secret; printf 'EFS=[%s]' \"\$ENV_FROM_SECRET\"" 2>&1)"
printf '%s' "$_cus" | grep -q 'EFS=\[ns-secrets\]'
chk $? "applies Secret and sets ENV_FROM_SECRET"
printf '%s' "$_cus" | grep -q 'Applying Kubernetes Secret'
chk $? "apply is logged"
! printf '%s' "$_cus" | grep -q 's3cr3tvalue'
chk $? "secret VALUE never printed"
! grep -q 's3cr3tvalue' "$TESTS_TMP/cus.log"
chk $? "secret VALUE never reaches the (mock) tool log"
_cus2="$(librun_stub "SECRETS_FILE='$TESTS_TMP/none.env'; NAMESPACE=ns; SECRET_NAME=ns-secrets; create_or_update_secret; printf 'EFS=[%s]' \"\$ENV_FROM_SECRET\"" 2>&1)"
printf '%s' "$_cus2" | grep -q 'EFS=\[\]'
chk $? "missing secrets file -> envFromSecret empty"
printf '%s' "$_cus2" | grep -q 'Secrets file not found'
chk $? "missing secrets file warns"
printf '# only\n# comments\n' > "$TESTS_TMP/commentsonly.env"
_cus3="$(librun_stub "SECRETS_FILE='$TESTS_TMP/commentsonly.env'; NAMESPACE=ns; SECRET_NAME=ns-secrets; create_or_update_secret; printf 'EFS=[%s]' \"\$ENV_FROM_SECRET\"" 2>&1)"
printf '%s' "$_cus3" | grep -q 'EFS=\[\]'
chk $? "comments-only secrets file -> envFromSecret empty"

section "render_values_file"
vals="$TESTS_TMP/vals.yaml"
printf 'MQTT_PASSWORD=render-secret\n' > "$TESTS_TMP/vals-secret.env"
_rvf="SECRETS_FILE='$TESTS_TMP/vals-secret.env'; NAMESPACE=ns; SECRET_NAME=ns-secrets; create_or_update_secret;
IMAGE_TAG=2026.10.0; TIMEZONE=Europe/Berlin; NODE_ARCH=arm64;
STORAGE_CLASS=longhorn; STORAGE_SIZE=8Gi; SERVICE_TYPE=LoadBalancer;
SERVICE_PORT=8123; LOADBALANCER_IP=1.2.3.4; NODE_PORT=;
INGRESS_ENABLED=true; INGRESS_CLASS=traefik; INGRESS_HOST=ha.example.com;
HOST_NETWORK=true; render_values_file '$vals'"
librun_stub "$_rvf" >/dev/null 2>&1
[ $? = "0" ]; chk $? "full render succeeds"
chk_grep "$vals" 'tag: "2026.10.0"' "render: image tag"
chk_grep "$vals" 'timezone: "Europe/Berlin"' "render: timezone"
chk_grep "$vals" 'storageClass: "longhorn"' "render: storage class"
chk_grep "$vals" 'size: "8Gi"' "render: storage size"
chk_grep "$vals" 'type: "LoadBalancer"' "render: service type"
chk_grep "$vals" 'loadBalancerIP: "1.2.3.4"' "render: loadBalancerIP"
chk_grep "$vals" 'enabled: true' "render: ingress enabled"
chk_grep "$vals" 'className: "traefik"' "render: ingress class"
chk_grep "$vals" 'host: "ha.example.com"' "render: ingress host"
chk_grep "$vals" 'pathType: Prefix' "render: ingress pathType"
chk_grep "$vals" 'hostNetwork: true' "render: hostNetwork"
chk_grep "$vals" 'dnsPolicy: "ClusterFirstWithHostNet"' "render: dnsPolicy with hostNetwork"
chk_grep "$vals" 'kubernetes.io/arch: "arm64"' "render: nodeSelector arch"
chk_grep "$vals" 'envFromSecret: "ns-secrets"' "render: envFromSecret"
vals2="$TESTS_TMP/vals-min.yaml"
librun_stub "SECRETS_FILE=/x; NAMESPACE=ns; SECRET_NAME=ns-secrets; create_or_update_secret; apply_defaults; ENV_FROM_SECRET=''; render_values_file '$vals2'" >/dev/null 2>&1
chk_grep "$vals2" 'enabled: false' "minimal render: ingress disabled"
chk_grep "$vals2" 'hostNetwork: false' "minimal render: hostNetwork off"
chk_grep "$vals2" 'envFromSecret: ""' "minimal render: envFromSecret empty"
chk_nogrep "$vals2" 'nodeSelector' "minimal render: no nodeSelector"
expect_fail "render rejects bad INGRESS_ENABLED" env HC_VAL=maybe bash -c \
  '. "$0/scripts/lib/common.sh"; SECRETS_FILE=/x; NAMESPACE=ns; SECRET_NAME=ns-secrets; create_or_update_secret >/dev/null 2>&1; INGRESS_ENABLED="$HC_VAL"; render_values_file /dev/null' "$REPO_ROOT"
grep -q "INGRESS_ENABLED must be 'true' or 'false'" "$TESTS_TMP/expect-fail.out"
chk $? "render message names the variable"

section "require_helm"
PATH="$STUBS:$BASE_PATH" librun 'require_helm' >"$TESTS_TMP/rh.out" 2>&1
[ $? = "0" ]; chk $? "helm v3 accepted"
chk_grep "$TESTS_TMP/rh.out" "helm version: v3.22.1" "v3 version logged"
HC_STUB_HELM_VERSION=v4.0.0 PATH="$STUBS:$BASE_PATH" librun 'require_helm' >"$TESTS_TMP/rh4.out" 2>&1
[ $? = "0" ]; chk $? "helm v4 accepted"
chk_grep "$TESTS_TMP/rh4.out" "helm version: v4.0.0" "v4 version logged"
HC_STUB_HELM_VERSION=v2.16.6 PATH="$STUBS:$BASE_PATH" librun 'require_helm' >/dev/null 2>&1
[ $? = "1" ]; chk $? "helm v2 rejected"
HC_STUB_HELM_VERSION=banana PATH="$STUBS:$BASE_PATH" librun 'require_helm' >/dev/null 2>&1
[ $? = "1" ]; chk $? "unparseable helm version rejected"
mkdir -p "$TESTS_TMP/emptybin"
PATH="$TESTS_TMP/emptybin:$BASE_PATH" librun 'require_helm' >/dev/null 2>&1
[ $? = "1" ]; chk $? "helm absent rejected"

section "require_cmds / require_cluster_reachable / wait_for_rollout"
expect_fail "require_cmds reports missing kubectl with hint" env PATH="$TESTS_TMP/emptybin:$BASE_PATH" bash -c \
  '. "$0/scripts/lib/common.sh"; require_cmds kubectl' "$REPO_ROOT"
grep -q 'install-prereqs' "$TESTS_TMP/expect-fail.out"
chk $? "missing-tool hint points at install-prereqs.sh"
PATH="$TESTS_TMP/emptybin:$BASE_PATH" HC_DRY_RUN=1 librun 'require_cmds helm kubectl' >/dev/null 2>&1
[ $? = "0" ]; chk $? "require_cmds skipped in dry-run"
PATH="$STUBS:$BASE_PATH" librun 'require_cluster_reachable' >"$TESTS_TMP/rcr.out" 2>&1
[ $? = "0" ]; chk $? "cluster reachable via mock"
chk_grep "$TESTS_TMP/rcr.out" "Cluster reachable." "reachability logged"
HC_STUB_NODES_FAIL=1 PATH="$STUBS:$BASE_PATH" librun 'require_cluster_reachable' >/dev/null 2>&1
[ $? = "1" ]; chk $? "unreachable cluster -> rc 1"
HC_STUB_LOG="$TESTS_TMP/wfr.log" PATH="$STUBS:$BASE_PATH" librun 'NAMESPACE=homeassistant; RELEASE_NAME=homeassistant; HELM_TIMEOUT=10m; wait_for_rollout' >/dev/null 2>&1
[ $? = "0" ]; chk $? "rollout wait succeeds via mock"
chk_grep "$TESTS_TMP/wfr.log" "rollout status" "rollout status called (mock log)"
HC_STUB_NO_STS=1 PATH="$STUBS:$BASE_PATH" librun 'NAMESPACE=homeassistant; RELEASE_NAME=homeassistant; HELM_TIMEOUT=10m; wait_for_rollout' >"$TESTS_TMP/wfr2.out" 2>&1
[ $? = "0" ]; chk $? "missing StatefulSet -> warn and skip (rc 0)"
chk_grep "$TESTS_TMP/wfr2.out" "skipping rollout wait" "skip is announced"

finish
