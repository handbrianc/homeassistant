# installer-cli Specification

## Purpose
Portable bash scripts that install and update the Home Assistant Helm release
from this repository on any k3s (or other Kubernetes) cluster, driven entirely
by environment files, running on Linux and macOS with Homebrew bash.

## Requirements

### Requirement: Environment-file configuration

The installer SHALL resolve configuration with precedence: built-in defaults < .env < command-line flags.
All installer knobs come from environment files with a defined precedence.

#### Scenario: Defaults without .env
- **WHEN** no `.env` file exists and the installer runs
- **THEN** it proceeds with built-in defaults matching `.env.example` and
  prints which defaults it uses

#### Scenario: .env overrides defaults
- **WHEN** `.env` exists in the repository root
- **THEN** every `KEY=VALUE` line is sourced and overrides the built-in
  defaults; commented and blank lines are ignored

#### Scenario: Explicit flags win
- **WHEN** `--namespace` or `--release` is passed on the command line
- **THEN** the flag overrides the value from `.env`

### Requirement: Prerequisite checking

The installer SHALL verify the required toolchain before mutating the cluster.
The installer verifies its toolchain before touching the cluster.

#### Scenario: Missing tools
- **WHEN** `helm` or `kubectl` is not on PATH (and not running with `--dry-run`)
- **THEN** the script fails with a message naming the missing tool and the
  install command for Linux and macOS (Homebrew)

#### Scenario: Unreachable cluster
- **WHEN** the cluster is not reachable (and not running with `--dry-run`)
- **THEN** the script fails with a message pointing at `KUBECONFIG` before any
  mutation

### Requirement: Idempotent install

The installer SHALL converge the release idempotently via helm upgrade --install.
Installing must work on an empty cluster and be safely re-runnable.

#### Scenario: First install
- **WHEN** `install.sh` runs against a cluster without the release
- **THEN** it runs `helm upgrade --install` with `--create-namespace`, the
  configured timeout and the rollback-on-failure flag chosen by the detected
  helm generation (`--atomic` on helm 3, `--rollback-on-failure` on helm 4+,
  where `--atomic` was renamed and deprecated), waits for the StatefulSet
  rollout, and prints the access URL(s); in dry-run preview without a
  detectable helm, the helm 4 flag name is shown

#### Scenario: Re-run install
- **WHEN** `install.sh` runs again with the same configuration
- **THEN** it converges the release to the same state without errors

### Requirement: Update flow

The installer SHALL preserve data on update and SHALL print rollback instructions.
Updating must preserve data and allow rollback.

#### Scenario: Version bump
- **WHEN** `update.sh` runs with a new `IMAGE_TAG` in `.env`
- **THEN** it performs the same idempotent `helm upgrade --install`, waits for
  the rollout, and prints the release revision history plus the `helm rollback`
  command to revert

### Requirement: Dry-run mode

The installer SHALL support a dry-run mode that performs no cluster access.
Users must be able to preview every mutation without a cluster.

#### Scenario: Dry run without tools or cluster
- **WHEN** `install.sh` or `update.sh` runs with `--dry-run` (or `DRY_RUN=1`)
- **THEN** it prints the generated Helm values file and every helm/kubectl
  command it would run, performs no cluster access, and exits 0 even when
  `helm`/`kubectl` are not installed

#### Scenario: Full configuration preview
- **WHEN** the dry-run runs with `helm` available on PATH
- **THEN** it additionally renders the complete chart configuration via
  `helm template` with the exact values the upgrade would receive (generated
  values, any extra values file and the `--set` pairs, chart defaults merged
  in), at the chart's minimum supported Kubernetes version, printed between
  `BEGIN/END rendered manifests` markers — still with no cluster access

#### Scenario: Render failure is not fatal in dry-run
- **WHEN** the `helm template` preview fails
- **THEN** the dry-run warns that the generated values file remains
  authoritative and still exits 0

### Requirement: Linux and macOS portability

The scripts SHALL run under bash 3.2+ on both Linux and macOS (Homebrew bash).
Scripts must run on Linux bash and macOS with Homebrew bash.

#### Scenario: Portable constructs only
- **WHEN** the scripts are written
- **THEN** they use `#!/usr/bin/env bash`, stay compatible with bash 3.2+ (no
  associative arrays or other bash-4-only features), and avoid GNU-only
  utilities (`readlink -f`, `sed -i`, `date -d`, `stat -c`)

