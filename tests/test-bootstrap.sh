#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2181,SC2319,SC1091
# Harness idiom: `[ cmd ]; chk $? "msg"` and literal librun snippets.
# =============================================================================
# tests/test-bootstrap.sh — end-to-end tests for scripts/bootstrap-cluster.sh
#
# Ported from the original ad-hoc suite. Everything runs against a throwaway
# repo copy and committed mocks (ssh/scp/kubectl/helm) inside env -i — the
# suite never touches a real cluster, real SSH host, or the real repo tree.
# The generated .env is validated by chaining scripts/install.sh --dry-run.
# macOS note: audited for portability; executed on Linux here.
# =============================================================================
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KC_CANON="$TESTS_DIR/fixtures/k3s.yaml"
AK="$TESTS_TMP/ak"
BSREPO="$TESTS_TMP/repo"
NOHELM="$TESTS_TMP/nohelm"
mkdir -p "$NOHELM"
cp "$STUBS/ssh" "$STUBS/scp" "$STUBS/kubectl" "$NOHELM/"

portable_audit() {
  if grep -vE '^[[:space:]]*#' "$REPO_ROOT/scripts/bootstrap-cluster.sh" |
     grep -nE 'sed -i|readlink -f|stat -c|date -d|declare -A|mapfile|\$\{[a-zA-Z_]+,,' \
     >"$TESTS_TMP/audit.txt" 2>&1; then
    return 1
  fi
  return 0
}

# ============================== T1: full bootstrap (LB, release, PVC) ========
fresh_repo "$BSREPO"
H="$TESTS_TMP/home1"
mkdir -p "$H"
printf 'OLDVALUE=1\n' > "$BSREPO/.env"
printf 'MQTT_PASSWORD=s3cr3tvalue\n' > "$BSREPO/secrets.env"
chmod 600 "$BSREPO/secrets.env"
rm -f "$AK"
section "T1: full bootstrap (LoadBalancer, existing release and PVC)"
env -i PATH="$STUBS:$BASE_PATH" HOME="$H" HC_STUB_LOG="$TESTS_TMP/bs1.log" \
  HC_STUB_KUBECONFIG="$KC_CANON" HC_STUB_AK="$AK" \
  bash "$BSREPO/scripts/bootstrap-cluster.sh" --host pi@10.0.0.5 >"$TESTS_TMP/bs1.out" 2>&1
chk $? "T1 full bootstrap exits 0"

