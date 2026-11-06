# Design: helm4-rollback-flag

## Decision

Version-aware flag selection inside the shared argument builder
(`helm_release_args` in `scripts/lib/common.sh`), so both `install.sh` and
`update.sh` get the right flag with one implementation:

- `require_helm` (both scripts already call it before any helm use) caches
  the parsed major version in `HC_HELM_MAJOR`.
- `helm_major_version` resolves the major version from that cache, falling
  back to a live `helm version --short` parse; it yields "" when helm is
  absent or unparseable.
- Flag mapping: `3` → `--atomic`; anything else (4+ or undetectable) →
  `--rollback-on-failure`.

## Rationale

- Undetectable helm (dry-run without a toolchain — the suite's zero-toolchain
  dry-run layer, and users previewing before installing prereqs) previews the
  helm 4 name: prereqs installs helm 4 today, so the preview matches the
  likely real run; a live helm is always detected correctly, so a real run
  never sends the wrong flag.
- `helm upgrade --install` only (never `helm install`): on helm 4 the old
  `--atomic` binding still exists for `upgrade` (deprecated warning), so this
  is warning-hygiene + future-proofing, not a hard failure today.
- Helm 3 compatibility is preserved byte-for-byte (`--atomic`), matching the
  spec scenario and existing v3 test expectations.

## Alternatives rejected

- Keep `--atomic` everywhere: every helm-4 run prints a deprecation warning.
- Always `--rollback-on-failure`: breaks helm 3 (unknown flag).
- Shell-alias wrapper mapping flags: invisible magic, harder to test.
