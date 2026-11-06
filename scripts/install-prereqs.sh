#!/usr/bin/env bash
# =============================================================================
# scripts/install-prereqs.sh — install the toolchain this project needs.
#
# Requirements: helm (v3+/v4), kubectl, bash 3.2+, git, curl.
#
#   Linux : helm + kubectl from official upstream binaries (sha256-verified,
#           get.helm.sh / dl.k8s.io), installed to /usr/local/bin (sudo when
#           passwordless, or as root) or ~/.local/bin as a no-prompt fallback.
#           bash/git/curl via the distro package manager when missing.
#   macOS : Homebrew is favored — installs Homebrew itself (non-interactively)
#           when absent, then `brew install helm kubectl bash git` as needed.
#
# Usage:
#   scripts/install-prereqs.sh [options]
#     -h, --help       Show this help and exit.
#         --check      Verify only: report status, install nothing, exit 0/1.
#         --prefix DIR Directory for Linux binary installs (default:
#                      /usr/local/bin when root/passwordless sudo, else
#                      ~/.local/bin). Also: HC_INSTALL_PREFIX env var.
#
# Idempotent: tools already present at a supported version are skipped.
# Every install is verified by running the tool's version command.
# =============================================================================
set -Eeuo pipefail

REPO_ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)" || {
  printf 'error: cannot determine script directory\n' >&2
  exit 1
}
# shellcheck source=scripts/lib/common.sh
. "$REPO_ROOT/scripts/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/install-prereqs.sh [options]

Installs the toolchain required by this repository: helm (v3+/v4), kubectl,
bash 3.2+, git, curl.

  macOS      Homebrew is favored: installs Homebrew when missing, then the
             missing formulas (helm kubectl bash git).
  Linux      helm + kubectl from official upstream binaries, sha256-verified;
             bash/git/curl via apt/dnf/pacman/zypper/apk when missing.

Options:
  -h, --help    Show this help and exit.
      --check   Verify only: report status, install nothing, exit 0/1.
      --prefix DIR  Target directory for Linux binary installs
                (default: /usr/local/bin with root/passwordless sudo,
                otherwise ~/.local/bin). Env: HC_INSTALL_PREFIX.
EOF
}

CHECK_ONLY=0
PREFIX="${HC_INSTALL_PREFIX:-}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --check)
      CHECK_ONLY=1
      ;;
    --prefix)
      if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then die "--prefix requires a non-empty argument"; fi
      PREFIX="$2"
      shift
      ;;
    --prefix=*)
      PREFIX="${1#--prefix=}"
      if [ -z "$PREFIX" ]; then die "--prefix requires a non-empty value"; fi
      ;;
    *)
      die "Unknown argument: '$1' (see --help)"
      ;;
  esac
  shift
done

# --- Detection -----------------------------------------------------------------
OS="$(uname -s)"
case "$OS" in
  Linux|Darwin) : ;;
  *) die "Unsupported operating system: $OS (this script supports Linux and macOS)" ;;
esac

ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  x86_64|amd64)        ARCH="amd64" ;;
  aarch64|arm64)       ARCH="arm64" ;;
  armv7l|armv6l)       ARCH="arm" ;;
  *) die "Unsupported architecture: $ARCH_RAW" ;;
esac

# Sudo policy: root needs none; passwordless sudo is used when available.
# A password prompt is never triggered — deterministic fallback instead.
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    SUDO="sudo"
  fi
fi

if [ -z "$PREFIX" ]; then
  if [ "$(id -u)" -eq 0 ] || [ -n "$SUDO" ]; then
    PREFIX="/usr/local/bin"
  else
    PREFIX="${HOME}/.local/bin"
  fi
fi

# Set to 1 when the prefix was added to PATH only for this run — the user's
# shell profile still needs the hint printed at the end.
_PREFIX_HINT=0

# --- Assessment ------------------------------------------------------------------
have_helm() {
  _hv="$(helm version --short 2>/dev/null || true)"
  case "${_hv:-}" in
    v3.*|v4.*) return 0 ;;
    *) return 1 ;;
  esac
}
have_kubectl() {
  command -v kubectl >/dev/null 2>&1 && kubectl version --client >/dev/null 2>&1
}
have_bash32() {
  [ "${BASH_VERSINFO[0]:-0}" -ge 3 ] && { [ "${BASH_VERSINFO[0]:-0}" -gt 3 ] || [ "${BASH_VERSINFO[1]:-0}" -ge 2 ]; }
}
have_git()  { command -v git  >/dev/null 2>&1; }
have_curl() { command -v curl >/dev/null 2>&1; }

helm_version()  { helm version --short 2>/dev/null | head -n 1 || true; }
kubectl_ver()   { kubectl version --client 2>/dev/null | head -n 1 || true; }

