# Contributing

Thanks for helping improve the Home Assistant on k3s project. This file covers
development setup, the quality gates every change must pass, and the workflow
for behavior changes.

## Repository layout

```text
charts/homeassistant/   Helm chart (single-replica StatefulSet, PVC, env config)
scripts/                installer entry points (install/update/uninstall/
                        bootstrap-cluster/install-prereqs)
scripts/lib/            shared shell libraries sourced by the entry scripts
tests/                  cluster-safe test suite + committed stubs
docs/                   12-factor mapping, RPi4/k3s node preparation
openspec/               OpenSpec specs, changes and archive
```

## Development environment

- bash 3.2+ (macOS: install a current bash via Homebrew) and shellcheck.
- Helm v3 or v4 and kubectl are optional: when helm is on PATH, the chart
  lint/template contract tests run; every cluster call is served by the
  committed stubs, so the suite never needs — or touches — a cluster.

## Running the tests

```bash
tests/run-tests.sh          # full suite + bash -n gate + leak check
tests/run-tests.sh chart    # subsets: common|install|update|bootstrap|
                            #          install-prereqs|chart
shellcheck -x scripts/*.sh scripts/lib/*.sh tests/*.sh tests/stubs/*
```

- Network downloads are opt-in only:
  `HC_TEST_NETWORK=1 tests/run-tests.sh install-prereqs`.
- Preview an install without touching anything:
  `DRY_RUN=1 bash scripts/install.sh`.

## Gates

Every commit must pass the **full test suite** and **shellcheck** with zero
findings. CI runs the same gates on every push and pull request.

## Non-negotiables

- **Tests never touch a cluster.** The suite is dry-run/mock-only by design:
  `env -i` environments put the committed stubs first on PATH so real
  `helm`/`kubectl`/`ssh` are unreachable even on a machine with a live
  cluster. Preserve that guarantee in any change.
- **`.env` and `secrets.env` are credentials.** Never commit them; never echo
  their values into logs, issues or pull requests.
- **Bash 3.2+ compatibility** (macOS system bash): no associative arrays or
  other bash-4-isms, no GNU-only utilities.
- **`values.yaml` `image.tag` stays pinned** and equal to `Chart.yaml`
  `appVersion` (test-enforced).
- **Never kill `helm upgrade` mid-run.** With `--rollback-on-failure`, a
  killed upgrade uninstalls the release; a statically provisioned PV can then
  fail to rebind. See the design notes under `openspec/changes/archive/` for
  the recovery procedure.

## Workflow for behavior changes (OpenSpec)

All behavior changes flow through OpenSpec:

1. `openspec new change <name>` — proposal, spec delta, design, tasks
2. `openspec validate --all`
3. implement, keeping the test suite green
4. `openspec archive <name> --yes` (syncs the main specs, moves the change to
   `changes/archive/`)
5. one commit including the archive directory

Validator gotchas: a MODIFIED requirement block must keep every existing
scenario title verbatim; the same requirement may not appear in both REMOVED
and ADDED; `#### Scenario:` needs exactly four hashes. Pure refactors and
documentation changes do not need a change entry.

## Pull requests

- Keep them small and focused; behavior changes land with their spec delta
  and tests.
- Commit subjects follow the existing history: `<area>: <imperative summary>`
  (areas: `chart:`, `installer:`, `install:`, `update:`, `bootstrap:`,
  `uninstall:`).
- Run the gates before pushing; CI must pass on your branch.
