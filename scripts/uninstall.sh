#!/usr/bin/env bash
# =============================================================================
# scripts/uninstall.sh — remove the Home Assistant Helm release.
#
# DATA IS PRESERVED BY DEFAULT: before the uninstall, the release's PVC(s) are
# annotated `helm.sh/resource-policy=keep` so helm keeps them when it deletes
# the release; your Home Assistant configuration survives and install.sh
# re-adopts the existing volume on reinstall. Deleting the data is explicit
# (--purge-data) and warns loudly first.
#
# The Secrets the installer applied outside of helm (<release>-secrets and the
# ingress TLS secret) are deleted with the release unless --keep-secrets.
# Secret values are never printed.
#
# Usage:
#   scripts/uninstall.sh [-h|--help] [--dry-run] [--namespace NS]
#                        [--release NAME] [--purge-data] [--keep-secrets]
#                        [--delete-namespace]
#
# Dry-run (also via DRY_RUN=1) prints the plan and every helm/kubectl command
# and needs no cluster access and no toolchain.
#
# Configuration precedence: built-in defaults < .env < command-line flags.
# Uninstall-only switches (not part of the .env contract; flags win):
#   --purge-data / PURGE_DATA, --keep-secrets / KEEP_SECRETS,
#   --delete-namespace / DELETE_NAMESPACE
# ===
# =============================================================================
set -Eeuo pipefail

# Repository root = one level above scripts/ (portable cd + pwd chain).
REPO_ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)" || {
  printf 'error: cannot determine script directory\n' >&2
  exit 1
}
# Sourcing path is built at runtime from REPO_ROOT; the directive lets
# `shellcheck -x` follow the library when run from the repository root.
# shellcheck source=scripts/lib/common.sh
. "$REPO_ROOT/scripts/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/uninstall.sh [options]

Removes the Home Assistant Helm release. DATA IS PRESERVED BY DEFAULT: the
release's PVC(s) are annotated helm.sh/resource-policy=keep before
`helm uninstall`, so your configuration survives and install.sh re-adopts the
existing volume on reinstall.

Options:
  -h, --help           Show this help and exit.
      --dry-run        Print the plan and every helm/kubectl command without
                       touching the cluster (also honors DRY_RUN=1 in the
                       environment or .env); needs no toolchain.
      --namespace NS   Override NAMESPACE from .env.
      --release NAME   Override RELEASE_NAME from .env.
      --purge-data     Delete the release's PVC(s) after the uninstall — ALL
                       Home Assistant data is lost. Default: preserved.
      --keep-secrets   Keep the '<release>-secrets' and ingress TLS Secrets.
                       Default: both are deleted.
      --delete-namespace
                       Also delete the namespace — everything remaining inside
                       it is removed with it. Default: kept.

Uninstall-only switches also accept environment equivalents (flags win):
PURGE_DATA, KEEP_SECRETS, DELETE_NAMESPACE (true/false).
Configuration precedence: built-in defaults < .env < command-line flags.
EOF
}

# --- Step 1: parse flags (applied later — flags win over .env) ---------------
FLAG_NAMESPACE=""
FLAG_RELEASE=""
FLAG_DRY_RUN=""
FLAG_PURGE_DATA=""
FLAG_KEEP_SECRETS=""
FLAG_DELETE_NAMESPACE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --dry-run)
      FLAG_DRY_RUN=1
      ;;
    --purge-data)
      FLAG_PURGE_DATA=1
      ;;
    --keep-secrets)
      FLAG_KEEP_SECRETS=1
      ;;
    --delete-namespace)
      FLAG_DELETE_NAMESPACE=1
      ;;
    --namespace)
      if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then die "--namespace requires a non-empty argument"; fi
      FLAG_NAMESPACE="$2"
      shift
      ;;
    --namespace=*)
      FLAG_NAMESPACE="${1#--namespace=}"
      if [ -z "$FLAG_NAMESPACE" ]; then die "--namespace requires a non-empty value"; fi
      ;;
    --release)
      if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then die "--release requires a non-empty argument"; fi
      FLAG_RELEASE="$2"
      shift
      ;;
    --release=*)
      FLAG_RELEASE="${1#--release=}"
      if [ -z "$FLAG_RELEASE" ]; then die "--release requires a non-empty value"; fi
      ;;
    *)
      die "Unknown argument: '$1' (see --help)"
      ;;
  esac
  shift
