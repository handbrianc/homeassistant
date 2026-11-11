# Changelog

All notable changes to this project are documented in this file. The format
is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). The
project has no releases yet, so sections are dated by change instead of
versioned.

## [Unreleased]

### Added

- CI workflow (GitHub Actions): shellcheck plus the full test suite on every
  push to `main` and on pull requests; helm is pinned to the version the
  test baseline was audited with, so the chart contract tests run.
- `.markdownlint.json` codifying the documentation style.

### Changed

- `install.sh` and `update.sh` share their deployment flow through the new
  `scripts/lib/deploy.sh` (behavior-preserving refactor; the entry scripts
  shrank from 272/230 to 155/113 lines and duplication dropped from 7.61%
  to 2.53%).

### Fixed

- `docs/12-factor.md` now names the correct rollback flag per helm major
  version (`--atomic` on helm 3, `--rollback-on-failure` on helm 4+).
- The README repository tree lists `scripts/uninstall.sh`.

## 2026-11-07

### Added

- Chart: seed the Home Assistant HTTP config store (stable slot) on first
  boot — reverse-proxy trust without HA ≥ 2026.11's 5-minute trial and
  auto-revert, which left headless installs answering HTTP 400 behind the
  ingress.

## 2026-11-06

### Added

- `scripts/bootstrap-cluster.sh` — one-time SSH access bootstrap, kubeconfig
  fetch, cluster review, and `.env`/`secrets.env` scaffolding (idempotent).
- `scripts/install-prereqs.sh` — portable, idempotent helm/kubectl/bash
  installer for Linux and macOS.
- `tests/` — cluster-safe test suite: dry-run and mocks only, committed
  stubs, `bash -n` syntax gate and repo leak check.
- Chart: cert-manager Certificate resource for the ingress TLS secret.
- `install.sh --dry-run` renders the full chart configuration (helm template
  preview) without needing cluster access.
- Bootstrap defaults ingress on with TLS when an ingress controller is
  detected.

### Changed

- Helm 4 support: `--rollback-on-failure` on helm 4, `--atomic` kept on
  helm 3.
- Installer traffic goes ClusterIP behind the ingress; TLS is cert-manager
  only, with wildcard DNS names.
- Bootstrap installs the client kubeconfig as `~/.kube/config` (the kubectl
  default; default name `~/.kube/config.yaml`).
- `uninstall.sh` removes the release with data preserved by default.

### Fixed

- Corrected Linux install guidance for helm v4.

## 2026-11-05

### Added

- Initial commit: Home Assistant on k3s — Helm chart, installer scripts,
  OpenSpec specs.
