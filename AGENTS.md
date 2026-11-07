# AGENTS.md

Orientation for AI coding agents in this repository. Read `README.md` first;
project constraints also live in `openspec/config.yaml` (OpenSpec injects them
into change artifacts).

## What this is

A Helm chart (`charts/homeassistant/`) plus portable bash installers
(`scripts/`: install / update / uninstall / bootstrap-cluster / install-prereqs)
that install and update Home Assistant on a k3s/RPi4 cluster. Configuration
flows through env vars with precedence `built-in defaults < .env < CLI flags`
(implemented in `scripts/lib/common.sh`). Secrets reach HA via `!env_var` in
`configuration.yaml`, sourced from a Kubernetes Secret (`secrets.env`).

## Commands

```bash
env PATH="$HOME/.local/bin:$PATH" tests/run-tests.sh   # full suite (on this workstation helm/kubectl live in ~/.local/bin, not on PATH)
tests/run-tests.sh chart            # subset: common|install|update|bootstrap|install-prereqs|chart
shellcheck -x scripts/*.sh scripts/lib/*.sh tests/*.sh tests/stubs/*
env PATH="$HOME/.local/bin:$PATH" DRY_RUN=1 bash scripts/install.sh   # preview: renders values + full helm template, touches nothing
```

- Gate before any commit: full suite green + shellcheck clean. Baseline ~578
  checks (Nov 2026) under helm v4; `HELM_BIN=/path/to/helm` pins the helm used.
- The suite includes a `bash -n` syntax gate and a **leak check** that fails if
  a test creates repo-root `.env*`/`secrets.env*`. Network downloads are
  opt-in only: `HC_TEST_NETWORK=1 tests/run-tests.sh install-prereqs`.
- `scripts/uninstall.sh` removes the release but preserves data by default.

## Non-negotiables

- **Test code must never touch a cluster.** The suite is dry-run/mock-only by
  design (see `tests/README.md`): `env -i` environments put committed stubs
  first on PATH so real `helm`/`kubectl`/`ssh` are unreachable even on a
  machine with a live cluster. Preserve that guarantee in any change.
- **`.env` and `secrets.env` are live-cluster config and credentials** —
  git-ignored; never commit them, never echo their values into chat or logs.
  Secret values for API operations go through a private secret channel, never
  the chat.
- **Never kill `helm upgrade` mid-run.** With `--rollback-on-failure`, a killed
  upgrade uninstalls the release; the static iSCSI PV then goes `Released` and
  the PVC cannot rebind until the PV's `spec.claimRef.uid`/`resourceVersion`
  are cleared (Retain keeps the LUN; recovery procedure used live — see
  `openspec/changes/archive/2026-11-06-*` design notes). First-time image
  pulls take >5 min: run installs backgrounded with long timeouts.
- Bash 3.2+ compatibility (macOS system bash): no associative arrays or other
  bash-4-isms, no GNU-only utilities.

## Home Assistant ≥ 2026.11 (hard-earned)

- HTTP integration settings moved into the `/config/.storage/http` store with
  stable/pending slots. The YAML `http:` block is migrated **once** into a
  pending config that runs as a **5-minute trial** and is auto-reverted
  (`not_promoted` + self-restart) unless promoted in the UI — unreachable on a
  headless install, which left installs answering HTTP 400 behind the ingress
  forever. After that migration HA ignores YAML `http:` entirely.
- The chart therefore seeds the store's stable slot on first boot
  (`templates/configmap.yaml` `storage-http` key + per-file init-container
  copy). The seed is **version-gated** (semver ≥ 2026.11.0 or non-semver tag):
  HA raises `UnsupportedStorageVersionError` for store files newer than the
  running version supports, so never seed unconditionally — and never
  downgrade HA below 2026.11 while a store file exists without deleting it.
- Diagnose live HA behavior against the source installed in the pod
  (`kubectl exec homeassistant-0 -- cat /usr/src/homeassistant/...`), not
  web knowledge — version truth settles questions fast.

## Live cluster (the real deployment target)

- kubeconfig `~/.kube/config` (`.env` sets `KUBECONFIG`); release
  `homeassistant` in ns `homeassistant`; single-replica StatefulSet; static
  iSCSI PV (`Retain`) on the NAS; ingress class `traefik`; pod CIDR
  `10.42.0.0/16` (trusted_proxies).
- DNS: pihole resolvers at 192.168.0.10 and 192.168.0.12. Every ingress-fronted
  service CNAMEs to `ingress.internal.earthenwire.com` (A → 192.168.0.11).
  Records are managed through the pihole v6 REST API (`POST /api/auth` →
  `X-FTL-SID`/`X-FTL-CSRF` headers; `PATCH /api/config` with the FULL
  `cnameRecords` array, read-modify-write). `nebula-sync` replicates
  pihole→pihole2 hourly; restart its deployment to force a run. FTL restarts
  around config changes cause transient empty DNS answers — re-check before
  concluding failure.
- This workstation's `/etc/hosts` carries cluster aliases: `getent`/`curl` may
  resolve from files, not DNS. Use `dig @192.168.0.10` for DNS truth.
- Installer runs against the cluster are real operations (user-approved);
  all other cluster work stays read-only (`get`/`describe`/`logs`/in-pod exec
  for inspection).

## OpenSpec workflow (all behavior changes)

- Flow: `openspec new change <name>` → proposal → spec delta → design → tasks
  → `openspec validate --all` → implement → `openspec archive <name> --yes`
  (syncs main specs + moves to `changes/archive/`) → one commit including the
  archive dir. The `opsx-*` commands in `.opencode/` drive this.
- Validator rules that bite: a MODIFIED requirement block must keep every
  existing scenario title verbatim; the same requirement may not appear in
  both REMOVED and ADDED; adding scenarios inside MODIFIED is fine.
  `#### Scenario:` needs exactly four hashes.

## Chart conventions

- `values.yaml` `image.tag` is pinned and must equal `Chart.yaml` appVersion
  (test-enforced).
- Bootstrap seeding is per-file and idempotent: each seed is written only when
  its own target is missing (`configuration.yaml`, `.storage/http`); the store
  seed additionally requires ingress + non-empty `trustedProxies` + the
  version gate (`homeassistant.httpStoreSeedEnabled` helper).
- The cert-manager Certificate and the Ingress `tls` block must reference the
  same Secret name; the issuer (`INGRESS_TLS_ISSUER`) must exist on the
  cluster or issuance stalls with only a Pending Certificate as evidence.
