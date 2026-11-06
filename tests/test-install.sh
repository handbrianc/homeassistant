#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2181,SC2319,SC1091
# Harness idiom: `[ cmd ]; chk $? "msg"` and literal librun snippets — both
# intentionally trip those codes.
# =============================================================================
# tests/test-install.sh — tests for scripts/install.sh
#
# Layers (cluster safety):
#   A  help/flag errors            — no tools, no cluster
#   B  --dry-run                   — the REAL script, zero cluster access,
#                                    zero toolchain (PATH has no helm/kubectl)
#   C  mock e2e                    — real mode with committed mocks first on
#                                    PATH inside env -i; a real cluster can
#                                    never be contacted
# macOS note: portable assertions only; audited (suite runs on Linux here).
# =============================================================================
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

section "A: help & flag errors (no tools)"
env -i PATH="$BASE_PATH" bash "$REPO_ROOT/scripts/install.sh" --help >"$TESTS_TMP/help.out" 2>&1
[ $? = "0" ]; chk $? "--help exits 0"
chk_grep "$TESTS_TMP/help.out" "Usage: scripts/install.sh" "--help shows usage"
expect_fail "unknown flag rejected" env -i PATH="$BASE_PATH" bash \
  "$REPO_ROOT/scripts/install.sh" --bogus
chk_grep "$TESTS_TMP/expect-fail.out" "Unknown argument" "unknown-flag message"

section "B: dry-run — real script, no cluster, no toolchain"
R="$TESTS_TMP/repo"
fresh_repo "$R"
mkdir -p "$TESTS_TMP/home"
_dr() { # _dr ARGS... — dry-run against the repo copy; output file reused
  env -i PATH="$BASE_PATH" HOME="$TESTS_TMP/home" bash "$R/scripts/install.sh" "$@" \
    >"$TESTS_TMP/dry.out" 2>&1
}
_dr --dry-run
[ $? = "0" ]; chk $? "--dry-run succeeds with NO helm/kubectl on PATH"
chk_grep "$TESTS_TMP/dry.out" "DRY-RUN" "dry-run announced"
chk_grep "$TESTS_TMP/dry.out" "BEGIN generated values" "generated values printed"
chk_grep "$TESTS_TMP/dry.out" 'tag: "2026.11.0"' "chart-default image tag rendered"
chk_grep "$TESTS_TMP/dry.out" 'envFromSecret: ""' "no secrets -> empty envFromSecret"
chk_grep "$TESTS_TMP/dry.out" "Secrets file not found" "missing secrets warned"
chk_regex "$TESTS_TMP/dry.out" 'upgrade --install homeassistant .* --create-namespace --rollback-on-failure' "helm command carries create-namespace + rollback-on-failure (preview default)"
chk_grep "$TESTS_TMP/dry.out" "Dry-run complete" "dry-run completes"
chk_grep "$TESTS_TMP/dry.out" "skipping the full manifest render" "no-helm dry-run notes the skipped render"
env -i PATH="$BASE_PATH" DRY_RUN=1 HOME="$TESTS_TMP/home" bash "$R/scripts/install.sh" >"$TESTS_TMP/dry2.out" 2>&1
[ $? = "0" ]; chk $? "DRY_RUN=1 environment also drives dry-run"
chk_grep "$TESTS_TMP/dry2.out" "DRY-RUN" "DRY_RUN=1 announced"
expect_fail "invalid DRY_RUN value rejected" env -i PATH="$BASE_PATH" DRY_RUN=bogus \
  HOME="$TESTS_TMP/home" bash "$R/scripts/install.sh"
chk_grep "$TESTS_TMP/expect-fail.out" "DRY_RUN must be" "DRY_RUN validation message"
env -i PATH="$BASE_PATH" HOME="$TESTS_TMP/home" bash "$R/scripts/install.sh" --dry-run \
  --namespace alt --release other >"$TESTS_TMP/dry3.out" 2>&1
