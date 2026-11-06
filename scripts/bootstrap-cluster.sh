#!/usr/bin/env bash
# =============================================================================
# scripts/bootstrap-cluster.sh — bootstrap cluster access + cluster-aware .env
#
# Three stages:
#   1. Access    — passwordless SSH from this host to the control plane
#                  (--host [user@]ip), fetch /etc/rancher/k3s/k3s.yaml (scp,
#                  'sudo cat' fallback), rewrite the server URL to the
#                  control-plane address, install the kubeconfig and validate
#                  cluster access with kubectl.
#   2. Review    — query the cluster for sane chart values: node architecture,
#                  default storage class, LoadBalancer capability, ingress
#                  class, live release image tag, existing PVC, and the key
#                  NAMES (never values) of the release secret.
#   3. Config    — back up and write .env (same variable contract as
#                  .env.example), scaffold secrets.env (mode 600) when
#                  missing, print next steps.
#
# Without --host the SSH/fetch stages are skipped (review-only mode) against
# an already-working kubectl.
#
# Usage:
#   scripts/bootstrap-cluster.sh [options]
#     --host [user@]IP        Control-plane host (enables the SSH/fetch stage)
#     --ssh-port N            SSH port on the control plane (default: 22)
#     --ssh-key PATH          Local SSH key (default: ~/.ssh/id_ed25519;
#                             generated when missing)
#     --remote-config PATH    Remote kubeconfig (default:
#                             /etc/rancher/k3s/k3s.yaml)
#     --kubeconfig-dest PATH  Where to install the kubeconfig (default:
#                             ~/.kube/config)
#     --kubeconfig PATH       Use this existing kubeconfig instead of
#                             fetching (implies review-only; not with --host)
#     --namespace NS          Target namespace (default: homeassistant)
#     --release NAME          Helm release name (default: homeassistant)
#     --install               Chain into scripts/install.sh when done
#     -h, --help              Show this help and exit
#
# After it completes: helm/kubectl work against the cluster and .env is
# complete for scripts/install.sh and scripts/update.sh.
# =============================================================================
set -Eeuo pipefail

# Repository root = one level above scripts/ (portable cd + pwd chain).
REPO_ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)" || {
  printf 'error: cannot determine script directory\n' >&2
  exit 1
}
# shellcheck source=scripts/lib/common.sh
. "$REPO_ROOT/scripts/lib/common.sh"

setup_cleanup_trap

usage() {
  cat <<'EOF'
Usage: scripts/bootstrap-cluster.sh [options]

Bootstraps cluster access from this host and generates a cluster-aware .env
for scripts/install.sh and scripts/update.sh.

Stages:
  1. Access   -- with --host [user@]ip: set up passwordless SSH, fetch the k3s
                 kubeconfig (scp, 'sudo cat' fallback), rewrite the server URL
                 to the control-plane address, install and validate it.
                 -- without --host: skipped (review-only against working kubectl).
  2. Review   -- derive sane chart values from the cluster: node architecture,
                 default storage class, LoadBalancer capability, ingress class,
                 live release image tag, existing PVC, secret key NAMES.
  3. Config   -- back up and write .env, scaffold secrets.env (mode 600) when
                 missing, print next steps.

Options:
  -h, --help              Show this help and exit.
      --host [user@]IP    Control-plane host (enables the SSH/fetch stage).
      --ssh-port N        SSH port on the control plane (default: 22).
      --ssh-key PATH      Local SSH key (default: ~/.ssh/id_ed25519;
                          generated when missing).
      --remote-config PATH   Remote kubeconfig (default:
                          /etc/rancher/k3s/k3s.yaml).
      --kubeconfig-dest PATH  Where to install the kubeconfig (default:
                          ~/.kube/config).
      --kubeconfig PATH   Use this existing kubeconfig instead of fetching
                          (review-only; mutually exclusive with --host).
      --namespace NS      Target namespace (default: homeassistant).
      --release NAME      Helm release name (default: homeassistant).
      --install           Chain into scripts/install.sh when done.

Examples:
  # Full bootstrap from the control plane (one-time password prompt possible):
  scripts/bootstrap-cluster.sh --host pi@192.168.1.10

  # Review-only, kubeconfig already working:
  scripts/bootstrap-cluster.sh
EOF
}