# report_status — prints one "<tool>: <status>" line per requirement.
report_status() {
  if have_helm;    then log_ok   "helm:    ok ($(helm_version))";    else log_warn "helm:    MISSING"; fi
  if have_kubectl; then log_ok   "kubectl: ok ($(kubectl_ver))";     else log_warn "kubectl: MISSING"; fi
  if have_bash32;  then log_ok   "bash:    ok (${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]})"; else log_warn "bash:    too old (3.2+ required)"; fi
  if have_git;     then log_ok   "git:     ok ($(git --version 2>/dev/null | head -n 1))"; else log_warn "git:     MISSING"; fi
  if have_curl;    then log_ok   "curl:    ok";                        else log_warn "curl:    MISSING"; fi
}

MISSING=""
_add_missing() { MISSING="$MISSING $1"; }
assess_missing() {
  MISSING=""
  have_helm    || _add_missing helm
  have_kubectl || _add_missing kubectl
  have_bash32  || _add_missing bash
  have_git     || _add_missing git
  have_curl    || _add_missing curl
}

# --- Linux package-manager installs ------------------------------------------------
PKG=""
for _p in apt-get dnf yum pacman zypper apk; do
  if command -v "$_p" >/dev/null 2>&1; then
    PKG="$_p"
    break
  fi
done

pkg_install() { # $@ = package names
  [ "$#" -gt 0 ] || return 0
  case "$PKG" in
    apt-get)
      $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -qq
      $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
      ;;
    dnf)    $SUDO dnf install -y "$@" ;;
    yum)    $SUDO yum install -y "$@" ;;
    pacman) $SUDO pacman -Sy --noconfirm "$@" ;;
    zypper) $SUDO zypper --non-interactive install "$@" ;;
    apk)    $SUDO apk add "$@" ;;
    *)      die "No supported package manager found; install manually: $*" ;;
  esac
}

# --- Linux upstream-binary installs (helm, kubectl) ---------------------------------
install_binary() { # $1 = source binary, $2 = name
  if [ -n "$SUDO" ]; then
    $SUDO mkdir -p "$PREFIX" || die "Cannot create $PREFIX (sudo failed). Re-run with --prefix DIR to choose a writable location."
    $SUDO install -m 0755 "$1" "$PREFIX/$2"
  else
    mkdir -p "$PREFIX" || die "Cannot create $PREFIX (permission denied?). Re-run with --prefix DIR to choose a writable location."
    install -m 0755 "$1" "$PREFIX/$2"
  fi
  # Make the freshly installed binary verifiable in THIS run; the persistent
  # PATH hint is printed at the end (_PREFIX_HINT).
  case ":$PATH:" in
    *":$PREFIX:"*) : ;;
    *) PATH="$PREFIX:$PATH"; export PATH; _PREFIX_HINT=1 ;;
  esac
}

fetch() { # $1 = url, $2 = output file
  curl -fsSL -o "$2" "$1" || die "Download failed: $1"
}

install_helm_linux() {
  log_info "Resolving the latest helm release (GitHub API)..."
  _hl_ver="$(curl -fsSL https://api.github.com/repos/helm/helm/releases/latest |
              sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)" ||
    _hl_ver=""
  [ -n "$_hl_ver" ] || die "Could not resolve the latest helm version (GitHub API unreachable or rate-limited). Install manually: https://helm.sh/docs/intro/install/"
  _hl_tar="helm-${_hl_ver}-linux-${ARCH}.tar.gz"
  log_info "Downloading and verifying $_hl_tar..."
  fetch "https://get.helm.sh/${_hl_tar}" "${HC_DLDIR}/${_hl_tar}"
  fetch "https://get.helm.sh/${_hl_tar}.sha256sum" "${HC_DLDIR}/${_hl_tar}.sha256sum"
  _hl_want="$(cut -d' ' -f1 "${HC_DLDIR}/${_hl_tar}.sha256sum" | head -n 1)"
  _hl_got="$(sha256sum "${HC_DLDIR}/${_hl_tar}" | cut -d' ' -f1)"
  [ "$_hl_want" = "$_hl_got" ] || die "helm checksum mismatch ($_hl_tar) — aborting."
  tar -xzf "${HC_DLDIR}/${_hl_tar}" -C "$HC_DLDIR"
  install_binary "${HC_DLDIR}/linux-${ARCH}/helm" helm
  log_ok "helm installed: $(helm_version)"
}

install_kubectl_linux() {
  log_info "Resolving the stable kubectl version (dl.k8s.io)..."
  _kv_ver="$(curl -fsSL https://dl.k8s.io/release/stable.txt | tr -d '[:space:]')" || _kv_ver=""
  [ -n "$_kv_ver" ] || die "Could not resolve the stable kubectl version. Install manually: https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/"
  log_info "Downloading and verifying kubectl $_kv_ver (${ARCH})..."
  fetch "https://dl.k8s.io/release/${_kv_ver}/bin/linux/${ARCH}/kubectl" "${HC_DLDIR}/kubectl"
  fetch "https://dl.k8s.io/release/${_kv_ver}/bin/linux/${ARCH}/kubectl.sha256" "${HC_DLDIR}/kubectl.sha256"
  _kv_want="$(tr -d '[:space:]' < "${HC_DLDIR}/kubectl.sha256")"
  _kv_got="$(sha256sum "${HC_DLDIR}/kubectl" | cut -d' ' -f1)"
  [ "$_kv_want" = "$_kv_got" ] || die "kubectl checksum mismatch — aborting."
  install_binary "${HC_DLDIR}/kubectl" kubectl
  log_ok "kubectl installed: $(kubectl_ver)"
}

