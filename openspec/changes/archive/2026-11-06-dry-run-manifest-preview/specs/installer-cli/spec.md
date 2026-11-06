# installer-cli Delta

## MODIFIED Requirements

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
