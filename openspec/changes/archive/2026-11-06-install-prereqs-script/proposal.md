# Proposal: install-prereqs-script

## Why

Deploying this repository requires `helm`, `kubectl`, bash 3.2+, `git` and
`curl`, and installing them differs by OS (apt/binary on Linux, Homebrew on
macOS). The installer scripts fail with hints only after the user runs them.
A single prerequisites installer removes the manual step and keeps Linux and
macOS on supported tool versions.

## What Changes

- Add `scripts/install-prereqs.sh`: detects OS/arch/package manager and
  installs what is missing.
  - macOS: Homebrew is the preferred path (installs Homebrew itself if
    absent); `helm`, `kubectl`, `bash`, `git` via brew.
  - Linux: official upstream binaries for `helm` (get.helm.sh release tarball)
    and `kubectl` (dl.k8s.io stable), sha256-verified, installed to
    `/usr/local/bin` (via sudo when available) or `~/.local/bin` as fallback;
    `bash`/`git`/`curl` via the distro package manager (apt/dnf/pacman/zypper/apk)
    when missing.
- Add `--check` mode (verify only, exit 0/1) and `--prefix DIR` override for
  the Linux binary install location.
- Idempotent: tools already present at a supported version are skipped;
  versions are verified after any install.
- Wire the installer scripts' missing-tool hints to the new script; update
  README prerequisites to point at it.

## Capabilities

### installer-cli

Existing capability, extended. Adds prerequisite *installation* next to the
existing prerequisite *checking*: a portable installer script for the
toolchain on Linux and macOS.

## Impact

- Affected specs: `installer-cli` (one ADDED requirement).
- Affected code: new `scripts/install-prereqs.sh`; hint text in
  `scripts/lib/common.sh`; README prerequisites section. No behavior change
  to install/update flows.
