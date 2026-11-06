# shellcheck shell=bash
# =============================================================================
# scripts/lib/common.sh — shared library for scripts/install.sh, scripts/update.sh
#
# Sourced (never executed) AFTER the entry script sets `set -Eeuo pipefail`.
# Provides: logging, die, require_cmds, env loading, defaults, YAML-safety
# assertions, generated-values rendering, Kubernetes Secret apply, the shared
# helm argument builder, rollout wait and trap-based temp-file cleanup.
#
# Portability: bash 3.2+ only (no bash-4-only constructs such as associative
# arrays, bulk line-reading builtins or case-modification parameter expansions,
# and no negative-offset substring operators), no GNU-only utilities.
# =============================================================================

# The helpers below read the effective configuration from variables the entry
# scripts initialise (load_env_file + apply_defaults + flag overrides):
#
#   KUBECONFIG NAMESPACE RELEASE_NAME CHART_DIR HELM_TIMEOUT VALUES_EXTRA
#   IMAGE_TAG TIMEZONE NODE_ARCH STORAGE_CLASS STORAGE_SIZE SERVICE_TYPE
#   SERVICE_PORT LOADBALANCER_IP NODE_PORT INGRESS_ENABLED INGRESS_CLASS
#   INGRESS_HOST HOST_NETWORK SECRETS_FILE DRY_RUN HC_DRY_RUN SECRET_NAME
#   ENV_FROM_SECRET
#
# shellcheck disable=SC2154  # entry script owns these; see block above

# --- Logging (printf-based, NO_COLOR-aware, warn/error -> stderr) ------------
_HC_COLOR=0
_HC_RESET='' _HC_BLUE='' _HC_GREEN='' _HC_YELLOW='' _HC_RED=''
if [ -z "${NO_COLOR:-}" ] && { [ -t 1 ] || [ -t 2 ]; }; then
  _HC_COLOR=1
  _HC_RESET=$'\033[0m'
  _HC_BLUE=$'\033[0;34m'
  _HC_GREEN=$'\033[0;32m'
  _HC_YELLOW=$'\033[0;33m'
  _HC_RED=$'\033[0;31m'
fi

_hc_log() { # $1 = color, $2 = tag, $3 = message
  if [ "$_HC_COLOR" = "1" ]; then
    printf '%s\n' "${1}[${2}]${_HC_RESET} ${3}"
  else
    printf '%s\n' "[${2}] ${3}"
  fi
}
log_info()  { _hc_log "$_HC_BLUE"   "info"  "$*"; }
log_ok()    { _hc_log "$_HC_GREEN"  "ok"    "$*"; }
log_warn()  { _hc_log "$_HC_YELLOW" "warn"  "$*" >&2; }
log_error() { _hc_log "$_HC_RED"    "error" "$*" >&2; }

die() {
  log_error "$*"
  exit 1
}

# --- Toolchain prerequisites (skipped entirely in dry-run) -------------------
require_cmds() {
  if [ "${HC_DRY_RUN:-0}" = "1" ]; then
    return 0
  fi
  _rq_missing=0
  for _rq_cmd in "$@"; do
    if command -v "$_rq_cmd" >/dev/null 2>&1; then
      continue
    fi
    log_error "Required command not found: $_rq_cmd"
    case "$_rq_cmd" in
      helm)
        log_error "  hint: scripts/install-prereqs.sh installs it — or: get-helm-4 script (Linux) / brew install helm (macOS/Homebrew)"
        ;;
      kubectl)
        log_error "  hint: scripts/install-prereqs.sh installs it — or: dl.k8s.io binary (Linux) / brew install kubectl (macOS/Homebrew)"
        ;;
      bash)
        log_error "  hint: brew install bash       (macOS/Homebrew; scripts need bash 3.2+)"
        ;;
      *)
        log_error "  hint: apt install $_rq_cmd  (Linux)  |  brew install $_rq_cmd (macOS/Homebrew)"
        ;;
    esac
    _rq_missing=1
  done
  if [ "$_rq_missing" = "1" ]; then
    log_error "One-line macOS install for all tooling: brew install helm kubectl bash"
    die "Install the missing tools and re-run."
  fi
}

require_helm() {
  _hv="$(helm version --short 2>/dev/null || true)"
  case "${_hv:-}" in
    v3.*|v4.*)
      HC_HELM_MAJOR="${_hv%%.*}"
      HC_HELM_MAJOR="${HC_HELM_MAJOR#v}"
      log_info "helm version: ${_hv%% *}"
      ;;
    "")
      die "Could not determine the helm version (helm v3+ required). Is 'helm' on PATH?"
      ;;
    *)
      die "helm v3+ is required, found: '${_hv%% *}'. Update helm (get-helm-4 script / snap / brew install helm)."
      ;;
  esac
}

