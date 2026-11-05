# Proposal: initialize-homeassistant-k3s

## Why

The project starts empty. We need a repeatable, secret-safe way to install and
update Home Assistant on a k3s cluster running on Raspberry Pi 4 nodes.
Manual installs drift; a Helm chart plus portable installer scripts make the
deployment declarative, upgradable and roll-back-able.

## What Changes

- Add a standalone Helm chart `charts/homeassistant` with sane defaults for
  Raspberry Pi 4 (arm64 image, modest resources, k3s-friendly service and
  storage defaults).
- Add portable bash installer scripts `scripts/install.sh`, `scripts/update.sh`
  and a shared `scripts/lib/common.sh` that run on Linux and macOS
  (Homebrew bash).
- Configuration and secrets flow through environment variables (12-factor):
  installer config via `.env` (see `.env.example`), credentials via
  `secrets.env` applied as a Kubernetes Secret and exposed as environment
  variables that Home Assistant reads with `!env_var` in `configuration.yaml`.
- Add ignore files (`.gitignore`, `.dockerignore`, chart `.helmignore`) so
  secrets and local state cannot be committed or packaged.
- Add docs: README quickstart, 12-factor compliance mapping, RPi4/k3s node prep.

## Capabilities

### homeassistant-chart

New capability. The Helm chart that renders the Home Assistant workload:
single-replica StatefulSet, PVC persistence at `/config`, environment-driven
configuration, probes, service exposure, optional ingress/hostNetwork/USB
devices, first-boot bootstrap configuration.

### installer-cli

New capability. The bash installer scripts: environment-file configuration,
prerequisite checks, Kubernetes Secret management from `secrets.env`,
idempotent install/update via `helm upgrade --install`, dry-run mode,
Linux/macOS portability.

## Impact

- Affected specs: none (both capabilities are new).
- Affected code: new files only — `charts/homeassistant/**`,
  `scripts/**`, `docs/**`, `README.md`, `.env.example`, `secrets.env.example`,
  ignore files. Nothing existing is modified or removed.
