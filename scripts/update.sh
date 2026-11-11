#!/usr/bin/env bash
# =============================================================================
# scripts/update.sh — update the existing Home Assistant Helm release.
#
# Same configuration/secret/values flow as scripts/install.sh, followed by the
# same idempotent `helm upgrade --install`. Data is preserved (the PVC is
# untouched); afterwards it waits for the rollout, prints the release revision
# history and the `helm rollback` command to revert if needed.
#
# The flow shared with scripts/install.sh (flags, .env/defaults, path
# resolution, tool checks, configuration logging, secret/values preparation
# and the helm upgrade step) lives in scripts/lib/deploy.sh. Only the usage
# text and the three strings passed to deploy_upgrade are script-specific.
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
# shellcheck source=scripts/lib/deploy.sh
. "$REPO_ROOT/scripts/lib/deploy.sh"

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

# --- Shared flow: flags -> .env/defaults -> paths -> tool checks -> logs ------
parse_deploy_flags "$@"
load_deploy_config
resolve_deploy_paths
require_deploy_toolchain
log_deploy_configuration
prepare_deploy

# --- Step 7: helm upgrade --install (shared; dry-run prints and exits) --------
deploy_upgrade \
  "  helm history $RELEASE_NAME -n \"$NAMESPACE\"  # prints revision history + rollback hint" \
  "The previous revision is intact — inspect with 'helm history $RELEASE_NAME -n $NAMESPACE'." \
  "Helm release '$RELEASE_NAME' updated (data on the PVC is untouched)."

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
