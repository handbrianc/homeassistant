#!/usr/bin/env bash
# =============================================================================
# scripts/install.sh — install / converge the Home Assistant Helm release.
#
# Reads configuration from .env (see .env.example) plus command-line flags,
# applies credentials as a Kubernetes Secret named <release>-secrets, renders
# a values file from the environment and runs:
#
#   helm upgrade --install <release> charts/homeassistant \
#     --namespace <ns> --create-namespace <rollback-flag> --timeout <t> \
#     -f <generated-values> [--set envFromSecret=...] [--set image.tag=...]
#
# <rollback-flag> is --atomic on helm 3 and --rollback-on-failure on helm 4+
# (helm 4 renamed and deprecated --atomic).
#
# Usage:
#   scripts/install.sh [-h|--help] [--dry-run] [--namespace NS]
#                      [--release NAME] [--values FILE]
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
Usage: scripts/install.sh [options]

Installs or converges the Home Assistant Helm release (chart:
charts/homeassistant) using configuration from .env (see .env.example).

Options:
  -h, --help          Show this help and exit.
      --dry-run       Print the generated Helm values file and every
                      helm/kubectl command without touching the cluster
                      (also honors DRY_RUN=1 in the environment or .env).
      --namespace NS  Override NAMESPACE from .env.
      --release NAME  Override RELEASE_NAME from .env.
      --values FILE   Extra Helm values file, applied last (overrides
                      VALUES_EXTRA from .env).

Configuration precedence: built-in defaults < .env < command-line flags.
Credentials come from secrets.env (see secrets.env.example) and are applied
as the Kubernetes Secret '<release>-secrets'; secret values are never printed.
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
  log_info "  kubectl get svc -n \"$NAMESPACE\" -l app.kubernetes.io/instance=$RELEASE_NAME  # prints access URL(s)"
  dry_run_render_manifests
  log_ok "Dry-run complete: no cluster access was performed."
  exit 0
fi

log_info "Running: $HELM_CMD"
if ! helm "${HELM_ARGS[@]}"; then
  die "helm upgrade failed for release '$RELEASE_NAME' in namespace '$NAMESPACE'. Re-run scripts/install.sh to retry (helm keeps the previous revision)."
fi
log_ok "Helm release '$RELEASE_NAME' applied."

# --- Step 8: wait for the rollout ---------------------------------------------
wait_for_rollout

# --- Step 9: print access URL(s) and post-install pointers ---------------------
print_access_urls() {
  _pau_svc_out="$(kubectl get svc -n "$NAMESPACE" -l "app.kubernetes.io/instance=$RELEASE_NAME" 2>/dev/null)" || _pau_svc_out=""
  if [ -z "$_pau_svc_out" ]; then
    log_warn "Could not list Services (kubectl get svc failed) — check the release with 'helm status $RELEASE_NAME -n $NAMESPACE'."
    return 0
  fi
  printf '%s\n' "$_pau_svc_out" | tail -n +2 | while read -r _pau_name _pau_type _pau_cip _pau_ext _pau_ports _pau_rest; do
    case "$_pau_type" in
      LoadBalancer)
        _pau_port="$_pau_ports"
        case "$_pau_port" in *:*) _pau_port="${_pau_port%%:*}" ;; esac
        case "$_pau_port" in */*) _pau_port="${_pau_port%%/*}" ;; esac
        case "$_pau_ext" in
          ""|"<pending>"*)
            log_warn "  LoadBalancer $_pau_name: external IP is still <pending>."
            log_info "  On k3s, klipper-lb binds the node IP within seconds — re-run 'kubectl get svc -n $NAMESPACE' to see it."
            case "$_pau_ports" in
              *:*)
                _pau_np="${_pau_ports#*:}"
                _pau_np="${_pau_np%%/*}"
                log_info "  Meanwhile (node port): http://<node-ip>:$_pau_np"
                ;;
            esac
            ;;
          *)
            log_ok "  http://${_pau_ext}:${_pau_port}"
            ;;
        esac
        ;;
      NodePort)
        case "$_pau_ports" in
          *:*)
            _pau_np="${_pau_ports#*:}"
            _pau_np="${_pau_np%%/*}"
            log_info "  NodePort service $_pau_name: http://<node-ip>:$_pau_np (node IPs: kubectl get nodes -o wide)"
            ;;
        esac
        ;;
      ClusterIP)
        if [ -z "$_pau_ports" ] || [ "$_pau_ports" = "<none>" ]; then
          continue  # headless service — not user-facing
        fi
        _pau_p="${_pau_ports%%/*}"
        log_info "  ClusterIP service $_pau_name — port-forward to reach it locally:"
        log_info "    kubectl port-forward svc/$_pau_name 8123:$_pau_p -n $NAMESPACE  # then open http://localhost:8123"
        ;;
      *)
        : ;;
    esac
  done
  if [ "$(parse_bool "$INGRESS_ENABLED")" = "true" ]; then
    if [ -n "$INGRESS_HOST" ]; then
      log_ok "  Ingress: https://$INGRESS_HOST"
    else
      log_info "  Ingress (catch-all rule): https://<ingress-controller-address> — point any hostname at the ingress controller's external address"
    fi
  fi
}

print_access_urls
log_ok "Home Assistant installation complete."

log_info "Next steps:"
log_info "  - Open Home Assistant at the URL(s) above (frontend answers on / without auth)."
log_info "  - Smoke-test the release:  helm test $RELEASE_NAME -n $NAMESPACE"
log_info "  - Update later with:       scripts/update.sh"
log_info "  - Preview changes with:    DRY_RUN=1 $REPO_ROOT/scripts/install.sh"
log_info "  - Credentials env:         Kubernetes Secret '$SECRET_NAME' (from $SECRETS_FILE); referenced in configuration.yaml via !env_var."