done

# --- Step 2: load .env, apply built-in defaults, then flag overrides ---------
load_env_file "$REPO_ROOT/.env"
apply_defaults

if [ -n "$FLAG_NAMESPACE" ]; then NAMESPACE="$FLAG_NAMESPACE"; fi
if [ -n "$FLAG_RELEASE" ]; then RELEASE_NAME="$FLAG_RELEASE"; fi

# DRY_RUN: --dry-run flag wins; otherwise parse DRY_RUN from .env/environment.
HC_DRY_RUN=0
if [ -n "$FLAG_DRY_RUN" ]; then
  HC_DRY_RUN=1
else
  case "${DRY_RUN:-false}" in
    ""|[Ff][Aa][Ll][Ss][Ee]|0) : ;;
    [Tt][Rr][Uu][Ee]|1) HC_DRY_RUN=1 ;;
    *) die "DRY_RUN must be 'true'/'false' (case-insensitive) or 0/1, got: '$DRY_RUN'" ;;
  esac
fi

# --- Uninstall-only switches (flags win; not part of the shared .env contract:
#     bootstrap never writes them and install/update ignore them) -------------
if [ -n "$FLAG_PURGE_DATA" ]; then
  PURGE_DATA=true
else
  _raw_purge="${PURGE_DATA:-false}"
  if ! PURGE_DATA="$(parse_bool "$_raw_purge")"; then
    die "PURGE_DATA must be 'true' or 'false' (case-insensitive), got: '$_raw_purge'"
  fi
fi
if [ -n "$FLAG_KEEP_SECRETS" ]; then
  KEEP_SECRETS=true
else
  _raw_keep="${KEEP_SECRETS:-false}"
  if ! KEEP_SECRETS="$(parse_bool "$_raw_keep")"; then
    die "KEEP_SECRETS must be 'true' or 'false' (case-insensitive), got: '$_raw_keep'"
  fi
fi
if [ -n "$FLAG_DELETE_NAMESPACE" ]; then
  DELETE_NAMESPACE=true
else
  _raw_delns="${DELETE_NAMESPACE:-false}"
  if ! DELETE_NAMESPACE="$(parse_bool "$_raw_delns")"; then
    die "DELETE_NAMESPACE must be 'true' or 'false' (case-insensitive), got: '$_raw_delns'"
  fi
fi

# --- Derived names -------------------------------------------------------------
SECRET_NAME="${RELEASE_NAME}-secrets"
TLS_SECRET_NAME="$(ingress_tls_secret_name)"
PVC_LABEL="app.kubernetes.io/instance=$RELEASE_NAME"

# --- Step 3: toolchain + cluster checks (skipped in dry-run) ------------------
if [ "$HC_DRY_RUN" != "1" ]; then
  require_cmds helm kubectl
  require_helm
  require_cluster_reachable
fi

log_info "Configuration (built-in defaults < .env < flags):"
log_info "  NAMESPACE=$NAMESPACE  RELEASE_NAME=$RELEASE_NAME"
log_info "  HELM_TIMEOUT=$HELM_TIMEOUT  KUBECONFIG=${KUBECONFIG:-<kubectl default>}"
log_info "  Switches: purge-data=$PURGE_DATA keep-secrets=$KEEP_SECRETS delete-namespace=$DELETE_NAMESPACE"
log_info "  PVC label: $PVC_LABEL"
log_info "  Secrets: $SECRET_NAME, $TLS_SECRET_NAME"
if [ "$HC_DRY_RUN" = "1" ]; then
  log_warn "DRY-RUN: nothing will be executed; the plan and every command are printed below."
