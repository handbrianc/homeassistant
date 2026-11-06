#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2181,SC2319,SC1091,SC2086
# Harness idiom: `[ cmd ]; chk $? "msg"` and literal librun snippets.
# =============================================================================
# tests/test-uninstall.sh — tests for scripts/uninstall.sh
#
# Cluster safety: layer B uses the built-in --dry-run (zero cluster access,
# no tools); layer C runs real mode against committed mocks inside env -i —
# a real cluster can never be contacted. Every e2e case gets its own
# HC_STUB_LOG so nogrep assertions never trip on shared log content.
# =============================================================================
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

section "A: help & flag errors (no tools)"
env -i PATH="$BASE_PATH" bash "$REPO_ROOT/scripts/uninstall.sh" --help >"$TESTS_TMP/help.out" 2>&1
[ $? = "0" ]; chk $? "--help exits 0"
chk_grep "$TESTS_TMP/help.out" "Usage: scripts/uninstall.sh" "--help shows usage"
chk_grep "$TESTS_TMP/help.out" "--purge-data" "--help documents --purge-data"
chk_grep "$TESTS_TMP/help.out" "helm.sh/resource-policy=keep" "--help explains data preservation"
expect_fail "unknown flag rejected" env -i PATH="$BASE_PATH" bash \
  "$REPO_ROOT/scripts/uninstall.sh" --bogus
chk_grep "$TESTS_TMP/expect-fail.out" "Unknown argument" "unknown-flag message"
expect_fail "bad PURGE_DATA env rejected" env -i PATH="$BASE_PATH" PURGE_DATA=maybe bash \
  "$REPO_ROOT/scripts/uninstall.sh" --dry-run
chk_grep "$TESTS_TMP/expect-fail.out" "PURGE_DATA must be" "bad PURGE_DATA message"
expect_fail "bad KEEP_SECRETS env rejected" env -i PATH="$BASE_PATH" KEEP_SECRETS=yes bash \
  "$REPO_ROOT/scripts/uninstall.sh" --dry-run
chk_grep "$TESTS_TMP/expect-fail.out" "KEEP_SECRETS must be" "bad KEEP_SECRETS message"
expect_fail "bad DELETE_NAMESPACE env rejected" env -i PATH="$BASE_PATH" DELETE_NAMESPACE=1! bash \
  "$REPO_ROOT/scripts/uninstall.sh" --dry-run
chk_grep "$TESTS_TMP/expect-fail.out" "DELETE_NAMESPACE must be" "bad DELETE_NAMESPACE message"

section "B: dry-run — real script, no cluster, no toolchain"
R="$TESTS_TMP/repo"
fresh_repo "$R"
mkdir -p "$TESTS_TMP/home"
env -i PATH="$BASE_PATH" HOME="$TESTS_TMP/home" bash "$R/scripts/uninstall.sh" --dry-run \
  >"$TESTS_TMP/dry.out" 2>&1
[ $? = "0" ]; chk $? "--dry-run succeeds with NO helm/kubectl on PATH"
chk_grep "$TESTS_TMP/dry.out" "DRY-RUN" "dry-run announced"
chk_regex "$TESTS_TMP/dry.out" 'helm uninstall "homeassistant" -n "homeassistant"' "uninstall command in plan"
chk_grep "$TESTS_TMP/dry.out" "helm.sh/resource-policy=keep" "PVC protection in plan"
chk_regex "$TESTS_TMP/dry.out" 'kubectl delete secret "homeassistant-secrets"' "app secret deletion in plan"
chk_regex "$TESTS_TMP/dry.out" 'kubectl delete secret "homeassistant-tls"' "TLS secret deletion in plan"
chk_grep "$TESTS_TMP/dry.out" "Data volume(s) preserved" "data preservation reported"
chk_grep "$TESTS_TMP/dry.out" "Dry-run complete" "dry-run completes"
chk_grep "$TESTS_TMP/dry.out" "no cluster access was performed" "dry-run states no cluster access"

env -i PATH="$BASE_PATH" HOME="$TESTS_TMP/home" DRY_RUN=1 bash "$R/scripts/uninstall.sh" \
  >"$TESTS_TMP/dry2.out" 2>&1
[ $? = "0" ]; chk $? "DRY_RUN=1 environment drives dry-run"
chk_grep "$TESTS_TMP/dry2.out" "[dry-run]" "DRY_RUN=1 prints dry-run commands"

env -i PATH="$BASE_PATH" HOME="$TESTS_TMP/home" bash "$R/scripts/uninstall.sh" --dry-run --purge-data \
  >"$TESTS_TMP/dry3.out" 2>&1
[ $? = "0" ]; chk $? "--purge-data dry-run succeeds"
chk_grep "$TESTS_TMP/dry3.out" "ALL Home Assistant data" "purge announces data loss"
chk_grep "$TESTS_TMP/dry3.out" "kubectl delete <PVC" "purge prints the delete plan"
chk_nogrep "$TESTS_TMP/dry3.out" "annotate" "purge never annotates"

