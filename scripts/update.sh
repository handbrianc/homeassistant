#!/usr/bin/env bash
# =============================================================================
# scripts/update.sh — update the existing Home Assistant Helm release.
#
# Same configuration/secret/values flow as scripts/install.sh, followed by the
# same idempotent `helm upgrade --install`. Data is preserved (the PVC is
# untouched); afterwards it waits for the rollout, prints the release revision
# history and the `helm rollback` command to revert if needed.
#
# Usage:
#   scripts/update.sh [-h|--help] [--dry-run] [--namespace NS]
#                     [--release NAME] [--values FILE]
#
# Dry-run (also via DRY_RUN=1) prints the generated values and every
# helm/kubectl command and needs no cluster or toolchain.
#
# Configuration precedence: built-in defaults < .env < command-line flags.
# Secret values are never printed.
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

setup_cleanup_trap

usage() {
  cat <<'EOF'
Usage: scripts/update.sh [options]

Updates the existing Home Assistant Helm release (chart: charts/homeassistant)
using configuration from .env (see .env.example). Same idempotent
`helm upgrade --install` as install.sh; data on the PVC is preserved.

Options:
  -h, --help          Show this help and exit.
      --dry-run       Print the generated Helm values file and every
                      helm/kubectl command without touching the cluster
                      (also honors DRY_RUN=1 in the environment or .env).
      --namespace NS  Override NAMESPACE from .env.
      --release NAME  Override RELEASE_NAME from .env.
      --values FILE   Extra Helm values file, applied last (overrides
                      VALUES_EXTRA from .env).

After the update the script prints the release revision history and the
`helm rollback <release> <previous-revision>` command to revert.
EOF
}

# --- Step 1: parse flags (applied later — flags win over .env) ---------------
FLAG_NAMESPACE=""
FLAG_RELEASE=""
FLAG_VALUES_EXTRA=""
FLAG_DRY_RUN=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --dry-run)
      FLAG_DRY_RUN=1
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
    --values)
      if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then die "--values requires a non-empty argument"; fi
      FLAG_VALUES_EXTRA="$2"
      shift
      ;;
    --values=*)
      FLAG_VALUES_EXTRA="${1#--values=}"
      if [ -z "$FLAG_VALUES_EXTRA" ]; then die "--values requires a non-empty value"; fi
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
if [ -n "$FLAG_VALUES_EXTRA" ]; then VALUES_EXTRA="$FLAG_VALUES_EXTRA"; fi

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

# --- Resolve repo-relative paths and derived names ---------------------------
SECRET_NAME="${RELEASE_NAME}-secrets"
CHART_DIR="$(resolve_repo_path "$CHART_DIR")"
SECRETS_FILE="$(resolve_repo_path "$SECRETS_FILE")"
if [ -n "$VALUES_EXTRA" ]; then
  VALUES_EXTRA="$(resolve_repo_path "$VALUES_EXTRA")"
fi

if [ ! -d "$CHART_DIR" ]; then
  die "Chart directory not found: $CHART_DIR (expected the Helm chart from this repository)"
fi
if [ -n "$VALUES_EXTRA" ] && [ ! -f "$VALUES_EXTRA" ]; then
  die "VALUES_EXTRA file not found: $VALUES_EXTRA"
fi

# --- Step 3: toolchain + cluster checks (skipped in dry-run) ------------------
if [ "$HC_DRY_RUN" != "1" ]; then
  require_cmds helm kubectl
  require_helm
  require_cluster_reachable
fi

log_info "Configuration (built-in defaults < .env < flags):"
log_info "  NAMESPACE=$NAMESPACE  RELEASE_NAME=$RELEASE_NAME"
log_info "  CHART_DIR=$CHART_DIR  HELM_TIMEOUT=$HELM_TIMEOUT  KUBECONFIG=${KUBECONFIG:-<kubectl default>}"
log_info "  IMAGE_TAG=$IMAGE_TAG  TIMEZONE=$TIMEZONE  NODE_ARCH=${NODE_ARCH:-<any>}"
log_info "  STORAGE: class=${STORAGE_CLASS:-<cluster default>} size=$STORAGE_SIZE"
log_info "  SERVICE: type=$SERVICE_TYPE port=$SERVICE_PORT lbIP=${LOADBALANCER_IP:-<none>} nodePort=${NODE_PORT:-<none>}"
log_info "  INGRESS: enabled=$INGRESS_ENABLED class=${INGRESS_CLASS:-<none>} host=${INGRESS_HOST:-<catch-all>} tls=$INGRESS_TLS_ENABLED${INGRESS_TLS_ISSUER:+ issuer=$INGRESS_TLS_ISSUER}"
log_info "  HOST_NETWORK=$HOST_NETWORK  SECRETS_FILE=$SECRETS_FILE  VALUES_EXTRA=${VALUES_EXTRA:-<none>}"
if [ "$HC_DRY_RUN" = "1" ]; then
  log_warn "DRY-RUN: nothing will be executed; the generated values and every command are printed below."
