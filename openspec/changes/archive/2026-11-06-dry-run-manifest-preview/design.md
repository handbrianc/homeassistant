# Design: dry-run-manifest-preview

## Decision

One shared helper, `dry_run_render_manifests` in `scripts/lib/common.sh`,
called at the end of both dry-run blocks:

- Gate on `command -v helm` so the zero-toolchain dry-run (a spec scenario)
  stays intact: without helm it prints one note and returns.
- Arguments mirror `helm_release_args` minus the upgrade-only flags:
  `template <release> <chart> --namespace <ns> -f <generated> [-f <extra>]
  --set envFromSecret=... --set image.tag=...`.
- `--kube-version` is parsed from the chart's own `Chart.yaml` `kubeVersion`
  constraint (`>=1.25.0-0` → `1.25.0`) with the same awk idiom bootstrap uses
  for the image tag. Rationale: helm 4's built-in template capability default
  (v1.20.0) is older than the chart floor, so a plain render hard-fails on
  helm 4 while the real upgrade against the actual cluster passes. Rendering
  at the chart minimum is deterministic across helm versions and this chart
  has no `.Capabilities` branches, so the output is identical at any
  supported version. Unparseable constraints simply omit the flag (helm's
  own check then applies).
- The rendered output is framed with `----- BEGIN/END rendered manifests -----`
  markers, mirroring the generated-values markers. A failing render prints a
  warning and the dry-run still exits 0.

## Rationale

- `helm template` is fully offline, so the "no cluster access" guarantee
  holds.
- The scripts lane never sets `secretEnv`, so rendered manifests cannot
  contain secret material.
- Reusing the array-building style of `helm_release_args` keeps word
  splitting and YAML-safety guarantees intact.

## Alternatives rejected

- Dumping merged values as YAML: helm has no offline values-dump; it would
  require reimplementing the merge in bash.
- Always passing a hardcoded `--kube-version 1.31.0`: lies about what the
  user's cluster validates against and duplicates the chart contract in a
  second place; parsing the chart's own floor keeps one source of truth.