KC_DEST="$H/.kube/config"
[ -f "$H/.ssh/id_ed25519" ]; chk $? "T1 ssh key generated"
[ "$(stat -c %a "$H/.ssh")" = "700" ]; chk $? "T1 ~/.ssh mode 700"
[ "$(wc -l < "$AK")" = "1" ]; chk $? "T1 authorized_keys has exactly the key"
[ -f "$KC_DEST" ]; chk $? "T1 kubeconfig installed"
[ "$(stat -c %a "$KC_DEST")" = "600" ]; chk $? "T1 kubeconfig mode 600"
chk_regex "$KC_DEST" '^    server: https://10\.0\.0\.5:6443$' "T1 server URL rewritten (indent kept)"
chk_nogrep "$KC_DEST" "127.0.0.1" "T1 no 127.0.0.1 left"
[ "$(stat -c %a "$BSREPO/.env")" = "600" ]; chk $? "T1 .env mode 600"
chk_grep "$BSREPO/.env" "KUBECONFIG=\"$KC_DEST\"" "T1 .env KUBECONFIG absolute"
chk_grep "$BSREPO/.env" 'NAMESPACE="homeassistant"' "T1 .env NAMESPACE"
chk_grep "$BSREPO/.env" 'RELEASE_NAME="homeassistant"' "T1 .env RELEASE_NAME"
chk_grep "$BSREPO/.env" 'IMAGE_TAG="2026.10.3"' "T1 IMAGE_TAG from live release"
chk_grep "$BSREPO/.env" 'TIMEZONE="Europe/Berlin"' "T1 TIMEZONE from control plane"
chk_grep "$BSREPO/.env" 'NODE_ARCH="arm64"' "T1 NODE_ARCH from nodes"
chk_grep "$BSREPO/.env" 'STORAGE_CLASS="longhorn"' "T1 STORAGE_CLASS from existing PVC"
chk_grep "$BSREPO/.env" 'STORAGE_SIZE="8Gi"' "T1 STORAGE_SIZE from existing PVC"
chk_grep "$BSREPO/.env" 'SERVICE_TYPE="LoadBalancer"' "T1 SERVICE_TYPE LoadBalancer"
chk_regex "$BSREPO/.env" '^NODE_PORT=""$' "T1 NODE_PORT empty under LB"
chk_grep "$BSREPO/.env" 'INGRESS_CLASS="traefik"' "T1 INGRESS_CLASS detected"
chk_grep "$BSREPO/.env" 'INGRESS_ENABLED="true"' "T1 ingress enabled by default (controller detected)"
chk_regex "$BSREPO/.env" '^INGRESS_HOST=""$' "T1 catch-all (no host by default)"
chk_grep "$BSREPO/.env" 'INGRESS_TLS_ENABLED="true"' "T1 ingress TLS on by default"
chk_grep "$BSREPO/.env" 'INGRESS_TLS_SECRET_NAME="homeassistant-tls"' "T1 TLS secret name derived from release"
chk_regex "$BSREPO/.env" '^INGRESS_TLS_CERT_FILE=""$' "T1 no cert file by default"
chk_regex "$BSREPO/.env" '^INGRESS_TLS_KEY_FILE=""$' "T1 no key file by default"
chk_regex "$BSREPO/.env" '^INGRESS_TLS_ISSUER=""$' "T1 no issuer by default"
chk_grep "$BSREPO/.env" 'INGRESS_TRUSTED_PROXIES="10.42.0.0/16"' "T1 k3s pod CIDR as trusted proxies"
chk_grep "$TESTS_TMP/bs1.out" "cert-manager detected" "T1 cert-manager presence reported"
chk_grep "$TESTS_TMP/bs1.out" "enabled: true, tls: true" "T1 report shows ingress+TLS state"
chk_grep "$BSREPO/.env" 'SECRETS_FILE="secrets.env"' "T1 SECRETS_FILE set"
[ "$(find "$BSREPO" -maxdepth 1 -name '.env.backup-*' | wc -l)" = "1" ]; chk $? "T1 exactly one .env backup"
grep -q 'OLDVALUE=1' "$BSREPO"/.env.backup-* 2>/dev/null
chk $? "T1 backup holds old .env"
chk_nogrep "$BSREPO/.env" "OLDVALUE" "T1 new .env without old content"
chk_grep "$BSREPO/secrets.env" "s3cr3tvalue" "T1 existing secrets.env untouched"
chk_grep "$TESTS_TMP/bs1.out" "MQTT_PASSWORD" "T1 secret key NAMES reported"
chk_grep "$TESTS_TMP/bs1.out" "HA_TOKEN" "T1 cluster secret keys reported"
chk_nogrep "$TESTS_TMP/bs1.out" "s3cr3tvalue" "T1 secret VALUES never printed"

# re-run: idempotent
env -i PATH="$STUBS:$BASE_PATH" HOME="$H" HC_STUB_LOG="$TESTS_TMP/bs1.log" \
  HC_STUB_KUBECONFIG="$KC_CANON" HC_STUB_AK="$AK" \
  bash "$BSREPO/scripts/bootstrap-cluster.sh" --host pi@10.0.0.5 >>"$TESTS_TMP/bs1.out" 2>&1
chk $? "T1 re-run exits 0 (idempotent)"
[ "$(wc -l < "$AK")" = "1" ]; chk $? "T1 authorized_keys still exactly one line"
[ "$(find "$BSREPO" -maxdepth 1 -name '.env.backup-*' | wc -l)" = "2" ]; chk $? "T1 second backup created (collision-safe)"

