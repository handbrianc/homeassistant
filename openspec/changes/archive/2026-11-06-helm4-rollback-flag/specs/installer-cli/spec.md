# installer-cli Delta

## MODIFIED Requirements

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