# --- Flags ---------------------------------------------------------------------
FLAG_HOST=""
FLAG_SSH_PORT=""
FLAG_SSH_KEY=""
FLAG_REMOTE_CONFIG=""
FLAG_KUBECONFIG_DEST=""
FLAG_KUBECONFIG=""
FLAG_NAMESPACE=""
FLAG_RELEASE=""
FLAG_INSTALL=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --host)
      [ "$#" -ge 2 ] && [ -n "${2:-}" ] || die "--host requires a non-empty argument ([user@]host)"
      FLAG_HOST="$2"
      shift
      ;;
    --host=*)
      FLAG_HOST="${1#--host=}"
      [ -n "$FLAG_HOST" ] || die "--host requires a non-empty value"
      ;;
    --ssh-port)
      [ "$#" -ge 2 ] && [ -n "${2:-}" ] || die "--ssh-port requires a non-empty argument"
      assert_int FLAG_SSH_PORT "$2"
      FLAG_SSH_PORT="$2"
      shift
      ;;
    --ssh-port=*)
      FLAG_SSH_PORT="${1#--ssh-port=}"
      [ -n "$FLAG_SSH_PORT" ] || die "--ssh-port requires a non-empty value"
      assert_int FLAG_SSH_PORT "$FLAG_SSH_PORT"
      ;;
    --ssh-key)
      [ "$#" -ge 2 ] && [ -n "${2:-}" ] || die "--ssh-key requires a non-empty argument"
      FLAG_SSH_KEY="$2"
      shift
      ;;
    --ssh-key=*)
      FLAG_SSH_KEY="${1#--ssh-key=}"
      [ -n "$FLAG_SSH_KEY" ] || die "--ssh-key requires a non-empty value"
      ;;
    --remote-config)
      [ "$#" -ge 2 ] && [ -n "${2:-}" ] || die "--remote-config requires a non-empty argument"
      FLAG_REMOTE_CONFIG="$2"
      shift
      ;;
    --remote-config=*)
      FLAG_REMOTE_CONFIG="${1#--remote-config=}"
      [ -n "$FLAG_REMOTE_CONFIG" ] || die "--remote-config requires a non-empty value"
      ;;
    --kubeconfig-dest)
      [ "$#" -ge 2 ] && [ -n "${2:-}" ] || die "--kubeconfig-dest requires a non-empty argument"
      FLAG_KUBECONFIG_DEST="$2"
      shift
      ;;
    --kubeconfig-dest=*)
      FLAG_KUBECONFIG_DEST="${1#--kubeconfig-dest=}"
      [ -n "$FLAG_KUBECONFIG_DEST" ] || die "--kubeconfig-dest requires a non-empty value"
      ;;
    --kubeconfig)
      [ "$#" -ge 2 ] && [ -n "${2:-}" ] || die "--kubeconfig requires a non-empty argument"
      FLAG_KUBECONFIG="$2"
      shift
      ;;
    --kubeconfig=*)
      FLAG_KUBECONFIG="${1#--kubeconfig=}"
      [ -n "$FLAG_KUBECONFIG" ] || die "--kubeconfig requires a non-empty value"
      ;;
    --namespace)
      [ "$#" -ge 2 ] && [ -n "${2:-}" ] || die "--namespace requires a non-empty argument"
      FLAG_NAMESPACE="$2"
      shift
      ;;
    --namespace=*)
      FLAG_NAMESPACE="${1#--namespace=}"
      [ -n "$FLAG_NAMESPACE" ] || die "--namespace requires a non-empty value"
      ;;
    --release)
      [ "$#" -ge 2 ] && [ -n "${2:-}" ] || die "--release requires a non-empty argument"
      FLAG_RELEASE="$2"
      shift
      ;;
    --release=*)
      FLAG_RELEASE="${1#--release=}"
      [ -n "$FLAG_RELEASE" ] || die "--release requires a non-empty value"
      ;;
    --install)
      FLAG_INSTALL=1
      ;;
    *)
      die "Unknown argument: '$1' (see --help)"
      ;;
  esac
  shift
done

if [ -n "$FLAG_HOST" ] && [ -n "$FLAG_KUBECONFIG" ]; then
  die "--host and --kubeconfig are mutually exclusive (--kubeconfig is for review-only runs with an existing kubeconfig)."
fi

# --- Effective configuration -----------------------------------------------------
SSH_PORT="${FLAG_SSH_PORT:-22}"
SSH_KEY="${FLAG_SSH_KEY:-${HOME}/.ssh/id_ed25519}"
REMOTE_CONFIG="${FLAG_REMOTE_CONFIG:-/etc/rancher/k3s/k3s.yaml}"
KUBECONFIG_DEST="${FLAG_KUBECONFIG_DEST:-${HOME}/.kube/config}"
NAMESPACE="${FLAG_NAMESPACE:-homeassistant}"
RELEASE_NAME="${FLAG_RELEASE:-homeassistant}"
SECRET_NAME="${RELEASE_NAME}-secrets"
CHART_DIR="charts/homeassistant"
HELM_TIMEOUT="10m"
VALUES_EXTRA=""
ENV_PATH="$REPO_ROOT/.env"
SECRETS_PATH="$REPO_ROOT/secrets.env"