# T9: the generated .env must drive install.sh --dry-run (cross-lane hand-off)
env -i PATH="$STUBS:$BASE_PATH" HOME="$H" HC_STUB_LOG="$TESTS_TMP/bs9.log" \
  bash "$BSREPO/scripts/install.sh" --dry-run >"$TESTS_TMP/bs9.out" 2>&1
[ $? = "0" ]; chk $? "T9 install.sh --dry-run accepts the bootstrap .env"
chk_grep "$TESTS_TMP/bs9.out" "Europe/Berlin" "T9 dry-run renders bootstrap TIMEZONE"
chk_grep "$TESTS_TMP/bs9.out" "longhorn" "T9 dry-run renders bootstrap STORAGE_CLASS"
chk_grep "$TESTS_TMP/bs9.out" "homeassistant-secrets" "T9 dry-run uses the release secret"
chk_grep "$TESTS_TMP/bs9.out" 'secretName: "homeassistant-tls"' "T9 dry-run renders TLS from bootstrap defaults"
chk_grep "$TESTS_TMP/bs9.out" '- "10.42.0.0/16"' "T9 dry-run renders trusted proxies"
chk_regex "$TESTS_TMP/bs9.out" '^    -$' "T9 dry-run renders the catch-all rule"

# ============================== T2: batch fail -> interactive retry ==========
fresh_repo "$BSREPO"
H2="$TESTS_TMP/home2"
mkdir -p "$H2"
rm -f "$AK"
section "T2: batch auth fails, interactive retry installs the key"
env -i PATH="$STUBS:$BASE_PATH" HOME="$H2" HC_STUB_LOG="$TESTS_TMP/bs2.log" \
  HC_STUB_KUBECONFIG="$KC_CANON" HC_STUB_AK="$AK" HC_STUB_SSH_BATCH_FAIL=1 \
  bash "$BSREPO/scripts/bootstrap-cluster.sh" --host pi@10.0.0.5 >"$TESTS_TMP/bs2.out" 2>&1
chk $? "T2 batch-fail path still succeeds (interactive retry)"
[ "$(wc -l < "$AK")" = "1" ]; chk $? "T2 key installed on retry"
chk_grep "$TESTS_TMP/bs2.out" "One-time authentication" "T2 user warned before prompting"
chk_grep "$TESTS_TMP/bs2.out" "Passwordless SSH" "T2 passwordless verified"

# ============================== T3: scp fails -> sudo cat fallback ===========
fresh_repo "$BSREPO"
H3="$TESTS_TMP/home3"
mkdir -p "$H3"
section "T3: scp failure falls back to 'sudo cat'"
env -i PATH="$STUBS:$BASE_PATH" HOME="$H3" HC_STUB_LOG="$TESTS_TMP/bs3.log" \
  HC_STUB_KUBECONFIG="$KC_CANON" HC_STUB_AK="$AK" HC_STUB_SCP_FAIL=1 \
  bash "$BSREPO/scripts/bootstrap-cluster.sh" --host pi@10.0.0.5 >"$TESTS_TMP/bs3.out" 2>&1
chk $? "T3 sudo-cat fallback succeeds"
chk_grep "$TESTS_TMP/bs3.log" "sudo cat" "T3 sudo cat used over ssh"
chk_grep "$H3/.kube/config" "https://10.0.0.5:6443" "T3 fetched kubeconfig rewritten"

# ============================== T4: review-only, NodePort fallback ===========
fresh_repo "$BSREPO"
H4="$TESTS_TMP/home4"
mkdir -p "$H4"
: > "$H4/kc.yaml"
section "T4: review-only run, NodePort fallback"
env -i PATH="$STUBS:$BASE_PATH" HOME="$H4" KUBECONFIG="$H4/kc.yaml" \
  HC_STUB_LOG="$TESTS_TMP/bs4.log" HC_STUB_KUBECONFIG="$KC_CANON" \
  HC_STUB_NO_LB=1 HC_STUB_NO_RELEASE=1 HC_STUB_NO_PVC=1 \
  bash "$BSREPO/scripts/bootstrap-cluster.sh" >"$TESTS_TMP/bs4.out" 2>&1