# helm_major_version — prints the detected helm major version ("3", "4", ...).
# Prefers HC_HELM_MAJOR (cached by require_helm); otherwise parses a live
# `helm version --short`. Prints nothing when helm is absent or its version
# cannot be parsed — callers treat that as "use the helm 4+ flag names".
helm_major_version() {
  if [ -n "${HC_HELM_MAJOR:-}" ]; then
    printf '%s\n' "$HC_HELM_MAJOR"
    return 0
  fi
  _hmv="$(helm version --short 2>/dev/null || true)"
  case "$_hmv" in
    v3.*) printf '3\n' ;;
    v4.*) printf '4\n' ;;
  esac
}

require_cluster_reachable() {
  log_info "Checking cluster reachability (kubectl get nodes)..."
  if ! kubectl get nodes --request-timeout=15s >/dev/null 2>&1; then
    log_error "Kubernetes cluster is not reachable: 'kubectl get nodes' failed."
    log_error "Check your kubeconfig (KUBECONFIG: ${KUBECONFIG:-<kubectl default resolution>}) and cluster access, then retry."
    exit 1
  fi
  log_ok "Cluster reachable."
}

# --- Environment-file loading and defaults -----------------------------------
# load_env_file PATH — sources a KEY=VALUE file with `set -a` so the values are
# exported (KUBECONFIG needs to reach kubectl/helm). Missing file -> warn,
# continue with built-in defaults.
load_env_file() {
  _lef_file="${1:-}"
  if [ -n "$_lef_file" ] && [ -f "$_lef_file" ]; then
    log_info "Loading environment file: $_lef_file"
    set -a
    # shellcheck disable=SC1090
    . "$_lef_file"
    set +a
  else
    log_warn "Environment file '${_lef_file:-<none>}' not found — continuing with built-in defaults (see .env.example)."
  fi
}

# apply_defaults — mirrors every variable documented in .env.example.
apply_defaults() {
  # --- Kubernetes target
  : "${KUBECONFIG:=}"
  : "${NAMESPACE:=homeassistant}"
  # --- Helm release
  : "${RELEASE_NAME:=homeassistant}"
  : "${CHART_DIR:=charts/homeassistant}"
  : "${HELM_TIMEOUT:=10m}"
  : "${VALUES_EXTRA:=}"
  # --- Container image
  : "${IMAGE_TAG:=2026.11.0}"
  # --- Workload configuration
  : "${TIMEZONE:=UTC}"
  : "${NODE_ARCH:=}"
  # --- Persistence
  : "${STORAGE_CLASS:=}"
  : "${STORAGE_SIZE:=5Gi}"
  # --- Exposure
  : "${SERVICE_TYPE:=LoadBalancer}"
  : "${SERVICE_PORT:=8123}"
  : "${LOADBALANCER_IP:=}"
  : "${NODE_PORT:=}"
  : "${INGRESS_ENABLED:=false}"
  : "${INGRESS_CLASS:=}"
  : "${INGRESS_HOST:=}"
  : "${HOST_NETWORK:=false}"
  # --- Secrets
  : "${SECRETS_FILE:=secrets.env}"
  # Dry-run switch (set by --dry-run flag or DRY_RUN=1 in the environment).
  : "${DRY_RUN:=0}"
}

# --- Value validation ---------------------------------------------------------
# parse_bool VALUE — prints true/false (normalised, case-insensitive) on
# stdout; returns 1 when VALUE is neither.
parse_bool() {
  case "$1" in
    [Tt][Rr][Uu][Ee])     printf 'true\n' ;;
    [Ff][Aa][Ll][Ss][Ee]) printf 'false\n' ;;
    *) return 1 ;;
  esac
}

# assert_yaml_safe VAR VALUE — aborts (naming the variable) when VALUE contains
# a double quote, single quote, backslash, backtick, newline, carriage return
# or dollar sign: any of these would break the generated values YAML or helm's
# --set parser.
assert_yaml_safe() {
  _ays_var="$1"
  _ays_value="$2"
  case "$_ays_value" in
    *'"'*)   die "Unsafe value in \$$_ays_var: contains a double quote (\") — aborted to avoid broken YAML." ;;
    *"'"*)   die "Unsafe value in \$$_ays_var: contains a single quote (') — aborted to avoid broken YAML." ;;
    *$'\\'*) die "Unsafe value in \$$_ays_var: contains a backslash (\\) — aborted to avoid broken YAML." ;;
    *'`'*)   die "Unsafe value in \$$_ays_var: contains a backtick (\`) — aborted to avoid broken YAML." ;;
    *'$'*)   die "Unsafe value in \$$_ays_var: contains a dollar sign (\$) — aborted to avoid broken YAML." ;;
    *$'\n'*) die "Unsafe value in \$$_ays_var: contains a newline — aborted to avoid broken YAML." ;;
    *$'\r'*) die "Unsafe value in \$$_ays_var: contains a carriage return — aborted to avoid broken YAML." ;;
  esac
}