assert_yaml_safe NAMESPACE      "$NAMESPACE"
assert_yaml_safe RELEASE_NAME   "$RELEASE_NAME"
assert_yaml_safe SECRET_NAME    "$SECRET_NAME"
assert_yaml_safe SSH_KEY        "$SSH_KEY"
assert_yaml_safe REMOTE_CONFIG  "$REMOTE_CONFIG"

SSH_TARGET=""
SSH_OPTS=()
KUBECONFIG_FOR_ENV=""
TIMEZONE="UTC"
R_TZ=""

# =============================================================================
# Stage 1 — Access
# =============================================================================

stage_access() {
  SSH_TARGET="$FLAG_HOST"
  log_info "Stage 1: access bootstrap for '$SSH_TARGET'"
  require_cmds ssh scp kubectl

  HOST_ONLY="${SSH_TARGET##*@}"
  if [ -z "$HOST_ONLY" ]; then
    die "Could not parse --host '$SSH_TARGET' (expected [user@]host)."
  fi

  # --- SSH key: generate when missing; re-derive the public key either way ----
  _key_dir="$(dirname "$SSH_KEY")"
  if [ ! -d "$_key_dir" ]; then
    mkdir -p "$_key_dir"
    chmod 700 "$_key_dir"
  fi
  if [ ! -f "$SSH_KEY" ]; then
    _key_comment="ha-k3s-bootstrap@$(hostname 2>/dev/null || printf 'client')"
    log_info "SSH key not found — generating $SSH_KEY (no passphrase)..."
    ssh-keygen -t ed25519 -N '' -f "$SSH_KEY" -C "$_key_comment" -q ||
      die "ssh-keygen failed for $SSH_KEY."
    chmod 600 "$SSH_KEY"
  fi
  PUB="$(ssh-keygen -y -f "$SSH_KEY" 2>/dev/null)" ||
    die "Could not read the public key of $SSH_KEY (is the private key readable?)."
  PUB_CORE="$(printf '%s\n' "$PUB" | awk '{print $1, $2}')" ||
    die "Could not parse the public key."
  # Defense in depth: the key type + base64 body can never contain shell
  # metacharacters; abort instead of interpolating anything else remotely.
  case "$PUB_CORE" in
    *"'"*|*'"'*|*$'\\'*|*'$'*|*'`'*) die "Unexpected character in the generated public key — aborting." ;;
  esac
  [ -n "$PUB_CORE" ] || die "Could not parse the public key."
  log_ok "Using SSH key: $SSH_KEY"

  # Remote command installs the key idempotently (grep -qxF: no duplicates on
  # re-runs). $HOME must expand on the REMOTE shell, hence the escaped \$;
  # PUB_CORE is guarded above and interpolated inside remote single quotes.
  REMOTE_KEY_CMD="mkdir -p \"\$HOME/.ssh\" && chmod 700 \"\$HOME/.ssh\" && touch \"\$HOME/.ssh/authorized_keys\" && chmod 600 \"\$HOME/.ssh/authorized_keys\" && { grep -qxF '$PUB_CORE' \"\$HOME/.ssh/authorized_keys\" || printf '%s\\n' '$PUB_CORE' >> \"\$HOME/.ssh/authorized_keys\"; }"

  SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -p "$SSH_PORT" -i "$SSH_KEY")

  if ssh "${SSH_OPTS[@]}" -o BatchMode=yes "$SSH_TARGET" "$REMOTE_KEY_CMD" 2>/dev/null; then
    log_ok "SSH key is authorized on '$SSH_TARGET'."
  else
    log_warn "Key-based SSH not accepted yet for '$SSH_TARGET'."
    log_warn "One-time authentication (password/2FA) is needed to install the key — you may be prompted."
    # Intentional: REMOTE_KEY_CMD is fully built client-side (key interpolated).
    # shellcheck disable=SC2029
    ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "$REMOTE_KEY_CMD" ||
      die "Could not install the SSH key on '$SSH_TARGET' (authentication failed?). Try: ssh-copy-id or manual authorized_keys edit."
  fi

  if ! ssh "${SSH_OPTS[@]}" -o BatchMode=yes -o PasswordAuthentication=no "$SSH_TARGET" true 2>/dev/null; then
    die "Passwordless SSH to '$SSH_TARGET' is NOT working after key installation."
  fi
  log_ok "Passwordless SSH to '$SSH_TARGET' verified."

  # --- Timezone from the control plane (best effort) ---------------------------
  R_TZ="$(ssh "${SSH_OPTS[@]}" -o BatchMode=yes "$SSH_TARGET" \
            'timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null' 2>/dev/null |
          head -n 1 | tr -d '[:space:]' || true)"
  case "$R_TZ" in
    *[!A-Za-z0-9_+./-]*) R_TZ="" ;;
  esac
  if [ -n "$R_TZ" ]; then
    TIMEZONE="$R_TZ"
    log_ok "Control-plane timezone detected: $TIMEZONE"
  else
    log_info "Could not detect the control-plane timezone — keeping TIMEZONE=$TIMEZONE."
  fi

  # --- Fetch the kubeconfig ------------------------------------------------------
  FETCHED="$(mktemp "${TMPDIR:-/tmp}/ha-k3s-kubeconfig.XXXXXX")" || die "mktemp failed"
  register_cleanup_file "$FETCHED"

  if scp -q -P "$SSH_PORT" -i "$SSH_KEY" -o BatchMode=yes \
       -o StrictHostKeyChecking=accept-new "${SSH_TARGET}:${REMOTE_CONFIG}" "$FETCHED" 2>/dev/null; then
    log_ok "Fetched '$REMOTE_CONFIG' via scp."
  else
    log_warn "scp failed (likely permission on '$REMOTE_CONFIG', root-owned) — trying 'sudo cat' over ssh..."
    ssh "${SSH_OPTS[@]}" -o BatchMode=yes "$SSH_TARGET" \
      "sudo cat $(printf '%q' "$REMOTE_CONFIG")" > "$FETCHED" 2>/dev/null ||
      die "Could not fetch '$REMOTE_CONFIG': neither direct read (scp) nor 'sudo cat' worked.