#### Scenario: Strict mode hygiene
- **WHEN** any installer script runs
- **THEN** it runs with `set -Eeuo pipefail`, removes temporary files via a
  `trap` on exit, and quotes all variable expansions

### Requirement: Generated values safety

The installer SHALL reject unsafe values before writing the generated values file.
Environment values are interpolated into a rendered values file.

#### Scenario: Unsafe value rejected
- **WHEN** a variable used in the generated values file contains quotes,
  backslashes, or newlines
- **THEN** the script aborts with a clear error naming the variable instead of
  producing broken YAML

#### Scenario: Ingress-fronted service is ClusterIP
- **WHEN** `INGRESS_ENABLED=true` and `SERVICE_TYPE` is set to anything other
  than `ClusterIP`
- **THEN** the script aborts with an error explaining that the ingress fronts
  the pod service and suggesting `SERVICE_TYPE=ClusterIP` or
  `INGRESS_ENABLED=false`
- **WHEN** `INGRESS_ENABLED=true` and `SERVICE_TYPE` is empty
- **THEN** `service.type: "ClusterIP"` is rendered (never the chart's
  LoadBalancer default)
- **WHEN** the ingress is disabled
- **THEN** the LoadBalancer/NodePort service types render as configured

### Requirement: Prerequisite installation
The project SHALL ship a portable script that installs its required toolchain
(`helm`, `kubectl`, bash 3.2+, `git`, `curl`) on Linux and macOS, so users do
not assemble the toolchain by hand.

#### Scenario: Linux installs official binaries
- **WHEN** the prerequisites script runs on Linux with `helm`/`kubectl` missing
- **THEN** it downloads the official upstream artifacts (helm release tarball
  from get.helm.sh, kubectl from dl.k8s.io stable), verifies each download
  against its published sha256 checksum, and installs the binaries into
  `/usr/local/bin` via sudo when passwordless sudo or root is available, or
  `~/.local/bin` otherwise with a PATH hint

#### Scenario: macOS uses Homebrew
- **WHEN** the prerequisites script runs on macOS
- **THEN** it uses Homebrew as the package manager (installing Homebrew
  non-interactively first when absent) and installs `helm`, `kubectl`, `bash`
  and `git` formulas that are not already present

#### Scenario: Idempotent and converging
- **WHEN** the prerequisites script runs again with all tools present at
  supported versions (helm v3+)
- **THEN** it installs nothing, reports every tool as satisfied, and exits 0

#### Scenario: Check-only mode
- **WHEN** the script runs with `--check`
- **THEN** it performs no installation, reports which requirements are met or
  missing, and exits nonzero when anything is missing

#### Scenario: Version verification
- **WHEN** the script installs a tool
- **THEN** it verifies the installed tool responds with a version before
  declaring success, and fails with a clear error otherwise

### Requirement: Cluster bootstrap

The project SHALL ship a script that bootstraps cluster access from the
client host and generates a cluster-aware installer configuration, so that
`helm`/`kubectl` work and `install.sh`/`update.sh` run without manual
configuration.

#### Scenario: Kubeconfig fetched from the control plane
- **WHEN** the script runs with `--host [user@]control-plane`
- **THEN** it fetches the k3s kubeconfig (`/etc/rancher/k3s/k3s.yaml` by
  default) via scp, falling back to `ssh host "sudo cat ..."` when the file is
  not directly readable, rewrites any `127.0.0.1`/`localhost` server URL to
  the control-plane address (preserving the port), installs it at the
  kubeconfig destination with mode 600, and validates cluster access with
  `kubectl get nodes` before proceeding

#### Scenario: Passwordless SSH to the control plane
- **WHEN** the script runs with `--host` and the local SSH key is missing
- **THEN** it generates an ed25519 key without passphrase, installs the public
  key into the control-plane host's `~/.ssh/authorized_keys` idempotently (no
  duplicates on re-run), first trying key-based (batch) auth and falling back
  to one interactive authentication, and verifies that passwordless SSH works
  before fetching anything

#### Scenario: Cluster review derives chart values
- **WHEN** the cluster is reachable and no ingress controller exists
- **THEN** the script derives values compatible with the cluster: node
  architecture (empty + warning when nodes are mixed-arch), the default
  storage class, LoadBalancer capability (assigned LoadBalancer ingress IPs or
  an `svclb` DaemonSet) with a NodePort fallback otherwise, the live release's
  image tag when the release already exists, the existing PVC's size and
  storage class, and the control-plane timezone (when SSH was used)