# assert_int VAR VALUE — aborts when VALUE is not a plain integer.
assert_int() {
  case "$2" in
    ''|*[!0-9]*) die "\$$1 must be an integer, got: '$2'" ;;
  esac
}

# Asserts every value the scripts interpolate into the generated values file
# or pass to helm/kubectl.
assert_all_values_safe() {
  assert_yaml_safe NAMESPACE        "$NAMESPACE"
  assert_yaml_safe RELEASE_NAME     "$RELEASE_NAME"
  assert_yaml_safe SECRET_NAME      "${SECRET_NAME:-}"
  assert_yaml_safe CHART_DIR        "$CHART_DIR"
  assert_yaml_safe HELM_TIMEOUT     "$HELM_TIMEOUT"
  assert_yaml_safe IMAGE_TAG        "$IMAGE_TAG"
  assert_yaml_safe TIMEZONE         "$TIMEZONE"
  assert_yaml_safe NODE_ARCH        "$NODE_ARCH"
  assert_yaml_safe STORAGE_CLASS    "$STORAGE_CLASS"
  assert_yaml_safe STORAGE_SIZE     "$STORAGE_SIZE"
  assert_yaml_safe SERVICE_TYPE     "$SERVICE_TYPE"
  assert_yaml_safe SERVICE_PORT     "$SERVICE_PORT"
  assert_yaml_safe LOADBALANCER_IP  "$LOADBALANCER_IP"
  assert_yaml_safe NODE_PORT        "$NODE_PORT"
  assert_yaml_safe INGRESS_ENABLED  "$INGRESS_ENABLED"
  assert_yaml_safe INGRESS_CLASS    "$INGRESS_CLASS"
  assert_yaml_safe INGRESS_HOST     "$INGRESS_HOST"
  assert_yaml_safe HOST_NETWORK     "$HOST_NETWORK"
  assert_yaml_safe SECRETS_FILE     "$SECRETS_FILE"
  assert_yaml_safe VALUES_EXTRA     "$VALUES_EXTRA"
  assert_yaml_safe ENV_FROM_SECRET  "${ENV_FROM_SECRET:-}"
}

