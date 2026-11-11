# shellcheck shell=bash
# =============================================================================
# scripts/lib/deploy.sh — the deployment flow shared by scripts/install.sh and
# scripts/update.sh
#
# Sourced (never executed) AFTER — and alongside — scripts/lib/common.sh by
# both entry scripts. Owns everything the two flows have in common: flag
# parsing, .env loading with built-in defaults, path resolution,
# toolchain/cluster checks, the configuration log block, values/secret
# preparation and the shared `helm upgrade --install` step (dry-run prints
# and exits 0).
#
# The entry scripts provide the only pieces that differ:
#   usage()    — the script-specific help text (called on -h/--help; define
#                it before parse_deploy_flags runs)
#   deploy_upgrade <dry-run-command-line> <failure-suffix> <success-message>
#              — the script-specific strings of the upgrade step
#
# Portability: bash 3.2+ only (no bash-4-only constructs such as associative
# arrays, and no GNU-only utilities; see common.sh).
# =============================================================================

# The functions below read the effective configuration from variables the
# entry scripts initialise (parse_deploy_flags + load_deploy_config + the
# common.sh defaults); the full variable list is documented in common.sh.
#
# shellcheck disable=SC2154  # entry script owns these; see common.sh block above

# Sourcing path is built at runtime from REPO_ROOT; the directive lets
# `shellcheck -x` follow the library when this file is checked standalone.
# Re-sourcing common.sh here is side-effect-free: both sources run before
# setup_cleanup_trap, so the cleanup-file list is still empty.
# shellcheck source=scripts/lib/common.sh
. "$REPO_ROOT/scripts/lib/common.sh"

# --- Step 1: parse flags (applied later — flags win over .env) ---------------
# parse_deploy_flags ARGS... — parses the flag set shared by install.sh and
# update.sh. Calls the entry script's usage() for -h/--help. Sets
# FLAG_NAMESPACE, FLAG_RELEASE, FLAG_VALUES_EXTRA and FLAG_DRY_RUN.
parse_deploy_flags() {
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
}

# --- Step 2: load .env, apply built-in defaults, then flag overrides ---------
# load_deploy_config — loads REPO_ROOT/.env, applies the built-in defaults and
# overlays the parsed flags (flags win), then resolves HC_DRY_RUN from the
# --dry-run flag or the DRY_RUN environment value (invalid values abort).
load_deploy_config() {
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
}

# --- Resolve repo-relative paths and derived names ---------------------------
# resolve_deploy_paths — resolves CHART_DIR/SECRETS_FILE/VALUES_EXTRA against
# REPO_ROOT (absolute paths pass through), derives SECRET_NAME and validates
# that the chart directory and the extra values file exist.
resolve_deploy_paths() {
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
}

# --- Step 3: toolchain + cluster checks (skipped in dry-run) ------------------
# require_deploy_toolchain — requires helm/kubectl on PATH, a usable helm
# version and a reachable cluster. Entirely skipped in dry-run, which needs
# no toolchain at all.
require_deploy_toolchain() {
  if [ "$HC_DRY_RUN" != "1" ]; then
    require_cmds helm kubectl
    require_helm
    require_cluster_reachable
  fi
}

# --- Configuration log block ---------------------------------------------------
# log_deploy_configuration — prints the effective configuration (secret values
# are never printed) and announces dry-run mode.
log_deploy_configuration() {
  log_info "Configuration (built-in defaults < .env < flags):"
  log_info "  NAMESPACE=$NAMESPACE  RELEASE_NAME=$RELEASE_NAME"
  log_info "  CHART_DIR=$CHART_DIR  HELM_TIMEOUT=$HELM_TIMEOUT  KUBECONFIG=${KUBECONFIG:-<kubectl default>}"
  log_info "  IMAGE_TAG=$IMAGE_TAG  TIMEZONE=$TIMEZONE  NODE_ARCH=${NODE_ARCH:-<any>}"
  log_info "  STORAGE: class=${STORAGE_CLASS:-<cluster default>} size=$STORAGE_SIZE"
  log_info "  SERVICE: type=${SERVICE_TYPE:-<chart default>} port=$SERVICE_PORT lbIP=${LOADBALANCER_IP:-<none>} nodePort=${NODE_PORT:-<none>}"
  log_info "  INGRESS: enabled=$INGRESS_ENABLED class=${INGRESS_CLASS:-<none>} host=${INGRESS_HOST:-<catch-all>} tls=$INGRESS_TLS_ENABLED${INGRESS_TLS_ISSUER:+ issuer=$INGRESS_TLS_ISSUER}${INGRESS_TLS_DNS_NAMES:+ dnsNames=$INGRESS_TLS_DNS_NAMES}"
  log_info "  HOST_NETWORK=$HOST_NETWORK  SECRETS_FILE=$SECRETS_FILE  VALUES_EXTRA=${VALUES_EXTRA:-<none>}"
  if [ "$HC_DRY_RUN" = "1" ]; then
    log_warn "DRY-RUN: nothing will be executed; the generated values and every command are printed below."
  fi
}

# --- Steps 4-6: validate, apply credentials, render the values file -----------
# prepare_deploy — rejects unsafe values, applies the Kubernetes Secret and
# renders the generated values file into a trap-cleaned temp file. Sets
# VALUES_GENERATED for deploy_upgrade and dry_run_render_manifests.
prepare_deploy() {
  # Step 4: reject unsafe values before anything is written
  assert_all_values_safe

  # Step 5: apply credentials as a Kubernetes Secret
  create_or_update_secret

  # Step 6: render the generated values file (trap-cleaned temp file)
  VALUES_GENERATED="$(mktemp "${TMPDIR:-/tmp}/homeassistant-values.XXXXXX")" || die "mktemp failed"
  register_cleanup_file "$VALUES_GENERATED"
  render_values_file "$VALUES_GENERATED"
}

# --- Step 7: helm upgrade --install -------------------------------------------
# deploy_upgrade DRY_RUN_COMMAND_LINE FAILURE_SUFFIX SUCCESS_MESSAGE — builds
# the shared helm arguments and runs the upgrade:
#   - dry-run: prints the generated values and every command that would run
#     (DRY_RUN_COMMAND_LINE is the script-specific trailing command line),
#     renders the full manifests and exits 0 — nothing is executed.
#   - real run: on failure dies with the shared message prefix plus
#     FAILURE_SUFFIX; on success logs SUCCESS_MESSAGE.
deploy_upgrade() {
  _du_dryrun_cmd="$1"
  _du_fail_suffix="$2"
  _du_ok_msg="$3"

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
    log_info "$_du_dryrun_cmd"
    dry_run_render_manifests
    log_ok "Dry-run complete: no cluster access was performed."
    exit 0
  fi

  log_info "Running: $HELM_CMD"
  if ! helm "${HELM_ARGS[@]}"; then
    die "helm upgrade failed for release '$RELEASE_NAME' in namespace '$NAMESPACE'. $_du_fail_suffix"
  fi
  log_ok "$_du_ok_msg"
}