[ $? = "0" ]; chk $? "flag overrides accepted"
chk_grep "$TESTS_TMP/dry3.out" "NAMESPACE=alt" "namespace override in config"
chk_regex "$TESTS_TMP/dry3.out" 'upgrade --install other ' "release override in helm command"
printf 'terminationGracePeriodSeconds: 90\n' > "$TESTS_TMP/extra.yaml"
env -i PATH="$BASE_PATH" HOME="$TESTS_TMP/home" bash "$R/scripts/install.sh" --dry-run \
  --values "$TESTS_TMP/extra.yaml" >"$TESTS_TMP/dry4.out" 2>&1
[ $? = "0" ]; chk $? "--values accepted"
chk_grep "$TESTS_TMP/dry4.out" "$TESTS_TMP/extra.yaml" "extra values file in helm command"
expect_fail "--values nonexistent" env -i PATH="$BASE_PATH" HOME="$TESTS_TMP/home" \
  bash "$R/scripts/install.sh" --dry-run --values "$TESTS_TMP/nope.yaml"
chk_grep "$TESTS_TMP/expect-fail.out" "VALUES_EXTRA file not found" "missing extra values message"

# secrets present: the Secret apply is previewed, values never printed
R2="$TESTS_TMP/repo2"
fresh_repo "$R2"
secf="$TESTS_TMP/sec2.env"
printf 'MQTT_PASSWORD=s3cr3tvalue\n' > "$secf"
printf 'SECRETS_FILE=%s\n' "$secf" > "$R2/.env"
env -i PATH="$BASE_PATH" HOME="$TESTS_TMP/home" bash "$R2/scripts/install.sh" --dry-run \
  >"$TESTS_TMP/dry5.out" 2>&1
[ $? = "0" ]; chk $? "dry-run with secrets file succeeds"
chk_grep "$TESTS_TMP/dry5.out" '[dry-run] kubectl create secret generic' "secret apply previewed"
chk_grep "$TESTS_TMP/dry5.out" 'envFromSecret: "homeassistant-secrets"' "envFromSecret wired"
chk_nogrep "$TESTS_TMP/dry5.out" "s3cr3tvalue" "secret VALUE never printed (dry-run)"

# ingress + TLS dry-run: catch-all rule, tls block, TLS secret previewed
R3="$TESTS_TMP/repo3"
fresh_repo "$R3"
tlscert="$TESTS_TMP/e2e.pem"; tlskey="$TESTS_TMP/e2e.key"
printf 'CERTDATA\n' > "$tlscert"; printf 'KEYDATA\n' > "$tlskey"
{
  printf 'SECRETS_FILE=%s\n' "$secf"
  printf 'INGRESS_ENABLED=true\n'
  printf 'INGRESS_CLASS=traefik\n'
  printf 'INGRESS_TLS_ENABLED=true\n'
  printf 'INGRESS_TLS_CERT_FILE=%s\n' "$tlscert"
  printf 'INGRESS_TLS_KEY_FILE=%s\n' "$tlskey"
  printf 'INGRESS_TRUSTED_PROXIES=10.42.0.0/16\n'
} > "$R3/.env"
env -i PATH="$BASE_PATH" HOME="$TESTS_TMP/home" bash "$R3/scripts/install.sh" --dry-run \
  >"$TESTS_TMP/dry6.out" 2>&1
[ $? = "0" ]; chk $? "dry-run with ingress+TLS succeeds (no host: catch-all)"
chk_grep "$TESTS_TMP/dry6.out" '[dry-run] kubectl create secret tls "homeassistant-tls"' "TLS secret apply previewed"
chk_nogrep "$TESTS_TMP/dry6.out" "CERTDATA" "TLS file contents never printed (dry-run)"
chk_grep "$TESTS_TMP/dry6.out" 'className: "traefik"' "ingress class rendered"
chk_regex "$TESTS_TMP/dry6.out" '^    -$' "catch-all rule rendered (no host key)"
chk_grep "$TESTS_TMP/dry6.out" 'secretName: "homeassistant-tls"' "tls secretName rendered"
chk_grep "$TESTS_TMP/dry6.out" '- "10.42.0.0/16"' "trusted proxies rendered"
chk_grep "$TESTS_TMP/dry6.out" 'host=<catch-all>' "config line shows catch-all host"

