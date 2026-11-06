# Design: uninstall-script

## Decision

One new script, `scripts/uninstall.sh`, mirroring `install.sh`'s structure
(same flag parsing, `load_env_file`/`apply_defaults`/flag-override order,
`assert_all_values_safe`, dry-run gate on toolchain checks) with three
uninstall-only switches parsed like the flags' env equivalents:
`PURGE_DATA`, `KEEP_SECRETS`, `DELETE_NAMESPACE` (strict `parse_bool`,
flags win). They are deliberately NOT part of the shared `.env` contract —
`bootstrap-cluster.sh` never writes them and `install.sh`/`update.sh` ignore
them.

1. **Data safety is the default.** The chart's PVC is an ordinary release
   resource (`pvc.yaml`, name `<fullname>-config`) without
   `helm.sh/resource-policy: keep`, so `helm uninstall` deletes it along with
   all Home Assistant data. The script therefore, only when the release
   exists and `--purge-data` is NOT set, annotates the release's PVCs
   `helm.sh/resource-policy=keep --overwrite` before the uninstall. Helm
   keeps annotated resources; `install.sh` (`helm upgrade --install`)
   re-adopts them on reinstall via their existing `meta.helm.sh/release-*`
   ownership labels. PVCs are discovered by the chart's
   `app.kubernetes.io/instance=<release>` label; externally provided claims
   (`persistence.existingClaim`) don't carry it and are never touched.

2. **Purge is explicit and works on orphans.** `--purge-data` skips the
   annotation, lets the uninstall do its thing, then re-lists the release's
   PVCs afterwards and deletes what remains (`--ignore-not-found`) — this
   also removes PVCs orphaned by an earlier protected uninstall, which is the
   normal way a user changes their mind. A loud all-data-lost warning prints
   before any deletion (and in dry-run). `helm uninstall --wait
   --timeout <HELM_TIMEOUT>` ensures the pod has released the PVC before any
   purge touches it.

3. **Secrets are cleaned by default.** `<release>-secrets` and the ingress
   TLS Secret (via `ingress_tls_secret_name`, so `INGRESS_TLS_SECRET_NAME`
   overrides apply) are `kubectl delete secret ... --ignore-not-found` —
   installer-applied resources helm does not own. A failure here is a
   warning with the manual command, not a fatal error (the release is
   already gone). Values are never printed.

4. **Idempotent.** Release-absent (`helm list -n <ns> --short` awk check,
   bootstrap's idiom) → warning, skip uninstall, still run the requested
   cleanups, exit 0. Second run converges: secrets `--ignore-not-found`,
   purge re-list empty.

5. **Dry-run parity.** Toolchain/cluster checks and the release-existence
   check are printed as would-run commands instead of executed; every
   mutating command is printed with the `[dry-run]` prefix; exits 0 with no
   helm/kubectl on PATH.

## Alternatives rejected

- Add `helm.sh/resource-policy: keep` to `pvc.yaml`: protects pure-helm users
  too, but silently changes chart upgrade/uninstall semantics for every
  existing user and expands the change into the chart spec; the uninstall
  script achieves the same guarantee where the installer is used, and the
  README documents the manual annotation for pure-helm users.
- Interactive "really delete data?" prompt: the project's scripts are
  non-interactive (cron-friendly); an explicit flag is the established
  confirmation mechanism (`DRY_RUN`, `--values`).
- `helm uninstall --ignore-not-found` instead of the existence check: the
  check distinguishes "uninstalled" from "already absent" in the output, and
  the annotate step needs to know whether the release exists anyway.
