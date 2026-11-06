# Tasks: install-prereqs-script

## 1. Script

- [x] 1.1 `scripts/install-prereqs.sh`: detection (OS/arch/package manager), assessment, macOS Homebrew path, Linux binary path (helm/kubectl, sha256-verified, prefix logic), package-manager path (bash/git/curl), `--check`/`--prefix`/`--help`
- [x] 1.2 Wire missing-tool hints in `scripts/lib/common.sh` to the new script; README prerequisites updated

## 2. Verification

- [x] 2.1 `bash -n` + `shellcheck` clean
- [x] 2.2 `--check` on a machine missing helm/kubectl: reports missing, exits 1
- [x] 2.3 Real Linux install into a temp `--prefix` (network): helm+kubectl installed, checksums verified, versions respond; re-run is a no-op (idempotent)
- [x] 2.4 macOS path: logic review + portability audit (no GNU-only constructs; cannot execute on Linux — stated)

## 3. Close-out

- [x] 3.1 `openspec validate --all` passes; change archived
- [ ] 3.2 Committed
