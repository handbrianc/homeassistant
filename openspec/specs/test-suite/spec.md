# test-suite Specification

## Purpose
A committed, cluster-safe test suite (tests/run-tests.sh) covering every
script in the repository and the chart contract: dry-run based where the
scripts offer it, hermetic mock binaries everywhere else, portable across
Linux and macOS with bash 3.2+. The suite never touches a real cluster.

## Requirements

### Requirement: No cluster modification

The suite SHALL NOT modify any cluster. Tests SHALL verify cluster-facing
behavior only through dry-run modes and mock binaries, and the runner SHALL
detect repo-tree leakage.

#### Scenario: Dry-run tests need no cluster
- **WHEN** `install.sh`/`update.sh` are tested via their `--dry-run` mode
- **THEN** the tests pass with no `helm`/`kubectl` installed and perform no
  network or cluster access at all

#### Scenario: Mocks shadow real tools
- **WHEN** a test exercises a cluster-touching code path
- **THEN** it runs inside an `env -i` environment whose `PATH` starts with
  `tests/stubs` (logged, env-knobbed mock binaries), so real `helm`/`kubectl`
  on the machine can never be invoked, and the stub log records every
  simulated call as proof that mocks ran

#### Scenario: No repo leakage
- **WHEN** the suite finishes
- **THEN** the runner verifies that no new artifacts (e.g. `.env`,
  `secrets.env`, backups) appeared in the real repository tree, and fails if
  a test leaked any

#### Scenario: Network access is opt-in
- **WHEN** the suite runs with default settings
- **THEN** no test performs downloads; the prerequisites installer's real
  download path runs only when `HC_TEST_NETWORK=1` is set explicitly

### Requirement: Coverage of all scripts

Every script SHALL have a committed test file, and the runner SHALL execute
all of them by default and any subset by name.

#### Scenario: Full-suite run
- **WHEN** `tests/run-tests.sh` runs without arguments
- **THEN** it runs the static gate (`bash -n`, `shellcheck` when available)
  and every `tests/test-*.sh`, printing per-test results and exiting nonzero
  when any check fails

#### Scenario: Subset run
- **WHEN** names are passed (e.g. `tests/run-tests.sh bootstrap common`)
- **THEN** only the matching test files run

### Requirement: Graceful degradation and portability

The suite SHALL run on Linux and macOS with bash 3.2+ and SHALL skip, not
fail, sections whose optional tooling is absent.

#### Scenario: Optional tool absent
- **WHEN** the chart contract tests run without helm (or `shellcheck` is not
  installed)
- **THEN** the section is skipped with an explicit SKIP notice instead of
  failing, and the suite still reports an accurate pass/fail summary

#### Scenario: Environment-dependent checks stay portable
- **WHEN** a check's expected outcome depends on the host (e.g. `--check`
  reporting missing tools)
- **THEN** the test asserts consistency (exit status matches the report)
  rather than a machine-specific value, and Linux-only sections (checksum
  verification) skip on non-Linux hosts