chk $? "T4 review-only run exits 0"
chk_grep "$BSREPO/.env" 'SERVICE_TYPE="NodePort"' "T4 NodePort fallback"
chk_grep "$BSREPO/.env" 'NODE_PORT="30812"' "T4 default nodePort 30812"
chk_grep "$BSREPO/.env" 'IMAGE_TAG="2026.11.0"' "T4 chart-default image tag (no release)"
chk_grep "$BSREPO/.env" 'STORAGE_SIZE="5Gi"' "T4 default storage size"
chk_grep "$BSREPO/.env" 'STORAGE_CLASS="local-path"' "T4 default storage class detected"
chk_grep "$BSREPO/.env" 'TIMEZONE="UTC"' "T4 UTC without ssh"
chk_grep "$BSREPO/.env" "KUBECONFIG=\"$H4/kc.yaml\"" "T4 existing kubeconfig referenced"
[ "$(find "$BSREPO" -maxdepth 1 -name '.env.backup-*' | wc -l)" = "0" ]; chk $? "T4 no backup when no prior .env"
[ -f "$BSREPO/secrets.env" ]; chk $? "T4 secrets.env scaffolded"
[ "$(stat -c %a "$BSREPO/secrets.env")" = "600" ]; chk $? "T4 secrets.env mode 600"
chk_grep "$TESTS_TMP/bs4.out" "export KUBECONFIG=" "T4 report prints KUBECONFIG export line"
chk_grep "$BSREPO/.env" 'INGRESS_ENABLED="true"' "T4 ingress defaults on (review-only too)"

# ============================== T4b: no ingress controller ====================
fresh_repo "$BSREPO"
H4b="$TESTS_TMP/home4b"
mkdir -p "$H4b"
: > "$H4b/kc.yaml"
section "T4b: no ingress controller keeps ingress and TLS off"
env -i PATH="$STUBS:$BASE_PATH" HOME="$H4b" KUBECONFIG="$H4b/kc.yaml" \
  HC_STUB_LOG="$TESTS_TMP/bs4b.log" HC_STUB_KUBECONFIG="$KC_CANON" \
  HC_STUB_NO_LB=1 HC_STUB_NO_RELEASE=1 HC_STUB_NO_PVC=1 HC_STUB_NO_INGRESS=1 \
  bash "$BSREPO/scripts/bootstrap-cluster.sh" >"$TESTS_TMP/bs4b.out" 2>&1
chk $? "T4b no-ingress run exits 0"
chk_regex "$BSREPO/.env" '^INGRESS_ENABLED="false"$' "T4b ingress stays disabled"
chk_regex "$BSREPO/.env" '^INGRESS_CLASS=""$' "T4b no ingress class"
chk_regex "$BSREPO/.env" '^INGRESS_TLS_ENABLED="false"$' "T4b TLS off"
chk_regex "$BSREPO/.env" '^INGRESS_TLS_SECRET_NAME=""$' "T4b no TLS secret name"
chk_regex "$BSREPO/.env" '^INGRESS_TRUSTED_PROXIES=""$' "T4b no trusted proxies"
chk_grep "$TESTS_TMP/bs4b.out" "No ingress controller detected" "T4b absence reported"

# ============================== T4c: cert-manager absent ======================
fresh_repo "$BSREPO"
H4c="$TESTS_TMP/home4c"
mkdir -p "$H4c"
: > "$H4c/kc.yaml"
section "T4c: cert-manager absent — cert/key file hint"
env -i PATH="$STUBS:$BASE_PATH" HOME="$H4c" KUBECONFIG="$H4c/kc.yaml" \
  HC_STUB_LOG="$TESTS_TMP/bs4c.log" HC_STUB_KUBECONFIG="$KC_CANON" \
  HC_STUB_NO_LB=1 HC_STUB_NO_RELEASE=1 HC_STUB_NO_PVC=1 HC_STUB_NO_CERTMGR=1 \
  bash "$BSREPO/scripts/bootstrap-cluster.sh" >"$TESTS_TMP/bs4c.out" 2>&1