# with the mock toolchain, dry-run also renders the full manifests
env -i PATH="$STUBS:$BASE_PATH" HOME="$TESTS_TMP/home" HC_STUB_LOG="$TESTS_TMP/dry7.log" \
  bash "$R/scripts/install.sh" --dry-run >"$TESTS_TMP/dry7.out" 2>&1
[ $? = "0" ]; chk $? "dry-run with mock helm renders manifests"
chk_grep "$TESTS_TMP/dry7.out" "----- BEGIN rendered manifests -----" "manifests previewed in dry-run"
chk_grep "$TESTS_TMP/dry7.log" "helm template homeassistant" "mock log: helm template served (dry-run)"

# unsafe values and bad chart path abort before anything happens
printf "STORAGE_CLASS='a\"b'\n" > "$R2/.env"
expect_fail "unsafe value aborts even in dry-run" env -i PATH="$BASE_PATH" \
  HOME="$TESTS_TMP/home" bash "$R2/scripts/install.sh" --dry-run
chk_grep "$TESTS_TMP/expect-fail.out" 'Unsafe value in $STORAGE_CLASS' "unsafe value names the variable"
printf 'CHART_DIR=does-not-exist\n' > "$R2/.env"
expect_fail "missing chart directory" env -i PATH="$BASE_PATH" HOME="$TESTS_TMP/home" \
  bash "$R2/scripts/install.sh" --dry-run
chk_grep "$TESTS_TMP/expect-fail.out" "Chart directory not found" "chart-missing message"

section "C: mock e2e — real mode, mocked helm/kubectl, NO cluster"
# R2/.env currently points CHART_DIR at a missing dir; restore it.
printf 'SECRETS_FILE=%s\n' "$secf" > "$R2/.env"
_e2e() { # _e2e OUTFILE [KNOB=VALUE ...] — real mode via env -i; the ONLY env
  #        the script sees is what is listed here, so real helm/kubectl (and
  #        any real KUBECONFIG) can never leak in. Knobs go through env, never
  #        function-prefixes (those persist past the call in bash).
  local _out="$1"
  shift
  env -i PATH="$STUBS:$BASE_PATH" HOME="$TESTS_TMP/home" HC_STUB_LOG="$TESTS_TMP/e2e.log" \
    "$@" bash "$R2/scripts/install.sh" >"$_out" 2>&1
}
_e2e "$TESTS_TMP/e2e.out"
[ $? = "0" ]; chk $? "mock e2e install succeeds"
chk_grep "$TESTS_TMP/e2e.out" "helm version: v3.22.1" "helm v3 accepted"
chk_grep "$TESTS_TMP/e2e.out" "Cluster reachable." "cluster reachability checked (mock)"
chk_grep "$TESTS_TMP/e2e.out" "Applying Kubernetes Secret 'homeassistant-secrets'" "Secret applied via mock"
chk_grep "$TESTS_TMP/e2e.out" "Helm release 'homeassistant' applied." "helm upgrade ran (mock)"
chk_grep "$TESTS_TMP/e2e.out" "http://192.168.1.50:8123" "LoadBalancer access URL printed"
chk_grep "$TESTS_TMP/e2e.out" "Home Assistant installation complete." "completion banner"
chk_grep "$TESTS_TMP/e2e.log" "helm upgrade --install" "mock log: helm upgrade served the call"
chk_grep "$TESTS_TMP/e2e.log" "rollout status" "mock log: rollout wait served the call"
chk_grep "$TESTS_TMP/e2e.log" "create secret generic" "mock log: secret create served the call"
chk_grep "$TESTS_TMP/e2e.log" "--atomic" "mock log: helm 3 upgrade carries --atomic"
chk_nogrep "$TESTS_TMP/e2e.log" "--rollback-on-failure" "mock log: no helm 4 flag before the v4 run"
chk_nogrep "$TESTS_TMP/e2e.out" "s3cr3tvalue" "secret VALUE never printed (e2e)"
chk_nogrep "$TESTS_TMP/e2e.log" "s3cr3tvalue" "secret VALUE never in mock log"