#### Scenario: Existing release state wins
- **WHEN** a Helm release with the configured name already exists in the
  namespace
- **THEN** `IMAGE_TAG` is taken from the live release (not the chart default)
  and `STORAGE_SIZE`/`STORAGE_CLASS` come from the existing PVC so an update
  never shrinks or moves storage

#### Scenario: Ingress controller defaults the ingress on
- **WHEN** an IngressClass is present on the cluster (Traefik preferred)
- **THEN** the generated configuration defaults `INGRESS_ENABLED=true` with
  the detected class, `INGRESS_TLS_ENABLED=true`,
  `INGRESS_TLS_SECRET_NAME=<release>-tls`,
  `INGRESS_TRUSTED_PROXIES=10.42.0.0/16` (k3s default pod CIDR, documented as
  adjustable), and `SERVICE_TYPE=ClusterIP` — the ingress fronts the pod
  service, so the LoadBalancer/NodePort derivation and the NodePort fallback
  do not apply (`NODE_PORT` is cleared) — leaving `INGRESS_HOST` empty for a
  catch-all rule
- **AND WHEN** the `certificates.cert-manager.io` CRD is present
- **THEN** the script reports that cert-manager issues the certificates and
  that setting `INGRESS_TLS_ISSUER` (with optional `INGRESS_TLS_ISSUER_KIND`)
  enables issuance
- **WHEN** the CRD is absent
- **THEN** the script warns that cert-manager is missing and the certificate
  will not be issued until it is installed
- **WHEN** no ingress controller is detected
- **THEN** the ingress and its TLS settings stay disabled and the
  LoadBalancer/NodePort derivation applies as before

#### Scenario: .env generated with backup
- **WHEN** configuration is written
- **THEN** an existing `.env` is first backed up to
  `.env.backup-<timestamp>` (`.N`-suffixed on same-second collisions), the new
  `.env` contains every variable from
  `.env.example` with cluster-derived values, every written value is checked
  to be YAML/shell-safe, and values containing spaces are double-quoted

#### Scenario: Secrets scaffolded without leaking values
- **WHEN** the secrets file is missing
- **THEN** it is scaffolded from `secrets.env.example` with mode 600; when it
  exists, only its key *names* are reported (cluster secret keys too), never
  any value

#### Scenario: Review-only mode
- **WHEN** the script runs without `--host` and kubectl already works
- **THEN** the SSH/fetch stages are skipped and only the review and
  configuration stages run

#### Scenario: Unusable kubeconfig is fatal
- **WHEN** the fetched kubeconfig does not validate against the cluster
  (`kubectl get nodes` fails)
- **THEN** the script aborts with a hint about the k3s `--tls-san` setting
  and the kubeconfig file is left in place for inspection

#### Scenario: End state ready for the installers
- **WHEN** the script completes successfully
- **THEN** `kubectl` and `helm` work against the cluster using the generated
  kubeconfig, `.env` is complete for `install.sh`/`update.sh`, the printed
  next steps name those scripts, and `--install` chains directly into
  `scripts/install.sh`

### Requirement: Uninstall flow

The project SHALL ship a script that removes the Home Assistant release
while preserving user data unless its deletion is explicitly requested.
`scripts/uninstall.sh` resolves the same configuration as the installer
(built-in defaults < .env < flags), removes the Helm release, cleans the
installer-applied Secrets, and treats the PVC as data that survives by
default.

#### Scenario: Release removed, data preserved
- **WHEN** the script runs and the release exists
- **THEN** it first protects the release's PVC(s) from helm's uninstall by
  annotating them `helm.sh/resource-policy=keep`, then runs
  `helm uninstall <release> -n <ns> --wait --timeout <HELM_TIMEOUT>`, and
  reports that the data (PVC) is preserved, with the reinstall and
  `--purge-data` commands

#### Scenario: Idempotent when the release is absent
- **WHEN** the script runs and no release with the configured name exists
- **THEN** it warns, skips the helm uninstall, still performs the requested
  Secret and PVC cleanup, and exits 0

#### Scenario: Data purge is explicit
- **WHEN** `--purge-data` (or `PURGE_DATA=true`) is set
- **THEN** the release's PVCs — selected by the
  `app.kubernetes.io/instance=<release>` label, including PVCs orphaned by an
  earlier protected uninstall — are deleted after the release removal, behind
  a warning that all Home Assistant data is lost; externally provided claims
  (`persistence.existingClaim`) are never touched