fi

# --- Step 4: reject unsafe values before anything is written -----------------
assert_all_values_safe

# --- Step 5: apply credentials as a Kubernetes Secret -------------------------
create_or_update_secret
create_or_update_tls_secret

# --- Step 6: render the generated values file (trap-cleaned temp file) --------
VALUES_GENERATED="$(mktemp "${TMPDIR:-/tmp}/homeassistant-values.XXXXXX")" || die "mktemp failed"
register_cleanup_file "$VALUES_GENERATED"
render_values_file "$VALUES_GENERATED"

# --- Step 7: helm upgrade --install -------------------------------------------
helm_release_args "$VALUES_GENERATED" "$VALUES_EXTRA"
HELM_CMD="$(print_helm_cmd)"

if [ "$HC_DRY_RUN" = "1" ]; then
  log_info "Generated Helm values file (would be passed via -f, temp file: $VALUES_GENERATED):"
  printf '%s\n' "----- BEGIN generated values -----"
  cat "$VALUES_GENERATED"
  printf '%s\n' "----- END generated values -----"
  log_info "Commands that would run (in order):"
  log_info "  (kubectl secret pipeline is printed by the secrets step above, when applicable)"
  log_info "  $HELM_CMD"
  log_info "  kubectl rollout status statefulset/<release-statefulset> -n \"$NAMESPACE\" --timeout=\"$HELM_TIMEOUT\"  # statefulset resolved at runtime via label app.kubernetes.io/instance=$RELEASE_NAME"
  log_info "  helm history $RELEASE_NAME -n \"$NAMESPACE\"  # prints revision history + rollback hint"
  dry_run_render_manifests
  log_ok "Dry-run complete: no cluster access was performed."
  exit 0
fi

log_info "Running: $HELM_CMD"
if ! helm "${HELM_ARGS[@]}"; then
  die "helm upgrade failed for release '$RELEASE_NAME' in namespace '$NAMESPACE'. The previous revision is intact — inspect with 'helm history $RELEASE_NAME -n $NAMESPACE'."
fi
log_ok "Helm release '$RELEASE_NAME' updated (data on the PVC is untouched)."

# --- Step 8: wait for the rollout ---------------------------------------------
wait_for_rollout

# --- Step 9: revision history, rollback hint, values tip -----------------------
print_update_status() {
  _pus_hist="$(helm history "$RELEASE_NAME" -n "$NAMESPACE" --max 10 2>/dev/null)" || _pus_hist=""
  if [ -z "$_pus_hist" ]; then
    log_warn "Could not read the release history — check with 'helm history $RELEASE_NAME -n $NAMESPACE'."
    return 0
  fi
  log_info "Release revision history (helm history $RELEASE_NAME -n $NAMESPACE):"
  printf '%s\n' "$_pus_hist"
  _pus_last="$(printf '%s\n' "$_pus_hist" | tail -n 1)"
  _pus_rev="$(printf '%s\n' "$_pus_last" | awk '{print $1}')"
  case "$_pus_rev" in
    ''|*[!0-9]*)
      log_info "Rollback if needed:  helm rollback $RELEASE_NAME <previous-revision> -n $NAMESPACE"
      ;;
    *)
      if [ "$_pus_rev" -le 1 ]; then
        log_info "This is revision 1 — nothing to roll back to yet."
      else
        _pus_prev=$((_pus_rev - 1))
        log_info "Rollback if the update misbehaves:  helm rollback $RELEASE_NAME $_pus_prev -n $NAMESPACE"
      fi
      ;;
  esac
}

print_update_status

log_info "Inspect what was applied:"
log_info "  helm get values $RELEASE_NAME -n $NAMESPACE          # user-supplied values"
log_info "  helm get values $RELEASE_NAME -n $NAMESPACE --all    # including chart defaults"
log_info "Data note: the PVC is not touched by updates or rollbacks; rollbacks revert the workload only."
log_ok "Home Assistant update complete."
