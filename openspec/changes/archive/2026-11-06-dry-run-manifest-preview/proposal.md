# Proposal: dry-run-manifest-preview

## Why

`install.sh`/`update.sh --dry-run` today print only the *sparse* generated
values file (the non-empty overrides) plus the command list. The chart's own
defaults (image, probes, resources, persistence, pod security...) are merged
in by helm at upgrade time and are invisible in the preview, so the dry-run
does not answer "what exactly will the cluster get?".

## What Changes

- `scripts/lib/common.sh`: new `dry_run_render_manifests` — dry-run only.
  When `helm` is on PATH it renders the complete chart configuration via
  `helm template` with the exact values the real upgrade would receive
  (generated values + extra values + `--set` pairs), printing the result
  between `BEGIN/END rendered manifests` markers. It renders at the chart's
  minimum supported Kubernetes version parsed from `Chart.yaml` `kubeVersion`
  (needed because helm 4's built-in template default, v1.20, is older than
  the chart's `>=1.25.0-0` floor). No cluster access. A failed render warns
  instead of aborting. Without helm, it prints a note that the generated
  values remain authoritative.
- `scripts/install.sh` + `scripts/update.sh`: call it at the end of their
  dry-run blocks.
- Tests: stub `helm template` knob, unit section in `test-common.sh`,
  dry-run asserts in `test-install.sh` and `test-update.sh`.

## Capabilities

### installer-cli

MODIFIED requirement: "Dry-run mode" — full-configuration preview scenario
added alongside the existing no-tools behavior (unchanged).

## Impact

- Affected specs: `installer-cli` (one requirement).
- Affected code: one shared helper, two call sites, one stub knob, three
  test files. No chart changes; no new env vars; behavior without helm is
  unchanged apart from one informational note line.