_e2e "$TESTS_TMP/e2e-v2.out" HC_STUB_HELM_VERSION=v2.16.6
[ $? = "1" ]; chk $? "helm v2 rejected in e2e"
chk_grep "$TESTS_TMP/e2e-v2.out" "helm v3+ is required" "v2 rejection message"
_e2e "$TESTS_TMP/e2e-v4.out" HC_STUB_HELM_VERSION=v4.0.0
[ $? = "0" ]; chk $? "helm v4 accepted in e2e"
chk_grep "$TESTS_TMP/e2e-v4.out" "helm version: v4.0.0" "v4 version logged"
chk_grep "$TESTS_TMP/e2e.log" "--rollback-on-failure" "mock log: helm 4 upgrade carries --rollback-on-failure"
_e2e "$TESTS_TMP/e2e-unreach.out" HC_STUB_NODES_FAIL=1
[ $? = "1" ]; chk $? "unreachable cluster aborts"
chk_grep "$TESTS_TMP/e2e-unreach.out" "not reachable" "unreachable message names KUBECONFIG"
_e2e "$TESTS_TMP/e2e-helmfail.out" HC_STUB_HELM_FAIL=1
[ $? = "1" ]; chk $? "helm upgrade failure aborts"
chk_grep "$TESTS_TMP/e2e-helmfail.out" "helm upgrade failed" "upgrade-failure message"
_e2e "$TESTS_TMP/e2e-rollout.out" HC_STUB_ROLLOUT_FAIL=1
[ $? = "1" ]; chk $? "failed rollout aborts"
chk_grep "$TESTS_TMP/e2e-rollout.out" "failed or timed out" "rollout-failure message"
_e2e "$TESTS_TMP/e2e-pending.out" HC_STUB_SVC_MODE=pending
[ $? = "0" ]; chk $? "pending external IP is a warning, not an error"
chk_grep "$TESTS_TMP/e2e-pending.out" "<pending>" "pending state reported"
chk_grep "$TESTS_TMP/e2e-pending.out" "http://<node-ip>:31456" "node-port fallback hint"
_e2e "$TESTS_TMP/e2e-np.out" HC_STUB_SVC_MODE=nodeport
[ $? = "0" ]; chk $? "NodePort service handled"
chk_grep "$TESTS_TMP/e2e-np.out" "http://<node-ip>:30812" "NodePort URL hint"
_e2e "$TESTS_TMP/e2e-nosvc.out" HC_STUB_SVC_MODE=none
[ $? = "0" ]; chk $? "service listing failure is a warning"
chk_grep "$TESTS_TMP/e2e-nosvc.out" "Could not list Services" "svc-list failure warned"

# ingress + TLS e2e: cert files applied as the TLS Secret, catch-all URL hint
_e2e "$TESTS_TMP/e2e-ing.out" INGRESS_ENABLED=true INGRESS_CLASS=traefik \
  INGRESS_TLS_ENABLED=true \
  INGRESS_TLS_CERT_FILE="$tlscert" INGRESS_TLS_KEY_FILE="$tlskey" \
  INGRESS_TRUSTED_PROXIES=10.42.0.0/16
[ $? = "0" ]; chk $? "ingress+TLS e2e install succeeds"
chk_grep "$TESTS_TMP/e2e-ing.out" "TLS Secret 'homeassistant-tls' applied." "TLS secret applied (mock)"
chk_grep "$TESTS_TMP/e2e-ing.out" "Ingress (catch-all rule): https://<ingress-controller-address>" "catch-all ingress URL printed"
chk_grep "$TESTS_TMP/e2e.log" "create secret tls" "mock log: tls secret served (e2e)"
chk_nogrep "$TESTS_TMP/e2e.log" "CERTDATA" "TLS file contents never in mock log"

finish