hint: re-install k3s with --write-kubeconfig-mode 644 (see docs/rpi4-k3s.md), or make the file group-readable."
  fi

  if [ ! -s "$FETCHED" ]; then
    die "Fetched kubeconfig is empty."
  fi
  if ! grep -q 'apiVersion:' "$FETCHED"; then
    die "Fetched file does not look like a kubeconfig (no 'apiVersion:')."
  fi

  # --- Rewrite 127.0.0.1/localhost -> control-plane host (awk, no sed -i) -------
  K3S_PORT="$(awk '/^[[:space:]]*server:/ { n=split($2, a, ":"); if (n>1) print a[n]; }' "$FETCHED" | head -n 1 || true)"
  case "${K3S_PORT:-}" in
    ''|*[!0-9]*) K3S_PORT="6443" ;;
  esac
  SRV_URL="https://${HOST_ONLY}:${K3S_PORT}"

  _dest_dir="$(dirname "$KUBECONFIG_DEST")"
  mkdir -p "$_dest_dir"
  awk -v srv="$SRV_URL" '
    /^[[:space:]]*server:/ {
      indent = $0
      sub(/server:.*/, "", indent)
      print indent "server: " srv
      next
    }
    { print }
  ' "$FETCHED" > "$KUBECONFIG_DEST" || die "Could not write $KUBECONFIG_DEST."
  chmod 600 "$KUBECONFIG_DEST"
  log_ok "Kubeconfig installed: $KUBECONFIG_DEST (server: $SRV_URL)"

  # --- Validate before proceeding -------------------------------------------------
  if ! KUBECONFIG="$KUBECONFIG_DEST" kubectl get nodes --request-timeout=15s >/dev/null 2>&1; then
    log_error "The fetched kubeconfig does NOT give working cluster access ('kubectl get nodes' failed)."
    log_error "Common cause: the API server certificate does not include '${HOST_ONLY}'."
    log_error "hint: (re)install k3s with --tls-san ${HOST_ONLY} (docs/rpi4-k3s.md). The kubeconfig was left at $KUBECONFIG_DEST for inspection."
    exit 1
  fi
  log_ok "Cluster reachable via the fetched kubeconfig."
  export KUBECONFIG="$KUBECONFIG_DEST"
  KUBECONFIG_FOR_ENV="$KUBECONFIG_DEST"
}

