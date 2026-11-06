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

### Requirement: Secret handling

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

### Requirement: Idempotent install

The installer SHALL converge the release idempotently via helm upgrade --install.
Installing must work on an empty cluster and be safely re-runnable.

#### Scenario: First install
- **WHEN** `install.sh` runs against a cluster without the release
- **THEN** it runs `helm upgrade --install` with `--create-namespace`,
  `--atomic` and the configured timeout, waits for the StatefulSet rollout,
  and prints the access URL(s)

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
