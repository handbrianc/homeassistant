# installer-cli Delta

## ADDED Requirements

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