# --- Path helpers --------------------------------------------------------------
# resolve_repo_path PATH — resolves a relative path against REPO_ROOT;
# absolute paths pass through unchanged.
resolve_repo_path() {
  _rrp_value="$1"
  case "$_rrp_value" in
    /*) printf '%s\n' "$_rrp_value" ;;
    *)  printf '%s\n' "$REPO_ROOT/$_rrp_value" ;;
  esac
}

# --- Temporary-file management (trap-based) -----------------------------------
# Newline-separated list of files removed on exit.
HC_CLEANUP_FILES=""

register_cleanup_file() {
  if [ -n "$1" ]; then
    if [ -n "$HC_CLEANUP_FILES" ]; then
      HC_CLEANUP_FILES="$HC_CLEANUP_FILES
$1"
    else
      HC_CLEANUP_FILES="$1"
    fi
  fi
}

cleanup_files() {
  if [ -n "$HC_CLEANUP_FILES" ]; then
    printf '%s\n' "$HC_CLEANUP_FILES" | while IFS= read -r _cf_file; do
      if [ -n "$_cf_file" ] && [ -f "$_cf_file" ]; then
        rm -f "$_cf_file" 2>/dev/null || true
      fi
    done
    HC_CLEANUP_FILES=""
  fi
}

setup_cleanup_trap() {
  trap 'cleanup_files' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

# --- Kubernetes Secret apply ---------------------------------------------------
# create_or_update_secret — applies SECRETS_FILE as the Secret named
# SECRET_NAME in NAMESPACE via a client-side dry run piped to kubectl apply.
# Never prints secret values. Sets ENV_FROM_SECRET to the secret name, or ""
# (with a warning) when the secrets file is missing/empty/unreadable.
create_or_update_secret() {
  if [ -z "$SECRETS_FILE" ] || [ ! -f "$SECRETS_FILE" ] || [ ! -r "$SECRETS_FILE" ]; then
    log_warn "Secrets file not found or not readable: '${SECRETS_FILE:-}'"
    log_warn "Continuing WITHOUT a Kubernetes Secret (envFromSecret='') — the pod will not wait on a missing Secret."
    log_warn "Create one from secrets.env.example to inject credentials."
    ENV_FROM_SECRET=""
  elif ! grep -Eq '^[^#[:space:]]' "$SECRETS_FILE"; then
    log_warn "Secrets file has no KEY=VALUE entries (comments only): '$SECRETS_FILE'"
    log_warn "Continuing WITHOUT a Kubernetes Secret (envFromSecret='')."
    ENV_FROM_SECRET=""
  else
    ENV_FROM_SECRET="$SECRET_NAME"
    if [ "${HC_DRY_RUN:-0}" = "1" ]; then
      log_info "[dry-run] kubectl create secret generic \"$SECRET_NAME\" --from-env-file=\"$SECRETS_FILE\" --dry-run=client -o yaml | kubectl apply -f - -n \"$NAMESPACE\""
    else
      log_info "Applying Kubernetes Secret '$SECRET_NAME' in namespace '$NAMESPACE' (values are never printed)..."
      if ! kubectl create secret generic "$SECRET_NAME" --from-env-file="$SECRETS_FILE" --dry-run=client -o yaml |
           kubectl apply -f - -n "$NAMESPACE"; then
        die "Failed to create/update Secret '$SECRET_NAME' in namespace '$NAMESPACE'."
      fi
      log_ok "Secret '$SECRET_NAME' applied."
    fi
  fi
  assert_yaml_safe ENV_FROM_SECRET "$ENV_FROM_SECRET"
}

# --- Generated values file ------------------------------------------------------
# render_values_file OUTFILE — writes the generated Helm values (YAML) from the
# effective environment, per the shared env -> values mapping contract
# (design.md). Only non-empty variables are emitted; true/false values are
# parsed case-insensitively.
render_values_file() {
  _rvf_out="$1"
  _rvf_ingress_enabled=0
  _rvf_host_network=0

  if ! _rvf_ingress_enabled="$(parse_bool "$INGRESS_ENABLED")"; then
    die "INGRESS_ENABLED must be 'true' or 'false' (case-insensitive), got: '$INGRESS_ENABLED'"
  fi
  if ! _rvf_host_network="$(parse_bool "$HOST_NETWORK")"; then
    die "HOST_NETWORK must be 'true' or 'false' (case-insensitive), got: '$HOST_NETWORK'"
  fi
  if [ -n "$SERVICE_PORT" ]; then
    assert_int SERVICE_PORT "$SERVICE_PORT"
  fi
  if [ -n "$NODE_PORT" ]; then
    assert_int NODE_PORT "$NODE_PORT"
  fi

  {
    printf '%s\n' "# Generated values file — written by scripts/install.sh / scripts/update.sh."
    printf '%s\n' "# Source of truth: environment (.env / command-line flags); edit those, not this file."
    printf '%s\n' ""
    printf '%s\n' "image:"
    printf '  tag: "%s"\n' "$IMAGE_TAG"
    printf '%s\n' ""
    printf 'timezone: "%s"\n' "$TIMEZONE"
    if [ -n "$STORAGE_CLASS" ] || [ -n "$STORAGE_SIZE" ]; then
      printf '%s\n' ""
      printf '%s\n' "persistence:"
      if [ -n "$STORAGE_CLASS" ]; then printf '  storageClass: "%s"\n' "$STORAGE_CLASS"; fi
      if [ -n "$STORAGE_SIZE" ]; then printf '  size: "%s"\n' "$STORAGE_SIZE"; fi
    fi
    if [ -n "$SERVICE_TYPE" ] || [ -n "$SERVICE_PORT" ] || [ -n "$LOADBALANCER_IP" ] || [ -n "$NODE_PORT" ]; then
      printf '%s\n' ""
      printf '%s\n' "service:"
      if [ -n "$SERVICE_TYPE" ]; then printf '  type: "%s"\n' "$SERVICE_TYPE"; fi
      if [ -n "$SERVICE_PORT" ]; then printf '  port: %s\n' "$SERVICE_PORT"; fi
      if [ -n "$LOADBALANCER_IP" ]; then printf '  loadBalancerIP: "%s"\n' "$LOADBALANCER_IP"; fi
      if [ -n "$NODE_PORT" ]; then printf '  nodePort: %s\n' "$NODE_PORT"; fi
    fi
    printf '%s\n' ""
    printf '%s\n' "ingress:"
    printf '  enabled: %s\n' "$_rvf_ingress_enabled"
    if [ -n "$INGRESS_CLASS" ]; then printf '  className: "%s"\n' "$INGRESS_CLASS"; fi
    if [ -n "$INGRESS_HOST" ]; then
      printf '%s\n' "  hosts:"
      printf '    - host: "%s"\n' "$INGRESS_HOST"
      printf '%s\n' "      paths:"
      printf '%s\n' "        - path: /"
      printf '%s\n' "          pathType: Prefix"
    fi
    printf '%s\n' ""
    printf 'hostNetwork: %s\n' "$_rvf_host_network"
    if [ "$_rvf_host_network" = "true" ]; then
      printf 'dnsPolicy: "%s"\n' "ClusterFirstWithHostNet"
    fi
    if [ -n "$NODE_ARCH" ]; then
      printf '%s\n' ""
      printf '%s\n' "nodeSelector:"
      printf '  kubernetes.io/arch: "%s"\n' "$NODE_ARCH"
    fi
    printf '%s\n' ""
    printf 'envFromSecret: "%s"\n' "${ENV_FROM_SECRET:-}"
  } > "$_rvf_out"
}

# --- Shared helm invocation ------------------------------------------------------
# helm_release_args GENERATED_VALUES_FILE [EXTRA_VALUES_FILE]
# Fills the global (bash 3.2-compatible, indexed) array HELM_ARGS with the
# shared `helm upgrade --install` arguments. The rollback flag follows the
# detected helm generation: --atomic on helm 3, --rollback-on-failure on
# helm 4+ (--atomic is deprecated there) and when helm is undetectable.
helm_release_args() {
  _hra_generated="$1"
  _hra_extra="${2:-}"
  HELM_ARGS=()
  HELM_ARGS+=("upgrade" "--install" "$RELEASE_NAME" "$CHART_DIR")
  HELM_ARGS+=("--namespace" "$NAMESPACE")
  HELM_ARGS+=("--create-namespace")
  case "$(helm_major_version)" in
    3) HELM_ARGS+=("--atomic") ;;
    *) HELM_ARGS+=("--rollback-on-failure") ;;
  esac
  HELM_ARGS+=("--timeout" "$HELM_TIMEOUT")
  HELM_ARGS+=("-f" "$_hra_generated")
  if [ -n "$_hra_extra" ]; then
    HELM_ARGS+=("-f" "$_hra_extra")
  fi
  HELM_ARGS+=("--set" "envFromSecret=$ENV_FROM_SECRET")
  HELM_ARGS+=("--set" "image.tag=$IMAGE_TAG")
}

# print_helm_cmd — prints the full helm command line for display (dry-run logs,
# "Running:" lines). Only for display; execution uses "${HELM_ARGS[@]}".
print_helm_cmd() {
  printf 'helm'
  printf ' %s' "${HELM_ARGS[@]}"
  printf '\n'
}

# --- Rollout wait ------------------------------------------------------------------
# wait_for_rollout — waits for the release's StatefulSet rollout, found via the
# standard helm label app.kubernetes.io/instance=<release>.
wait_for_rollout() {
  _wfs_sts="$(kubectl get statefulset -n "$NAMESPACE" \
                -l "app.kubernetes.io/instance=$RELEASE_NAME" -o name 2>/dev/null |
              head -n 1 | tr -d '\n')" || _wfs_sts=""
  _wfs_name=""
  case "$_wfs_sts" in
    statefulset.apps/*) _wfs_name="${_wfs_sts#statefulset.apps/}" ;;
    statefulset/*)      _wfs_name="${_wfs_sts#statefulset/}" ;;
    "")                 _wfs_name="" ;;
    *)                  _wfs_name="$_wfs_sts" ;;
  esac
  if [ -z "$_wfs_name" ]; then
    log_warn "Could not find a StatefulSet for release '$RELEASE_NAME' (label app.kubernetes.io/instance=$RELEASE_NAME); skipping rollout wait."
    return 0
  fi
  log_info "Waiting for StatefulSet rollout: statefulset/$_wfs_name (timeout: $HELM_TIMEOUT)..."
  if ! kubectl rollout status "statefulset/$_wfs_name" -n "$NAMESPACE" --timeout="$HELM_TIMEOUT"; then
    log_error "Rollout of statefulset/$_wfs_name failed or timed out."
    die "Inspect with: kubectl -n $NAMESPACE describe statefulset/$_wfs_name  (and: kubectl -n $NAMESPACE logs)"
  fi
  log_ok "Rollout complete."
}
