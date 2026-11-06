# Spec Delta: installer-cli

## ADDED Requirements

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