fi

# --- Step 4: reject unsafe values before anything is written -----------------
assert_all_values_safe

# --- Helpers --------------------------------------------------------------------
dry_print() { # dry_print ARGS... — print a would-run command in dry-run mode
  log_info "[dry-run] $*"
}

delete_secret_quietly() { # delete_secret_quietly NAME — kubectl delete with
  # --ignore-not-found (idempotent); a failure warns (the release is already
  # gone) instead of aborting. Never prints secret values.
  _dsn="$1"
  if kubectl delete secret "$_dsn" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1; then
    log_ok "Secret '$_dsn' deleted (if it existed)."
  else
    log_warn "Could not delete secret '$_dsn' — remove it manually: kubectl delete secret $_dsn -n $NAMESPACE"
  fi
}

# list_release_pvcs — the release's PVC(s) by the chart's instance label.
# Externally provided claims (persistence.existingClaim) do not carry the
# label and are never touched.
list_release_pvcs() {
  kubectl get pvc -n "$NAMESPACE" -l "$PVC_LABEL" -o name 2>/dev/null || true
}

# --- Step 5: dry-run prints the plan and exits (no cluster access) ------------
if [ "$HC_DRY_RUN" = "1" ]; then
  if [ "$PURGE_DATA" = "true" ]; then
    log_warn "PURGE-DATA: the data volume(s) matching '$PVC_LABEL' would be DELETED — ALL Home Assistant data is lost."
    dry_print "kubectl get pvc -n \"$NAMESPACE\" -l \"$PVC_LABEL\" -o name   # discover the release's PVC(s)"
    dry_print "kubectl delete <PVC(s) from the list above> -n \"$NAMESPACE\" --ignore-not-found"
  else
    log_info "Data preservation: the PVC(s) matching '$PVC_LABEL' would be protected from helm's uninstall:"
    dry_print "kubectl get pvc -n \"$NAMESPACE\" -l \"$PVC_LABEL\" -o name   # discover the release's PVC(s)"
    dry_print "kubectl annotate pvc <PVC(s) from the list above> -n \"$NAMESPACE\" helm.sh/resource-policy=keep --overwrite"
    log_info "Data volume(s) preserved; scripts/install.sh re-adopts them on reinstall (--purge-data deletes them instead)."
  fi
  dry_print "helm uninstall \"$RELEASE_NAME\" -n \"$NAMESPACE\" --wait --timeout \"$HELM_TIMEOUT\""
  if [ "$KEEP_SECRETS" = "true" ]; then
    log_info "Secrets '$SECRET_NAME' and '$TLS_SECRET_NAME' would be kept (--keep-secrets)."
  else
    dry_print "kubectl delete secret \"$SECRET_NAME\" -n \"$NAMESPACE\" --ignore-not-found"
    dry_print "kubectl delete secret \"$TLS_SECRET_NAME\" -n \"$NAMESPACE\" --ignore-not-found"
  fi
  if [ "$DELETE_NAMESPACE" = "true" ]; then
    log_warn "DELETE-NAMESPACE: namespace '$NAMESPACE' would be deleted — everything remaining inside it goes with it."
    dry_print "kubectl delete namespace \"$NAMESPACE\" --ignore-not-found"
  fi
  log_ok "Dry-run complete: no cluster access was performed."
  exit 0
fi

# --- Step 6: release existence (idempotency) ----------------------------------
RELEASE_EXISTS=0
if helm list -n "$NAMESPACE" --short 2>/dev/null | awk -v n="$RELEASE_NAME" '$1 == n { f=1 } END { exit !f }'; then
  RELEASE_EXISTS=1
  log_ok "Helm release '$RELEASE_NAME' found in namespace '$NAMESPACE'."
