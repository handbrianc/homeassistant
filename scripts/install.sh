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
# The flow shared with scripts/update.sh (flags, .env/defaults, path
# resolution, tool checks, configuration logging, secret/values preparation
# and the helm upgrade step) lives in scripts/lib/deploy.sh. Only the usage
# text and the three strings passed to deploy_upgrade are script-specific.
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
# shellcheck source=scripts/lib/deploy.sh
. "$REPO_ROOT/scripts/lib/deploy.sh"

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

# --- Shared flow: flags -> .env/defaults -> paths -> tool checks -> logs ------
parse_deploy_flags "$@"
load_deploy_config
resolve_deploy_paths
require_deploy_toolchain
log_deploy_configuration
prepare_deploy

# --- Step 7: helm upgrade --install (shared; dry-run prints and exits) --------
deploy_upgrade \
  "  kubectl get svc -n \"$NAMESPACE\" -l app.kubernetes.io/instance=$RELEASE_NAME  # prints access URL(s)" \
  "Re-run scripts/install.sh to retry (helm keeps the previous revision)." \
  "Helm release '$RELEASE_NAME' applied."

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