# Review-only path (no --host): resolve an existing working kubeconfig.
stage_access_existing() {
  log_info "Stage 1: skipped (no --host) — using the existing kubeconfig"
  require_cmds kubectl
  if [ -n "$FLAG_KUBECONFIG" ]; then
    _kc="$FLAG_KUBECONFIG"
  elif [ -n "${KUBECONFIG:-}" ]; then
    _kc="$KUBECONFIG"
  elif [ -f "$HOME/.kube/config" ]; then
    _kc="$HOME/.kube/config"
  else
    _kc=""
  fi
  if [ -n "$_kc" ]; then
    case "$_kc" in
      /*) : ;;
      *)  _kc="$PWD/$_kc" ;;
    esac
    if ! kubectl get nodes --request-timeout=15s >/dev/null 2>&1; then
      die "Cluster not reachable with kubeconfig: $_kc.
If you have SSH access to the control plane, re-run with --host [user@]ip to fetch the kubeconfig."
    fi
    log_ok "Using kubeconfig: $_kc"
    export KUBECONFIG="$_kc"
    KUBECONFIG_FOR_ENV="$_kc"
  else
    log_warn "No kubeconfig found (--kubeconfig, \$KUBECONFIG or ~/.kube/config)."
    log_warn "Review continues with kubectl's default resolution; KUBECONFIG will be left EMPTY in .env."
    log_warn "If the cluster lives on another host, re-run with --host [user@]ip to fetch its kubeconfig."
  fi
}

# =============================================================================
# Stage 2 — Review (names only for secrets; go-template/jsonpath queries)
# =============================================================================

NODE_ARCH=""
STORAGE_CLASS=""
STORAGE_SIZE="5Gi"
SERVICE_TYPE="LoadBalancer"
SERVICE_PORT="8123"
LOADBALANCER_IP=""
NODE_PORT=""
INGRESS_ENABLED="false"
INGRESS_CLASS=""
INGRESS_HOST=""
HOST_NETWORK="false"
IMAGE_TAG=""
RELEASE_EXISTS=0
NS_EXISTS=0
LOCAL_SECRET_KEYS=""
CLUSTER_SECRET_KEYS=""

review_nodes() {
  _archs="$(kubectl get nodes -o go-template='{{range .items}}{{.status.nodeInfo.architecture}}{{"\n"}}{{end}}' 2>/dev/null | sort -u || true)"
  _count="$(printf '%s\n' "$_archs" | grep -c . || true)"
  if [ "$_count" = "1" ]; then
    NODE_ARCH="$(printf '%s\n' "$_archs" | head -n 1)"
    log_ok "All nodes are ${NODE_ARCH} — NODE_ARCH=${NODE_ARCH} (pinning scheduling)."
  else
    log_warn "Mixed-architecture or unreadable node list — leaving NODE_ARCH empty (no nodeSelector)."
  fi
}

review_storage_class() {
  _defs="$(kubectl get sc -o go-template='{{range .items}}{{if .metadata.annotations}}{{if index .metadata.annotations "storageclass.kubernetes.io/is-default-class"}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}{{end}}' 2>/dev/null | sort -u || true)"
  _count="$(printf '%s\n' "$_defs" | grep -c . || true)"
  if [ "$_count" = "1" ]; then
    STORAGE_CLASS="$(printf '%s\n' "$_defs" | head -n 1)"
    log_ok "Default storage class: $STORAGE_CLASS."
  elif [ "$_count" -gt 1 ]; then
    log_warn "Multiple default storage classes found — leaving STORAGE_CLASS empty (kubernetes picks one)."
  else
    log_info "No default storage class annotation found — leaving STORAGE_CLASS empty (k3s 'local-path' applies by default)."
  fi
}

review_lb_capability() {
  _assigned="$(kubectl get svc -A -o go-template='{{range .items}}{{if eq .spec.type "LoadBalancer"}}{{range .status.loadBalancer.ingress}}{{.ip}}{{" "}}{{.hostname}}{{" "}}{{end}}{{end}}{{end}}' 2>/dev/null | tr -d '[:space:]' || true)"
  if [ -n "$_assigned" ]; then
    log_ok "LoadBalancer services have assigned addresses — SERVICE_TYPE=LoadBalancer."
    return 0
  fi
  _svclb="$(kubectl -n kube-system get ds -o go-template='{{range .items}}{{.metadata.name}}{{"\n"}}{{end}}' 2>/dev/null | grep -c '^svclb' || true)"
  if [ "${_svclb:-0}" -gt 0 ]; then
    log_ok "klipper-lb detected (svclb DaemonSet) — SERVICE_TYPE=LoadBalancer."
    return 0
  fi
  SERVICE_TYPE="NodePort"
  NODE_PORT="30812"
  log_warn "No LoadBalancer capability detected — falling back to SERVICE_TYPE=NodePort with NODE_PORT=30812."
  log_warn "If you install MetalLB (or use k3s ServiceLB) later, switch SERVICE_TYPE back to LoadBalancer."
}

review_ingress_class() {
  _classes="$(kubectl get ingressclasses -o go-template='{{range .items}}{{.metadata.name}}{{"\n"}}{{end}}' 2>/dev/null || true)"
  if printf '%s\n' "$_classes" | grep -qx traefik; then
    INGRESS_CLASS="traefik"
    log_ok "Ingress class 'traefik' available (INGRESS_ENABLED stays false — opt-in)."
  else
    INGRESS_CLASS="$(printf '%s\n' "$_classes" | grep -v '^$' | head -n 1 || true)"
    if [ -n "$INGRESS_CLASS" ]; then
      log_ok "Ingress class '$INGRESS_CLASS' available (INGRESS_ENABLED stays false — opt-in)."
    else
      log_info "No ingress controller detected — INGRESS_CLASS left empty."
    fi
  fi
}

chart_default_image_tag() {
  _tag="$(awk -F'"' '/^[[:space:]]*tag:/ { print $2; exit }' "$REPO_ROOT/$CHART_DIR/values.yaml" || true)"
  [ -n "$_tag" ] || die "Could not read the default image tag from $CHART_DIR/values.yaml (chart contract broken?)."
  printf '%s\n' "$_tag"
}

review_release() {
  if command -v helm >/dev/null 2>&1; then
    if helm list -n "$NAMESPACE" --short 2>/dev/null | awk -v n="$RELEASE_NAME" '$1 == n { f=1 } END { exit !f }'; then
      RELEASE_EXISTS=1
      log_ok "Helm release '$RELEASE_NAME' already exists in namespace '$NAMESPACE'."
    fi
  else
    log_warn "helm is not on PATH — existing-release detection skipped (run scripts/install-prereqs.sh)."
  fi

  if [ "$RELEASE_EXISTS" = "1" ]; then
    _live_img="$(kubectl -n "$NAMESPACE" get statefulset \
                   -l "app.kubernetes.io/instance=$RELEASE_NAME" \
                   -o jsonpath='{.items[0].spec.template.spec.containers[0].image}' 2>/dev/null || true)"
    _live_tag=""
    case "$_live_img" in
      *@sha256:*) _live_tag="" ;;
      *:*)        _live_tag="${_live_img##*:}" ;;
      *)          _live_tag="" ;;
    esac
    if [ -n "$_live_tag" ]; then
      IMAGE_TAG="$_live_tag"
      log_ok "Live release image tag: $IMAGE_TAG (update.sh will target this unless you raise it)."
    fi
  fi
  if [ -z "$IMAGE_TAG" ]; then
    IMAGE_TAG="$(chart_default_image_tag)"
    log_ok "IMAGE_TAG from chart default: $IMAGE_TAG."
  fi
}

review_pvc() {
  [ "$NS_EXISTS" = "1" ] || return 0
  _tab=$'\t'
  _pvc="$(kubectl -n "$NAMESPACE" get pvc \
            -l "app.kubernetes.io/instance=$RELEASE_NAME" \
            -o go-template='{{range .items}}{{.spec.resources.requests.storage}}{{"\t"}}{{.spec.storageClassName}}{{"\n"}}{{end}}' 2>/dev/null |
          head -n 1 || true)"
  if [ -n "$_pvc" ]; then
    _size="${_pvc%%"${_tab}"*}"
    _class="${_pvc#*"${_tab}"}"
    if [ -n "$_size" ]; then
      STORAGE_SIZE="$_size"
      log_ok "Existing PVC requests storage: $STORAGE_SIZE (kept — never shrink storage)."
    fi
    if [ -n "$_class" ]; then
      STORAGE_CLASS="$_class"
      log_ok "Existing PVC storage class: $STORAGE_CLASS (kept — never move storage)."
    else
      log_ok "Existing PVC uses the cluster default storage class (STORAGE_CLASS left empty)."
    fi
  fi
}

review_secrets() {
  if [ -f "$SECRETS_PATH" ]; then
    LOCAL_SECRET_KEYS="$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$SECRETS_PATH" | cut -d= -f1 || true)"
    log_ok "Local secrets file exists: $SECRETS_PATH (values are never printed)."
  fi
  [ "$NS_EXISTS" = "1" ] || return 0
  if kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" >/dev/null 2>&1; then
    # The template is evaluated by kubectl, not by this shell — single quotes
    # keep $k literal here on purpose.
    # shellcheck disable=SC2016
    CLUSTER_SECRET_KEYS="$(kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" \
      -o go-template='{{range $k,$_ := .data}}{{$k}}{{"\n"}}{{end}}' 2>/dev/null || true)"
    log_ok "Cluster secret '$SECRET_NAME' exists (key names only are reported)."
  fi
}

stage_review() {
  log_info "Stage 2: reviewing the cluster (namespace: $NAMESPACE, release: $RELEASE_NAME)"
  if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    NS_EXISTS=1
    log_ok "Namespace '$NAMESPACE' exists."
  else
    log_info "Namespace '$NAMESPACE' does not exist yet (install.sh creates it)."
  fi

  review_nodes
  review_storage_class
  review_lb_capability
  review_ingress_class
  review_release
  review_pvc
  review_secrets
}

# =============================================================================
# Stage 3 — Configuration (.env + secrets scaffold)
# =============================================================================

write_env_file() {
  if [ -f "$ENV_PATH" ]; then
    _ts="$(date +%Y%m%d%H%M%S)"
    _bak="$ENV_PATH.backup-$_ts"
    # Collision-safe: two runs within the same second must not overwrite the
    # first backup (that would lose the original .env).
    _bakn=0
    while [ -e "$_bak" ]; do
      _bakn=$((_bakn + 1))
      _bak="$ENV_PATH.backup-$_ts.$_bakn"
    done
    cp "$ENV_PATH" "$_bak" ||
      die "Could not back up the existing .env to $_bak."
    log_ok "Backed up the existing .env -> $(basename "$_bak")"
  fi

  # Every written value must be YAML/shell-safe (no quotes/backslashes/$).
  assert_yaml_safe KUBECONFIG        "$KUBECONFIG_FOR_ENV"
  assert_yaml_safe CHART_DIR         "$CHART_DIR"
  assert_yaml_safe HELM_TIMEOUT      "$HELM_TIMEOUT"
  assert_yaml_safe IMAGE_TAG         "$IMAGE_TAG"
  assert_yaml_safe TIMEZONE          "$TIMEZONE"
  assert_yaml_safe NODE_ARCH         "$NODE_ARCH"
  assert_yaml_safe STORAGE_CLASS     "$STORAGE_CLASS"
  assert_yaml_safe STORAGE_SIZE      "$STORAGE_SIZE"
  assert_yaml_safe SERVICE_TYPE      "$SERVICE_TYPE"
  assert_yaml_safe SERVICE_PORT      "$SERVICE_PORT"
  assert_yaml_safe LOADBALANCER_IP   "$LOADBALANCER_IP"
  assert_yaml_safe NODE_PORT         "$NODE_PORT"
  assert_yaml_safe INGRESS_ENABLED   "$INGRESS_ENABLED"
  assert_yaml_safe INGRESS_CLASS     "$INGRESS_CLASS"
  assert_yaml_safe INGRESS_HOST      "$INGRESS_HOST"
  assert_yaml_safe HOST_NETWORK      "$HOST_NETWORK"
  assert_yaml_safe SECRETS_FILE      "secrets.env"
  assert_yaml_safe VALUES_EXTRA      "$VALUES_EXTRA"

  cat > "$ENV_PATH" <<EOF
# =============================================================================
# homeassistant-on-k3s — generated by scripts/bootstrap-cluster.sh
# Values marked "(cluster)" were derived from the running cluster; edit freely,
# then run scripts/install.sh. NEVER commit this file.
# Real credentials go in secrets.env (see secrets.env.example).
# =============================================================================

# --- Kubernetes target --------------------------------------------------------
KUBECONFIG="$KUBECONFIG_FOR_ENV"
NAMESPACE="$NAMESPACE"

# --- Helm release ---------------------------------------------------------------
RELEASE_NAME="$RELEASE_NAME"
CHART_DIR="$CHART_DIR"
HELM_TIMEOUT="$HELM_TIMEOUT"
VALUES_EXTRA="$VALUES_EXTRA"

# --- Container image --------------------------------------------------------------
# (cluster) the live release's tag when a release already exists, else the
# chart default — raise it to upgrade via scripts/update.sh
IMAGE_TAG="$IMAGE_TAG"

# --- Workload configuration ---------------------------------------------------------
# (cluster) control-plane timezone when SSH was used, else UTC
TIMEZONE="$TIMEZONE"
# (cluster) pinned when every node shares one architecture
NODE_ARCH="$NODE_ARCH"

# --- Persistence -----------------------------------------------------------------------
# (cluster) default storage class; empty = cluster default (k3s local-path)
STORAGE_CLASS="$STORAGE_CLASS"
# (cluster) size of the existing PVC when the release already exists
STORAGE_SIZE="$STORAGE_SIZE"

# --- Exposure -----------------------------------------------------------------------------
# (cluster) LoadBalancer when the cluster can bind one, else NodePort
SERVICE_TYPE="$SERVICE_TYPE"
SERVICE_PORT="$SERVICE_PORT"
LOADBALANCER_IP="$LOADBALANCER_IP"
# (cluster) fixed NodePort fallback (30000-32767)
NODE_PORT="$NODE_PORT"
# (cluster) ingress class available; enabling stays opt-in
INGRESS_ENABLED="$INGRESS_ENABLED"
INGRESS_CLASS="$INGRESS_CLASS"
INGRESS_HOST="$INGRESS_HOST"
# mDNS/SSDP/UPnP discovery — opt-in, binds a node's host network
HOST_NETWORK="$HOST_NETWORK"

# --- Secrets --------------------------------------------------------------------------------
# Real secrets live in secrets.env (git-ignored); install.sh applies them as
# the Kubernetes Secret '$SECRET_NAME'.
SECRETS_FILE="secrets.env"
EOF

  chmod 600 "$ENV_PATH"

  # The generated file must source cleanly before we call the job done.
  # shellcheck disable=SC1090  # file is generated just above
  if ! ( set -a; . "$ENV_PATH" ) 2>/dev/null; then
    die "The generated .env does not source cleanly (this is a bug — please report it)."
  fi
  log_ok "Wrote $ENV_PATH (mode 600)."
}

scaffold_secrets() {
  if [ ! -f "$SECRETS_PATH" ]; then
    cp "$REPO_ROOT/secrets.env.example" "$SECRETS_PATH" ||
      die "Could not scaffold $SECRETS_PATH from secrets.env.example."
    chmod 600 "$SECRETS_PATH"
    log_ok "Scaffolded $SECRETS_PATH from secrets.env.example (mode 600) — fill in real values before install.sh."
  fi
}

# =============================================================================
# Report
# =============================================================================

print_report() {
  printf '\n'
  log_ok "Bootstrap complete. Cluster-derived configuration:"
  log_ok "  KUBECONFIG:     ${KUBECONFIG_FOR_ENV:-<kubectl default>}"
  log_ok "  NAMESPACE:      $NAMESPACE"
  log_ok "  RELEASE_NAME:   $RELEASE_NAME"
  log_ok "  IMAGE_TAG:      $IMAGE_TAG"
  log_ok "  TIMEZONE:       $TIMEZONE"
  log_ok "  NODE_ARCH:      ${NODE_ARCH:-<mixed/none>}"
  log_ok "  STORAGE_CLASS:  ${STORAGE_CLASS:-<cluster default>}"
  log_ok "  STORAGE_SIZE:   $STORAGE_SIZE"
  log_ok "  SERVICE_TYPE:   $SERVICE_TYPE${NODE_PORT:+ (nodePort $NODE_PORT)}"
  log_ok "  INGRESS_CLASS:  ${INGRESS_CLASS:-<none detected>} (enabled: $INGRESS_ENABLED)"

  if [ -n "$LOCAL_SECRET_KEYS" ]; then
    log_ok "  secrets.env keys:       $(printf '%s' "$LOCAL_SECRET_KEYS" | tr '\n' ' ')"
  fi
  if [ -n "$CLUSTER_SECRET_KEYS" ]; then
    log_ok "  cluster secret keys:    $(printf '%s' "$CLUSTER_SECRET_KEYS" | tr '\n' ' ')"
  fi
  if [ -n "$CLUSTER_SECRET_KEYS" ] && [ ! -f "$SECRETS_PATH" ]; then
    log_warn "The cluster already has a secret but no local secrets.env — scaffold one above and mirror those KEY names."
  fi

  printf '\n'
  log_ok "helm and kubectl now work against the cluster. For ad-hoc use:"
  if [ -n "$KUBECONFIG_FOR_ENV" ]; then
    log_ok "  export KUBECONFIG=\"$KUBECONFIG_FOR_ENV\""
  fi
  printf '\n'
  log_ok "Next steps:"
  log_ok "  1. edit secrets.env (real credentials; key names only are shown above)"
  log_ok "  2. scripts/install.sh --dry-run   # preview every change"
  log_ok "  3. scripts/install.sh             # install the release"
  log_ok "  4. scripts/update.sh              # later upgrades (same .env)"
  printf '\n'
}

# =============================================================================
# Main
# =============================================================================

log_info "Bootstrapping Home Assistant on k3s — repo: $REPO_ROOT"

if [ -n "$FLAG_HOST" ]; then
  stage_access
else
  stage_access_existing
fi

stage_review
write_env_file
scaffold_secrets
print_report

if [ "$FLAG_INSTALL" = "1" ]; then
  log_info "Handing off to scripts/install.sh (--install)..."
  exec "$REPO_ROOT/scripts/install.sh"
fi

log_ok "Done."