else
  log_warn "Helm release '$RELEASE_NAME' not found in namespace '$NAMESPACE' — nothing to uninstall."
  log_info "Skipping the uninstall; the requested cleanups still run below."
fi

# --- Step 7: protect the data (default) / uninstall the release ---------------
if [ "$RELEASE_EXISTS" = "1" ]; then
  if [ "$PURGE_DATA" != "true" ]; then
    _pvcs="$(list_release_pvcs)"
    if [ -z "$_pvcs" ]; then
      log_info "No PVCs matching '$PVC_LABEL' — no chart-owned data volume found (an externally provided claim is never touched)."
    else
      log_info "Protecting the data volume(s) from helm's uninstall (helm.sh/resource-policy=keep):"
      # shellcheck disable=SC2086  # PVC names from -o name never contain whitespace
      for _pvc in $_pvcs; do
        if ! kubectl annotate "$_pvc" -n "$NAMESPACE" helm.sh/resource-policy=keep --overwrite >/dev/null 2>&1; then
          die "Could not annotate $_pvc — aborting so the data is NOT deleted. Annotate manually: kubectl annotate $_pvc -n $NAMESPACE helm.sh/resource-policy=keep --overwrite"
        fi
        log_ok "  kept: $_pvc"
      done
    fi
  fi
  log_info "Uninstalling the release (waiting for resources to go, timeout: $HELM_TIMEOUT)..."
  if ! helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" --wait --timeout "$HELM_TIMEOUT"; then
    die "helm uninstall failed for release '$RELEASE_NAME' in namespace '$NAMESPACE'. The release may still exist — inspect with 'helm status $RELEASE_NAME -n $NAMESPACE' and 'kubectl get all -n $NAMESPACE'."
  fi
  log_ok "Helm release '$RELEASE_NAME' uninstalled."
  if [ "$PURGE_DATA" != "true" ]; then
    log_ok "Data volume(s) preserved (helm.sh/resource-policy=keep)."
    log_info "Reinstall with scripts/install.sh — it re-adopts the existing volume."
    log_info "To delete the data volume later: scripts/uninstall.sh --purge-data"
  fi
fi

# --- Step 8: optional data purge (explicit; also cleans orphans) --------------
if [ "$PURGE_DATA" = "true" ]; then
  log_warn "PURGE-DATA: deleting the data volume(s) — ALL Home Assistant data (configuration, users, dashboards, history) is lost."
  _pvcs="$(list_release_pvcs)"
  if [ -z "$_pvcs" ]; then
    log_info "No PVCs matching '$PVC_LABEL' — nothing to delete."
  else
    # shellcheck disable=SC2086  # PVC names from -o name never contain whitespace
    for _pvc in $_pvcs; do
      if kubectl delete "$_pvc" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1; then
        log_ok "Deleted data volume: $_pvc"
      else
        log_warn "Could not delete $_pvc — remove it manually: kubectl delete $_pvc -n $NAMESPACE"
      fi
    done
  fi
fi

# --- Step 9: installer-applied Secrets (helm does not own them) ---------------
if [ "$KEEP_SECRETS" = "true" ]; then
  log_info "Keeping Secrets '$SECRET_NAME' and '$TLS_SECRET_NAME' (--keep-secrets)."
else
  delete_secret_quietly "$SECRET_NAME"
  delete_secret_quietly "$TLS_SECRET_NAME"
fi

# --- Step 10: optional namespace removal (last) -------------------------------
if [ "$DELETE_NAMESPACE" = "true" ]; then
  log_warn "DELETE-NAMESPACE: deleting namespace '$NAMESPACE' — everything remaining inside it is removed with it."
  if kubectl delete namespace "$NAMESPACE" --ignore-not-found >/dev/null 2>&1; then
    log_ok "Namespace '$NAMESPACE' deleted."
  else
    log_warn "Could not delete namespace '$NAMESPACE' — remove it manually: kubectl delete namespace $NAMESPACE"
  fi
fi

log_ok "Home Assistant uninstall complete."