chk $? "T4c run exits 0"
chk_grep "$TESTS_TMP/bs4c.out" "cert-manager not detected" "T4c cert-manager absence reported"
chk_grep "$TESTS_TMP/bs4c.out" "INGRESS_TLS_CERT_FILE/INGRESS_TLS_KEY_FILE" "T4c file path hint"

# ============================== T5: mixed arch ================================
fresh_repo "$BSREPO"
H5="$TESTS_TMP/home5"
mkdir -p "$H5"
: > "$H5/kc.yaml"
section "T5: mixed-architecture cluster"
env -i PATH="$STUBS:$BASE_PATH" HOME="$H5" KUBECONFIG="$H5/kc.yaml" \
  HC_STUB_LOG="$TESTS_TMP/bs5.log" HC_STUB_ARCHS='arm64\namd64\n' \
  bash "$BSREPO/scripts/bootstrap-cluster.sh" >"$TESTS_TMP/bs5.out" 2>&1
chk $? "T5 mixed-arch run exits 0"
chk_regex "$BSREPO/.env" '^NODE_ARCH=""$' "T5 NODE_ARCH empty on mixed arch"
chk_grep "$TESTS_TMP/bs5.out" "Mixed-architecture" "T5 mixed-arch warning"

# ============================== T6: helm absent ===============================
fresh_repo "$BSREPO"
H6="$TESTS_TMP/home6"
mkdir -p "$H6"
section "T6: helm absent degrades gracefully"
env -i PATH="$NOHELM:$BASE_PATH" HOME="$H6" HC_STUB_LOG="$TESTS_TMP/bs6.log" \
  HC_STUB_KUBECONFIG="$KC_CANON" HC_STUB_AK="$AK" \
  bash "$BSREPO/scripts/bootstrap-cluster.sh" --host pi@10.0.0.5 >"$TESTS_TMP/bs6.out" 2>&1
chk $? "T6 run without helm exits 0"
chk_grep "$TESTS_TMP/bs6.out" "helm is not on PATH" "T6 helm absence warned"
chk_grep "$BSREPO/.env" 'IMAGE_TAG="2026.11.0"' "T6 chart-default tag without helm"

# ============================== T7: error paths ===============================
section "T7: error paths"
fresh_repo "$BSREPO"
expect_fail "no-kubectl run" env -i PATH="$BASE_PATH" HOME="$TESTS_TMP/home" \
  bash "$BSREPO/scripts/bootstrap-cluster.sh"
chk_grep "$TESTS_TMP/expect-fail.out" "Required command not found: kubectl" "T7 friendly kubectl error"
chk_grep "$TESTS_TMP/expect-fail.out" "install-prereqs" "T7 hint points at install-prereqs.sh"
expect_fail "--host + --kubeconfig conflict" env -i PATH="$STUBS:$BASE_PATH" \
  HOME="$TESTS_TMP/home" bash "$BSREPO/scripts/bootstrap-cluster.sh" --host a@b --kubeconfig /tmp/x
chk_grep "$TESTS_TMP/expect-fail.out" "mutually exclusive" "T7 conflict message clear"
expect_fail "unknown flag" env -i PATH="$STUBS:$BASE_PATH" HOME="$TESTS_TMP/home" \
  bash "$BSREPO/scripts/bootstrap-cluster.sh" --bogus
env -i PATH="$STUBS:$BASE_PATH" HOME="$TESTS_TMP/home" \
  bash "$BSREPO/scripts/bootstrap-cluster.sh" --help >"$TESTS_TMP/bs7e.out" 2>&1
[ $? = "0" ]; chk $? "T7 --help exits 0"
chk_grep "$TESTS_TMP/bs7e.out" "bootstrap-cluster.sh" "T7 --help shows usage"

# ============================== T8: portability audit =========================
section "T8: portability audit"
portable_audit
chk $? "T8 no GNU-only/bash4-only constructs"

finish