#### Scenario: Installer secrets cleaned
- **WHEN** the script runs without `--keep-secrets`
- **THEN** the `<release>-secrets` Secret and the ingress TLS Secret
  (`INGRESS_TLS_SECRET_NAME`, default `<release>-tls`) are deleted with
  `kubectl delete secret --ignore-not-found`, without printing any values
- **WHEN** `--keep-secrets` (or `KEEP_SECRETS=true`) is set
- **THEN** both Secrets are retained

#### Scenario: Namespace kept unless explicit
- **WHEN** the script runs without `--delete-namespace`
- **THEN** the namespace is left in place
- **WHEN** `--delete-namespace` (or `DELETE_NAMESPACE=true`) is set
- **THEN** the namespace is deleted last, with a warning that everything
  remaining inside it is removed with it

#### Scenario: Dry-run uninstall
- **WHEN** the script runs with `--dry-run` (or `DRY_RUN=1`)
- **THEN** it prints the configuration and every helm/kubectl command it
  would run, performs no cluster access, and exits 0 even when
  `helm`/`kubectl` are not installed

#### Scenario: Flag and environment equivalences
- **WHEN** `--namespace`/`--release` flags are passed
- **THEN** they override `.env` exactly as in `install.sh`; `--purge-data`,
  `--keep-secrets` and `--delete-namespace` accept the environment
  equivalents `PURGE_DATA`, `KEEP_SECRETS` and `DELETE_NAMESPACE` (flags win)

### Requirement: Credential handling

The installer SHALL apply credentials only through a Kubernetes Secret and SHALL NOT print secret values.
Credentials never live in git, chart values committed to the repo, or command
output.

#### Scenario: Secrets applied as Kubernetes Secret
- **WHEN** `secrets.env` (path from `SECRETS_FILE`) exists with non-comment
  `KEY=VALUE` lines
- **THEN** the script creates/updates a Kubernetes Secret named
  `<release>-secrets` in the target namespace using
  `kubectl create secret --from-env-file` piped through a client-side dry run
  to `kubectl apply`, without printing any secret values

#### Scenario: Missing secrets file
- **WHEN** the secrets file does not exist
- **THEN** the script warns, skips Secret creation, and renders the release
  with `envFromSecret=""` so the pod does not wait on a missing Secret

### Requirement: Ingress TLS certificate issuance

Ingress TLS certificates SHALL be issued exclusively by cert-manager: the
installer never applies a TLS Secret outside the chart's `Certificate`
resource, and never renders a self-signed fallback.

#### Scenario: Certificate issued via cert-manager only
- **WHEN** ingress TLS is enabled with `INGRESS_TLS_ISSUER` set
- **THEN** the generated values enable the chart's cert-manager `Certificate`
  (`ingress.certificate`) with `issuerRef` (name from `INGRESS_TLS_ISSUER`,
  kind from `INGRESS_TLS_ISSUER_KIND`, `ClusterIssuer` when empty), `dnsNames`
  (see below) and `secretName` equal to the Ingress `tls` secret name
  (`INGRESS_TLS_SECRET_NAME`, default `<release>-tls`); the
  `cert-manager.io/cluster-issuer` Ingress annotation is never rendered, so
  cert-manager issues exactly one Certificate. No `kubernetes.io/tls` Secret
  is created outside the Certificate resource

#### Scenario: TLS requires an issuer
- **WHEN** `INGRESS_TLS_ENABLED=true` with an empty `INGRESS_TLS_ISSUER`
- **THEN** the script aborts with an error naming `INGRESS_TLS_ISSUER` (the
  chart's Certificate requires an issuer name; there is no renderable
  half-state and no fallback certificate)

#### Scenario: Certificate DNS names configurable (wildcards)
- **WHEN** `INGRESS_TLS_DNS_NAMES` is set (comma-separated)
- **THEN** the Certificate renders those names verbatim as `dnsNames`,
  enabling wildcards (`INGRESS_TLS_DNS_NAMES="*.example.com,example.com"`)
  and multi-domain certificates
- **WHEN** `INGRESS_TLS_DNS_NAMES` is empty
- **THEN** `dnsNames` falls back to `INGRESS_HOST` (omitted when that is
  empty too — catch-all rule)
