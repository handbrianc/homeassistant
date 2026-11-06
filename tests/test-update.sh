#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2181,SC2319,SC1091
# Harness idiom: `[ cmd ]; chk $? "msg"` and literal librun snippets.
# =============================================================================
# tests/test-update.sh — tests for scripts/update.sh
#
# Cluster safety: layer B uses the built-in --dry-run (zero cluster access,
# no tools); layer C runs real mode against committed mocks inside env -i —
# a real cluster can never be contacted. Rollback hints are asserted.
# =============================================================================
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

section "A: help & flag errors (no tools)"
env -i PATH="$BASE_PATH" bash "$REPO_ROOT/scripts/update.sh" --help >"$TESTS_TMP/help.out" 2>&1
[ $? = "0" ]; chk $? "--help exits 0"
chk_grep "$TESTS_TMP/help.out" "Usage: scripts/update.sh" "--help shows usage"
expect_fail "unknown flag rejected" env -i PATH="$BASE_PATH" bash \
  "$REPO_ROOT/scripts/update.sh" --bogus
chk_grep "$TESTS_TMP/expect-fail.out" "Unknown argument" "unknown-flag message"

section "B: dry-run — real script, no cluster, no toolchain"
R="$TESTS_TMP/repo"
fresh_repo "$R"
mkdir -p "$TESTS_TMP/home"
env -i PATH="$BASE_PATH" HOME="$TESTS_TMP/home" bash "$R/scripts/update.sh" --dry-run \
  >"$TESTS_TMP/dry.out" 2>&1
[ $? = "0" ]; chk $? "--dry-run succeeds with NO helm/kubectl on PATH"
chk_grep "$TESTS_TMP/dry.out" "DRY-RUN" "dry-run announced"
chk_grep "$TESTS_TMP/dry.out" "BEGIN generated values" "generated values printed"
chk_regex "$TESTS_TMP/dry.out" 'helm history homeassistant -n "homeassistant"' "history command in would-run list"
chk_grep "$TESTS_TMP/dry.out" "skipping the full manifest render" "no-helm dry-run notes the skipped render"
chk_grep "$TESTS_TMP/dry.out" "cert=false" "config line shows certificate mode"
chk_grep "$TESTS_TMP/dry.out" "Dry-run complete" "dry-run completes"
env -i PATH="$BASE_PATH" HOME="$TESTS_TMP/home" DRY_RUN=1 bash "$R/scripts/update.sh" \
  >"$TESTS_TMP/dry2.out" 2>&1
[ $? = "0" ]; chk $? "DRY_RUN=1 environment drives dry-run"

section "C: mock e2e — real mode, mocked helm/kubectl, NO cluster"
secf="$TESTS_TMP/sec.env"
printf 'MQTT_PASSWORD=s3cr3tvalue\n' > "$secf"
printf 'SECRETS_FILE=%s\n' "$secf" > "$R/.env"
_e2e() { # _e2e OUTFILE [KNOB=VALUE ...] — env -i + mocks first on PATH only
  local _out="$1"
  shift
  env -i PATH="$STUBS:$BASE_PATH" HOME="$TESTS_TMP/home" HC_STUB_LOG="$TESTS_TMP/e2e.log" \
    "$@" bash "$R/scripts/update.sh" >"$_out" 2>&1
}
_e2e "$TESTS_TMP/e2e.out"
[ $? = "0" ]; chk $? "mock e2e update succeeds"
chk_grep "$TESTS_TMP/e2e.out" "Helm release 'homeassistant' updated" "update applied via mock"
chk_grep "$TESTS_TMP/e2e.out" "Release revision history" "history printed"
chk_grep "$TESTS_TMP/e2e.out" "helm rollback homeassistant 1 -n homeassistant" "rollback hint points at revision 1"
chk_grep "$TESTS_TMP/e2e.out" "Data note: the PVC is not touched" "data-preservation note"
chk_grep "$TESTS_TMP/e2e.out" "Home Assistant update complete." "completion banner"
chk_grep "$TESTS_TMP/e2e.log" "helm upgrade --install" "mock log: helm upgrade served the call"
chk_grep "$TESTS_TMP/e2e.log" "history" "mock log: history served the call"
chk_nogrep "$TESTS_TMP/e2e.out" "s3cr3tvalue" "secret VALUE never printed"

_e2e "$TESTS_TMP/e2e-one.out" HC_STUB_HIST_ONE=1
[ $? = "0" ]; chk $? "single-revision history handled"
chk_grep "$TESTS_TMP/e2e-one.out" "nothing to roll back to yet" "revision-1 case announced"
_e2e "$TESTS_TMP/e2e-nohist.out" HC_STUB_HIST_EMPTY=1
[ $? = "0" ]; chk $? "unreadable history is a warning"
chk_grep "$TESTS_TMP/e2e-nohist.out" "Could not read the release history" "history failure warned"
_e2e "$TESTS_TMP/e2e-v2.out" HC_STUB_HELM_VERSION=v2.16.6
[ $? = "1" ]; chk $? "helm v2 rejected"
chk_grep "$TESTS_TMP/e2e-v2.out" "helm v3+ is required" "v2 rejection message"
_e2e "$TESTS_TMP/e2e-v4.out" HC_STUB_HELM_VERSION=v4.0.0
[ $? = "0" ]; chk $? "helm v4 accepted"
chk_grep "$TESTS_TMP/e2e-v4.out" "helm version: v4.0.0" "v4 version logged"
_e2e "$TESTS_TMP/e2e-fail.out" HC_STUB_HELM_FAIL=1
[ $? = "1" ]; chk $? "helm upgrade failure aborts"
chk_grep "$TESTS_TMP/e2e-fail.out" "previous revision is intact" "failure message reassures about the previous revision"

finish