# --- macOS Homebrew path --------------------------------------------------------------
install_brew() {
  log_info "Homebrew not found — installing it non-interactively (https://brew.sh)..."
  # shellcheck disable=SC2016  # the installer script is fetched and run as-is
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" ||
    die "Homebrew installation failed. Install it manually: https://brew.sh then re-run this script."
  # Make brew reachable for THIS run (Apple Silicon: /opt/homebrew, Intel: /usr/local).
  for _b in /opt/homebrew/bin /usr/local/bin; do
    if [ -x "${_b}/brew" ]; then
      PATH="${_b}:${PATH}"
      export PATH
      break
    fi
  done
  command -v brew >/dev/null 2>&1 || die "Homebrew was installed but 'brew' is not reachable. Open a new shell (or eval its shellenv) and re-run this script."
  log_ok "Homebrew installed: $(brew --version | head -n 1)"
}

# --- Main -------------------------------------------------------------------------------
log_info "Prerequisites for ${REPO_ROOT} — OS: $OS, arch: ${ARCH} (${ARCH_RAW})"
if [ "$OS" = "Linux" ]; then
  log_info "Package manager: ${PKG:-<none>}   Binary prefix: $PREFIX (sudo: ${SUDO:-<none>})"
fi

# Temporary download directory, cleaned on exit.
HC_DLDIR="$(mktemp -d "${TMPDIR:-/tmp}/ha-prereqs.XXXXXX")" || die "mktemp failed"
trap 'rm -rf "$HC_DLDIR"' EXIT

assess_missing

if [ "$CHECK_ONLY" = "1" ]; then
  log_info "Check-only mode (--check): installing nothing."
  report_status
  if [ -n "$MISSING" ]; then
    log_error "Missing requirements:${MISSING} — run without --check to install them."
    exit 1
  fi
  log_ok "All prerequisites satisfied."
  exit 0
fi

if [ "$OS" = "Darwin" ]; then
  # A pre-existing Homebrew that is not on PATH yet must still be usable here.
  for _b in /opt/homebrew/bin /usr/local/bin; do
    if [ -x "${_b}/brew" ]; then
      case ":$PATH:" in
        *":${_b}:"*) : ;;
        *) PATH="${_b}:${PATH}"; export PATH ;;
      esac
      break
    fi
  done
  # Homebrew is the favored package manager on macOS; install it if absent.
  if ! command -v brew >/dev/null 2>&1; then
    have_curl || die "curl is required to install Homebrew; install it (or Xcode Command Line Tools: xcode-select --install) first."
    install_brew
  fi
  if [ -n "$MISSING" ]; then
    # Intentional word-splitting: MISSING is a plain space-separated list.
    log_info "Installing missing formulas:${MISSING} (brew update + brew install)..."
    brew update
    # shellcheck disable=SC2086
    brew install $MISSING
  fi
  if [ -d /opt/homebrew ] && ! case ":$PATH:" in *":/opt/homebrew/bin:"*) true ;; *) false ;; esac; then
    log_warn "Homebrew lives in /opt/homebrew — add it to your shell profile:"
    # shellcheck disable=SC2016  # literal text for the user's shell profile
    log_warn '  eval "$(/opt/homebrew/bin/brew shellenv)"'
  fi
else
  # Linux: bash/git/curl via the package manager; helm/kubectl as verified
  # upstream binaries (version-agnostic, identical across distros).
  if [ -n "$MISSING" ]; then
    _PKG_NEED=""
    have_curl || _PKG_NEED="$_PKG_NEED curl"
    have_git  || _PKG_NEED="$_PKG_NEED git"
    have_bash32 || _PKG_NEED="$_PKG_NEED bash"
    if [ -n "$_PKG_NEED" ]; then
      log_info "Installing via $PKG:$_PKG_NEED"
      # Intentional word-splitting: plain space-separated package list.
      # shellcheck disable=SC2086
      pkg_install $_PKG_NEED
    fi
    have_curl || die "curl is still missing after package install; install it manually and re-run."
    have_helm    || install_helm_linux
    have_kubectl || install_kubectl_linux
  fi
fi

# --- Verify & report ---------------------------------------------------------------------
assess_missing
log_info "Result:"
report_status
if [ -n "$MISSING" ]; then
  log_error "Some requirements could not be installed:${MISSING}"
  exit 1
fi
if [ "$_PREFIX_HINT" = "1" ]; then
  log_warn "Note: '$PREFIX' was used for this run but is not on your PATH — add it to your shell profile (e.g. export PATH=\"$PREFIX:\$PATH\")."
fi
log_ok "All prerequisites satisfied. Next: ./scripts/install.sh --dry-run"
