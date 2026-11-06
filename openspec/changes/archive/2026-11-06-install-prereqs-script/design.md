# Design: install-prereqs-script

## Technical Approach

A single entry script `scripts/install-prereqs.sh` that sources the existing
`scripts/lib/common.sh` for logging/error handling and implements detection +
install in four layers:

1. **Detect** — OS (`uname -s`: Linux/Darwin), architecture (`uname -m`:
   `x86_64|aarch64|arm64|armv7l` → `amd64|arm64|arm`), and on Linux the
   package manager (`apt-get|dnf|yum|pacman|zypper|apk`).
2. **Assess** — for each requirement, decide satisfied/missing:
   - `helm` → `helm version --short` output matches `v3.*` or `v4.*`
   - `kubectl` → `kubectl version --client` succeeds
   - bash → `$BASH_VERSINFO[0]` ≥ 3 (and ≥ 2 minor)
   - `git`, `curl` → `command -v`
3. **Install** — per OS:
   - **macOS (Homebrew favored)**: if `brew` missing, run the official
     Homebrew installer with `NONINTERACTIVE=1`; then `brew update` (once,
     only when something is missing) and `brew install` the missing subset of
     `helm kubectl bash git`. Brew handles checksums/arch; no manual binaries.
   - **Linux**: `git`/`curl`/bash via the distro package manager when missing;
     `helm` from the get.helm.sh release tarball of the latest GitHub release
     (version resolved via the GitHub releases API) and `kubectl` from
     `dl.k8s.io` `stable.txt` — both sha256-verified against the published
     checksum files, extracted in a `mktemp -d` cleaned by trap, binary
     installed to the chosen prefix.
4. **Verify & report** — after installs, run each tool's version command;
   print a final per-tool status table; warn when the chosen prefix is not on
   PATH; exit nonzero if anything is still missing.

### Install prefix (Linux binaries)

- `--prefix DIR` (or `HC_INSTALL_PREFIX`) overrides the target directory.
- Default: `/usr/local/bin` when running as root, or when `sudo` exists AND
  `sudo -n true` succeeds (passwordless). Otherwise `~/.local/bin` with a
  clear note (no password prompts, no hangs — deterministic fallback).
- The prefix override is also the test hook: verification runs the real Linux
  install path into a temp prefix without touching the system.

### Checksums

- helm: `https://get.helm.sh/helm-vX.Y.Z-linux-<arch>.tar.gz.sha256sum` (hash
  is field 1) → compared with `sha256sum -c`.
- kubectl: `.../kubectl.sha256` (hash is the whole file) → same comparison.
- macOS needs no manual checksum work (brew verifies; tarball path unused).

### Portability

Same rules as the other scripts: `#!/usr/bin/env bash`, bash 3.2+ (no
associative arrays/`mapfile`/`${var,,}`), no GNU-only utilities on the macOS
path, `mktemp`+`trap` cleanup, quoted expansions, `set -Eeuo pipefail`.
`sha256sum` is used only on the Linux path (coreutils).

### Flags

- `--check` — assess only, exit 0 when everything satisfied, 1 otherwise.
- `--prefix DIR` — Linux binary install directory (also `HC_INSTALL_PREFIX`).
- `-h|--help`.

### Non-goals

- Installing/creating a k3s cluster (node setup — `docs/rpi4-k3s.md`).
- Managing kubeconfig contents (documented in README).
- Version pinning beyond "helm v3+/kubectl current stable" — the deploy
  target version is controlled by `IMAGE_TAG` in `.env`, not by local tools.

## Risks / trade-offs

- **Upstream binaries over distro packages on Linux**: version-agnostic and
  identical across distros (no repo minor-version pinning like
  `pkgs.k8s.io/core:/stable:/v1.37`), at the cost of manual updates —
  acceptable for a home-lab toolchain; `--check` makes drift visible.
- **GitHub API for the helm version**: unauthenticated rate limits (60/h) are
  plenty for a human-run script; on failure the script dies with a clear
  message rather than guessing.
- **Homebrew non-interactive install**: uses the installer's own
  `NONINTERACTIVE=1` mode; if it fails (rare), the script exits with the
  manual install URL instead of continuing half-configured.