env -i PATH="$BASE_PATH" HOME="$TESTS_TMP/home" bash "$R/scripts/uninstall.sh" --dry-run --keep-secrets \
  >"$TESTS_TMP/dry4.out" 2>&1
[ $? = "0" ]; chk $? "--keep-secrets dry-run succeeds"
chk_nogrep "$TESTS_TMP/dry4.out" "kubectl delete secret" "keep-secrets keeps both secrets in plan"
chk_grep "$TESTS_TMP/dry4.out" "would be kept" "keep-secrets announced"

env -i PATH="$BASE_PATH" HOME="$TESTS_TMP/home" bash "$R/scripts/uninstall.sh" --dry-run --delete-namespace \
  >"$TESTS_TMP/dry5.out" 2>&1
[ $? = "0" ]; chk $? "--delete-namespace dry-run succeeds"
chk_regex "$TESTS_TMP/dry5.out" 'kubectl delete namespace "homeassistant"' "namespace deletion in plan"
chk_grep "$TESTS_TMP/dry5.out" "everything remaining inside" "namespace warning"

env -i PATH="$BASE_PATH" HOME="$TESTS_TMP/home" bash "$R/scripts/uninstall.sh" --dry-run \
  --namespace ha-ns --release ha-rel >"$TESTS_TMP/dry6.out" 2>&1
[ $? = "0" ]; chk $? "flag overrides accepted"
chk_regex "$TESTS_TMP/dry6.out" 'helm uninstall "ha-rel" -n "ha-ns"' "overrides reach the planned commands"
chk_grep "$TESTS_TMP/dry6.out" "instance=ha-rel" "PVC label follows the release override"
chk_grep "$TESTS_TMP/dry6.out" "ha-rel-secrets" "secret names follow the release override"

printf 'NAMESPACE=envns\nRELEASE_NAME=envrel\n' > "$R/.env"
env -i PATH="$BASE_PATH" HOME="$TESTS_TMP/home" bash "$R/scripts/uninstall.sh" --dry-run \
  >"$TESTS_TMP/dry7.out" 2>&1
[ $? = "0" ]; chk $? ".env values honored"
chk_regex "$TESTS_TMP/dry7.out" 'helm uninstall "envrel" -n "envns"' ".env namespace/release used"
env -i PATH="$BASE_PATH" HOME="$TESTS_TMP/home" bash "$R/scripts/uninstall.sh" --dry-run --release flarel \
  >"$TESTS_TMP/dry8.out" 2>&1
[ $? = "0" ]; chk $? "flags win over .env"
chk_regex "$TESTS_TMP/dry8.out" 'helm uninstall "flarel" -n "envns"' "release flag beats .env; namespace from .env"
rm -f "$R/.env"

section "C: mock e2e — real mode, mocked helm/kubectl, NO cluster"
_e2e() { # _e2e OUTFILE LOGFILE SCRIPT-ARGS... — one knob via UN_KNOB (NAME=VALUE)
  local _out="$1" _log="$2"
  shift 2
  env -i PATH="$STUBS:$BASE_PATH" HOME="$TESTS_TMP/home" HC_STUB_LOG="$_log" ${UN_KNOB:-} \
    bash "$R/scripts/uninstall.sh" "$@" >"$_out" 2>&1
}

UN_KNOB= ; _e2e "$TESTS_TMP/e2e.out" "$TESTS_TMP/e2e-default.log"
[ $? = "0" ]; chk $? "default uninstall exits 0"
chk_grep "$TESTS_TMP/e2e.out" "Helm release 'homeassistant' uninstalled" "uninstall ran via mock"
chk_grep "$TESTS_TMP/e2e.out" "Data volume(s) preserved" "data preservation reported"
chk_grep "$TESTS_TMP/e2e.out" "scripts/install.sh" "reinstall hint printed"
chk_grep "$TESTS_TMP/e2e.out" "--purge-data" "purge hint printed"
chk_grep "$TESTS_TMP/e2e-default.log" "helm uninstall homeassistant -n homeassistant --wait --timeout 10m" "mock log: uninstall served the call"
chk_grep "$TESTS_TMP/e2e-default.log" "kubectl get pvc -n homeassistant -l app.kubernetes.io/instance=homeassistant -o name" "mock log: PVC discovery by release label"
chk_grep "$TESTS_TMP/e2e-default.log" "helm.sh/resource-policy=keep --overwrite" "mock log: PVC annotated keep"
chk_grep "$TESTS_TMP/e2e-default.log" "kubectl delete secret homeassistant-secrets -n homeassistant --ignore-not-found" "mock log: app secret deleted"
chk_grep "$TESTS_TMP/e2e-default.log" "kubectl delete secret homeassistant-tls -n homeassistant --ignore-not-found" "mock log: TLS secret deleted"
chk_nogrep "$TESTS_TMP/e2e-default.log" "delete namespace" "namespace kept by default"
chk_nogrep "$TESTS_TMP/e2e-default.log" "delete persistentvolumeclaim" "no PVC deletion by default"
chk_grep "$TESTS_TMP/e2e-default.log" "kubectl get nodes" "mock log: cluster reachability checked"

