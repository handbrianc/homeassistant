# Proposal: uninstall-script

## Why

There is no way to remove Home Assistant today except hand-writing
`helm uninstall` — and a plain `helm uninstall` **deletes the chart's PVC**
(it is an ordinary release resource with no `helm.sh/resource-policy: keep`),
destroying all Home Assistant data (configuration, users, history). The
README's manual uninstall snippet is wrong about this. Removing the release
also leaves the installer-applied Secrets (`<release>-secrets`, the ingress
TLS Secret) behind, since they are applied via `kubectl` outside helm.

## What Changes

- New `scripts/uninstall.sh` with the installer's configuration model
  (built-in defaults < `.env` < flags; `--namespace`/`--release`; `--dry-run`
  / `DRY_RUN=1` with no toolchain and no cluster access):
  - **Data preserved by default**: when the release exists, its PVC(s)
    (label `app.kubernetes.io/instance=<release>`; externally provided
    claims are never touched) are annotated
    `helm.sh/resource-policy=keep` before
    `helm uninstall <release> -n <ns> --wait --timeout <HELM_TIMEOUT>`, and
    remain on disk — `scripts/install.sh` re-adopts them on reinstall.
  - `--purge-data` (`PURGE_DATA=true`): deletes the release's PVCs after the
    uninstall (catches PVCs orphaned by an earlier protected uninstall too),
    behind a loud all-data-lost warning.
  - Secrets `<release>-secrets` and `INGRESS_TLS_SECRET_NAME`
    (default `<release>-tls`) are deleted with `--ignore-not-found` unless
    `--keep-secrets` (`KEEP_SECRETS=true`); values never printed.
  - `--delete-namespace` (`DELETE_NAMESPACE=true`) deletes the namespace
    last, with a warning that everything remaining inside goes with it.
  - Release absent → warning, cleanups still offered, exit 0 (idempotent).
- `tests/stubs/helm`: `uninstall` case with a failure knob;
  `tests/stubs/kubectl`: `-o name` PVC listing case.
- `tests/run-tests.sh`: coverage pair `uninstall:test-uninstall`.
- README: rewrite the Uninstalling section around the script (and correct
  the wrong plain-`helm uninstall` claim).

## Capabilities

### installer-cli

ADDED requirement: "Uninstall flow" (data-preserving default, explicit purge,
secret cleanup, optional namespace removal, dry-run guarantees, flag/env
equivalences).

## Impact

- Affected specs: `installer-cli` (1 new requirement).
- Affected code: one new script, two stub extensions, runner coverage list,
  one new test file, README. No chart change (protection is applied at
  uninstall time; the chart keeps its current semantics for pure-helm users,
  documented in the README).