UN_KNOB= ; _e2e "$TESTS_TMP/e2e-purge.out" "$TESTS_TMP/e2e-purge.log" --purge-data
[ $? = "0" ]; chk $? "--purge-data uninstall exits 0"
chk_grep "$TESTS_TMP/e2e-purge.out" "ALL Home Assistant data" "purge announces data loss"
chk_grep "$TESTS_TMP/e2e-purge.out" "Deleted data volume: persistentvolumeclaim/homeassistant-config" "PVC deleted"
chk_grep "$TESTS_TMP/e2e-purge.log" "kubectl delete persistentvolumeclaim/homeassistant-config -n homeassistant --ignore-not-found" "mock log: PVC delete served"
chk_nogrep "$TESTS_TMP/e2e-purge.log" "annotate" "purge never annotates"
chk_grep "$TESTS_TMP/e2e-purge.log" "kubectl delete secret homeassistant-secrets" "purge also cleans secrets"

UN_KNOB= ; _e2e "$TESTS_TMP/e2e-keep.out" "$TESTS_TMP/e2e-keep.log" --keep-secrets
[ $? = "0" ]; chk $? "--keep-secrets exits 0"
chk_grep "$TESTS_TMP/e2e-keep.out" "Keeping Secrets" "keep-secrets announced"
chk_nogrep "$TESTS_TMP/e2e-keep.log" "delete secret" "keep-secrets: no secret deletion"
chk_grep "$TESTS_TMP/e2e-keep.log" "helm uninstall homeassistant" "keep-secrets still uninstalls"

UN_KNOB= ; _e2e "$TESTS_TMP/e2e-ns.out" "$TESTS_TMP/e2e-ns.log" --delete-namespace
[ $? = "0" ]; chk $? "--delete-namespace exits 0"
chk_grep "$TESTS_TMP/e2e-ns.log" "kubectl delete namespace homeassistant --ignore-not-found" "mock log: namespace delete served"
chk_grep "$TESTS_TMP/e2e-ns.out" "everything remaining inside" "namespace warning printed"

UN_KNOB=HC_STUB_NO_RELEASE=1 ; _e2e "$TESTS_TMP/e2e-absent.out" "$TESTS_TMP/e2e-absent.log"
[ $? = "0" ]; chk $? "release-absent is idempotent (exit 0)"
chk_grep "$TESTS_TMP/e2e-absent.out" "not found" "absence warned"
chk_nogrep "$TESTS_TMP/e2e-absent.log" "helm uninstall" "no uninstall attempted"
chk_grep "$TESTS_TMP/e2e-absent.log" "kubectl delete secret homeassistant-secrets" "cleanups still run"

UN_KNOB=HC_STUB_NO_RELEASE=1 ; _e2e "$TESTS_TMP/e2e-absent-purge.out" "$TESTS_TMP/e2e-absent-purge.log" --purge-data
[ $? = "0" ]; chk $? "purge with release absent exits 0 (orphan cleanup)"
chk_grep "$TESTS_TMP/e2e-absent-purge.log" "kubectl delete persistentvolumeclaim/homeassistant-config" "orphan PVC still purged"
chk_grep "$TESTS_TMP/e2e-absent-purge.out" "ALL Home Assistant data" "purge warning also fires without a release"

UN_KNOB=HC_STUB_UNINSTALL_FAIL=1 ; _e2e "$TESTS_TMP/e2e-fail.out" "$TESTS_TMP/e2e-fail.log"
[ $? = "1" ]; chk $? "helm uninstall failure aborts"
chk_grep "$TESTS_TMP/e2e-fail.out" "helm uninstall failed" "failure message printed"
chk_grep "$TESTS_TMP/e2e-fail.out" "helm status" "failure hint points at helm status"
chk_nogrep "$TESTS_TMP/e2e-fail.log" "delete secret" "failure aborts before secret cleanup"
chk_nogrep "$TESTS_TMP/e2e-fail.log" "delete persistentvolumeclaim" "failure aborts before any purge"

UN_KNOB=HC_STUB_NO_PVC=1 ; _e2e "$TESTS_TMP/e2e-nopvc.out" "$TESTS_TMP/e2e-nopvc.log"
[ $? = "0" ]; chk $? "no-PVC uninstall exits 0"
chk_grep "$TESTS_TMP/e2e-nopvc.out" "No PVCs matching" "no-PVC case announced"
chk_nogrep "$TESTS_TMP/e2e-nopvc.log" "annotate" "no annotation without PVCs"
chk_grep "$TESTS_TMP/e2e-nopvc.log" "helm uninstall homeassistant" "release still uninstalled"

finish
