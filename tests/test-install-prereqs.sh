#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2181,SC2319,SC1091
# Harness idiom: `[ cmd ]; chk $? "msg"` and literal librun snippets.
# =============================================================================
# tests/test-install-prereqs.sh — tests for scripts/install-prereqs.sh
#
# Layers (cluster safety; and no real network by default):
#   A  flags & --check   — machine-independent fake toolchain, no network
#   B  offline installs  — fake tarballs served by a curl mock that is the ONLY
#                          curl on PATH (nothing real can be fetched);
#                          checksum-mismatch abort + idempotent re-run asserted.
#                          Linux-gated (GNU sha256sum/tar semantics).
#   C  real downloads    — opt-in via HC_TEST_NETWORK=1; installs into a
#                          throwaway --prefix under $TESTS_TMP only.
# Nothing here touches a cluster; installs land only in $TESTS_TMP prefixes.
# macOS: sections A and C are portable; section B is Linux-only.
# =============================================================================
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$REPO_ROOT/scripts/install-prereqs.sh"
HOME_T="$TESTS_TMP/home-prereqs"
mkdir -p "$HOME_T"
DL="$TESTS_TMP/prereq-dl"      # served fixture files + fake payloads
mkdir -p "$DL"
PRQ_TMP="$TESTS_TMP/tmpdir"    # where the script's own download dir lands
mkdir -p "$PRQ_TMP"
TOOLS="$TESTS_TMP/tools"       # fake git + curl mock, first on PATH
mkdir -p "$TOOLS"

# Arch mapping mirroring the script's `uname -m` mapping.
case "$(uname -m)" in
  x86_64|amd64)  ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *)             ARCH="arm" ;;
esac

# --- fake tools: git (presence is all that is checked) + the curl mock --------
cat > "$TOOLS/git" <<'EOF'
#!/bin/sh
printf 'git version 2.99.0-fake\n'
EOF

cat > "$TOOLS/curl" <<'EOF'
#!/bin/sh
# Mock curl: serves URLs from fixture files under $HC_PREREQ_DL and logs every
# call to $HC_STUB_LOG. HC_STUB_BAD_SHA=1 poisons the helm checksum fixture to
# drive the mismatch abort. Unknown URLs exit 22 (curl's -f HTTP error) so a
# script change can never silently hit the real network.
echo "curl $*" >> "${HC_STUB_LOG:?}"
out=""; url=""; prev=""
for _a in "$@"; do
  if [ "$prev" = "-o" ]; then out="$_a"
  else
    case "$_a" in -*) : ;; *) url="$_a" ;; esac
  fi
  prev="$_a"
done
src=""
case "$url" in
  *"api.github.com/repos/helm/helm/releases/latest"*) src="$HC_PREREQ_DL/latest.json" ;;
  *"get.helm.sh/"*.tar.gz.sha256sum)
    if [ "${HC_STUB_BAD_SHA:-0}" = "1" ]; then
      src="$HC_PREREQ_DL/tarball.badsha256sum"
    else
      src="$HC_PREREQ_DL/tarball.sha256sum"
    fi ;;
  *"get.helm.sh/"*.tar.gz) src="$HC_PREREQ_DL/tarball.tgz" ;;
  *"dl.k8s.io/release/stable.txt") src="$HC_PREREQ_DL/stable.txt" ;;
  *"bin/linux/"*/kubectl.sha256) src="$HC_PREREQ_DL/kubectl.sha256" ;;
  *"bin/linux/"*/kubectl) src="$HC_PREREQ_DL/kubectl" ;;
  *)
    echo "curl-mock: no fixture for: $url" >&2
    exit 22
    ;;
esac
if [ ! -f "$src" ]; then
  echo "curl-mock: fixture missing: $src" >&2
  exit 22
fi
if [ -n "$out" ]; then cat "$src" > "$out"; else cat "$src"; fi
EOF
chmod 755 "$TOOLS/git" "$TOOLS/curl"

section "A: flags & --check (no network, fake toolchain)"

env -i PATH="$TOOLS:$BASE_PATH" HOME="$HOME_T" bash "$SCRIPT" --help \
  >"$TESTS_TMP/prq-help.out" 2>&1
[ $? = "0" ]; chk $? "--help exits 0"
chk_grep "$TESTS_TMP/prq-help.out" "Usage: scripts/install-prereqs.sh" "--help shows usage"

expect_fail "unknown flag rejected" env -i PATH="$TOOLS:$BASE_PATH" HOME="$HOME_T" \
  bash "$SCRIPT" --bogus
chk_grep "$TESTS_TMP/expect-fail.out" "Unknown argument" "unknown-flag message"

expect_fail "--prefix without a value rejected" env -i PATH="$TOOLS:$BASE_PATH" \
  HOME="$HOME_T" bash "$SCRIPT" --prefix
chk_grep "$TESTS_TMP/expect-fail.out" "--prefix requires a non-empty argument" \
  "empty --prefix message"

# --check with a fully-satisfied fake toolchain -> rc 0, installs nothing.
GOODBIN="$TESTS_TMP/goodbin"
mkdir -p "$GOODBIN"
cat > "$GOODBIN/helm" <<'EOF'
#!/bin/sh
case "$*" in *version*) printf 'v3.22.1-fake\n' ;; esac
EOF
cat > "$GOODBIN/kubectl" <<'EOF'
#!/bin/sh
case "$*" in *"version --client"*) printf 'Client Version: v1.99.0-fake\n' ;; esac
exit 0
EOF
chmod 755 "$GOODBIN/helm" "$GOODBIN/kubectl"
NEVER="$TESTS_TMP/never-prefix"
env -i PATH="$GOODBIN:$TOOLS:$BASE_PATH" HOME="$HOME_T" HC_INSTALL_PREFIX="$NEVER" \
  HC_STUB_LOG="$TESTS_TMP/prq-a.log" \
  bash "$SCRIPT" --check >"$TESTS_TMP/prq-check-ok.out" 2>&1
[ $? = "0" ]; chk $? "--check with all tools present exits 0"
chk_grep "$TESTS_TMP/prq-check-ok.out" "All prerequisites satisfied." "ok report"
chk_grep "$TESTS_TMP/prq-check-ok.out" "Check-only mode" "check-only announced"
chk_grep "$TESTS_TMP/prq-check-ok.out" "helm:    ok" "helm reported ok"
[ ! -e "$NEVER" ]; chk $? "--check installs nothing (prefix never created)"

# --check with broken tool fakes -> rc 1; the exit code matches the report
# (consistency assertion, not a machine-specific value).
BADBIN="$TESTS_TMP/badbin"
mkdir -p "$BADBIN"
cat > "$BADBIN/helm" <<'EOF'
#!/bin/sh
printf 'banana\n'
EOF
cat > "$BADBIN/kubectl" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod 755 "$BADBIN/helm" "$BADBIN/kubectl"
env -i PATH="$BADBIN:$TOOLS:$BASE_PATH" HOME="$HOME_T" HC_INSTALL_PREFIX="$NEVER" \
  HC_STUB_LOG="$TESTS_TMP/prq-a.log" \
  bash "$SCRIPT" --check >"$TESTS_TMP/prq-check-bad.out" 2>&1
_rc=$?
[ "$_rc" = "1" ]; chk $? "--check with broken toolchain exits 1 (got $_rc)"
chk_grep "$TESTS_TMP/prq-check-bad.out" "Missing requirements:" "missing list reported"
chk_grep "$TESTS_TMP/prq-check-bad.out" "helm:    MISSING" "helm MISSING"
chk_grep "$TESTS_TMP/prq-check-bad.out" "kubectl: MISSING" "kubectl MISSING"
chk_nogrep "$TESTS_TMP/prq-check-bad.out" "All prerequisites satisfied." \
  "no ok report on failure"

if [ "$(uname -s)" = "Linux" ] && command -v sha256sum >/dev/null 2>&1 \
   && command -v tar >/dev/null 2>&1; then
  section "B: offline installs (fake tarballs via the curl mock — no network)"

  # Build fake payloads and fixtures: a tiny helm (reporting a v3.* version so
  # the idempotent re-run skips) and a tiny kubectl, tarred exactly the way the
  # installer extracts them, plus every URL the installer fetches.
  mkdir -p "$DL/payload/linux-$ARCH"
  cat > "$DL/payload/linux-$ARCH/helm" <<'EOF'
#!/bin/sh
printf 'v3.99.9-fake\n'
EOF
  cat > "$DL/payload/kubectl" <<'EOF'
#!/bin/sh
case "$*" in
  *"version --client"*) printf 'Client Version: v1.33.1-fake\n' ;;
esac
exit 0
EOF
  chmod 755 "$DL/payload/linux-$ARCH/helm" "$DL/payload/kubectl"
  tar -czf "$DL/tarball.tgz" -C "$DL/payload" "linux-$ARCH"
  printf '{"tag_name": "v3.99.9-fake", "html_url": "x"}\n' > "$DL/latest.json"
  _sha="$(sha256sum "$DL/tarball.tgz" | cut -d' ' -f1)"
  printf '%s  helm-v3.99.9-fake-linux-%s.tar.gz\n' "$_sha" "$ARCH" > "$DL/tarball.sha256sum"
  printf '0000000000000000000000000000000000000000000000000000000000000000  helm\n' \
    > "$DL/tarball.badsha256sum"
  printf 'v1.33.1-fake\n' > "$DL/stable.txt"
  cp "$DL/payload/kubectl" "$DL/kubectl"
  sha256sum "$DL/kubectl" | cut -d' ' -f1 > "$DL/kubectl.sha256"

  PFX="$TESTS_TMP/prefix-offline"
  _prq() { # _prq OUTFILE PREFIX [KNOB=VALUE ...] — env -i; mock curl is the
    #        only curl on PATH, so no real fetch can happen.
    local _out="$1" _pfx="$2"
    shift 2
    env -i PATH="$TOOLS:$BASE_PATH" HOME="$HOME_T" TMPDIR="$PRQ_TMP" \
      HC_PREREQ_DL="$DL" HC_STUB_LOG="$TESTS_TMP/prq.log" "$@" \
      bash "$SCRIPT" --prefix "$_pfx" >"$_out" 2>&1
  }

  _prq "$TESTS_TMP/prq1.out" "$PFX"
  [ $? = "0" ]; chk $? "offline install succeeds end-to-end"
  chk_grep "$TESTS_TMP/prq1.out" "helm installed: v3.99.9-fake" "helm installed + version-verified"
  chk_regex "$TESTS_TMP/prq1.out" 'kubectl installed: .*v1.33.1-fake' "kubectl installed + version-verified"
  chk_grep "$TESTS_TMP/prq1.out" \
    "All prerequisites satisfied. Next: ./scripts/install.sh --dry-run" "final banner"
  [ -x "$PFX/helm" ]; chk $? "installed helm is executable"
  [ -x "$PFX/kubectl" ]; chk $? "installed kubectl is executable"
  [ "$("$PFX/helm" version --short)" = "v3.99.9-fake" ]; chk $? "installed helm reports the fake version"
  chk_grep "$TESTS_TMP/prq1.out" "was used for this run but is not on your PATH" "PATH hint printed"
  # Proof the mock — not the network — served every fetch:
  chk_grep "$TESTS_TMP/prq.log" "api.github.com" "mock served the GitHub release lookup"
  chk_grep "$TESTS_TMP/prq.log" "get.helm.sh" "mock served the helm tarball + checksum"
  chk_grep "$TESTS_TMP/prq.log" "dl.k8s.io" "mock served kubectl + checksum"
  # The script's own download dir must be cleaned on exit.
  [ -z "$(find "$PRQ_TMP" -maxdepth 1 -name 'ha-prereqs.*')" ]; chk $? "download dir cleaned on exit"

  # Idempotent re-run: the installed fakes report supported versions, so
  # nothing is re-resolved, re-downloaded or re-installed.
  env -i PATH="$PFX:$TOOLS:$BASE_PATH" HOME="$HOME_T" TMPDIR="$PRQ_TMP" \
    HC_PREREQ_DL="$DL" HC_STUB_LOG="$TESTS_TMP/prq.log" \
    bash "$SCRIPT" >"$TESTS_TMP/prq2.out" 2>&1
  [ $? = "0" ]; chk $? "idempotent re-run exits 0"
  chk_nogrep "$TESTS_TMP/prq2.out" "Downloading and verifying" "no re-download on re-run"
  chk_nogrep "$TESTS_TMP/prq2.out" "Resolving the latest helm release" "no re-resolution on re-run"
  chk_grep "$TESTS_TMP/prq2.out" "helm:    ok (v3.99.9-fake)" "installed helm recognized (v3.* check)"
  chk_grep "$TESTS_TMP/prq2.out" "All prerequisites satisfied." "re-run report ok"
  chk_nogrep "$TESTS_TMP/prq2.out" "was used for this run but is not on your PATH" \
    "no PATH hint when the prefix is already on PATH"

  # Checksum mismatch aborts before anything is installed.
  PFX2="$TESTS_TMP/prefix-badsha"
  _prq "$TESTS_TMP/prq-bad.out" "$PFX2" HC_STUB_BAD_SHA=1
  [ $? = "1" ]; chk $? "helm checksum mismatch aborts (rc 1)"
  chk_grep "$TESTS_TMP/prq-bad.out" "helm checksum mismatch" "mismatch message"
  [ ! -e "$PFX2/helm" ]; chk $? "no helm installed after mismatch"
  [ ! -e "$PFX2/kubectl" ]; chk $? "kubectl install never ran after mismatch"
else
  skip_note "offline download tests (Linux with sha256sum+tar only)"
fi

section "C: real downloads (opt-in: HC_TEST_NETWORK=1)"
if [ "${HC_TEST_NETWORK:-}" = "1" ] && command -v curl >/dev/null 2>&1 \
   && command -v git >/dev/null 2>&1; then
  NPFX="$TESTS_TMP/prefix-net"
  env -i PATH="$BASE_PATH" HOME="$HOME_T" TMPDIR="$PRQ_TMP" \
    bash "$SCRIPT" --prefix "$NPFX" >"$TESTS_TMP/prq-net.out" 2>&1
  [ $? = "0" ]; chk $? "real download install exits 0"
  [ -x "$NPFX/helm" ]; chk $? "real helm installed"
  _nh="$("$NPFX/helm" version --short 2>/dev/null || true)"
  case "$_nh" in
    v3.*|v4.*) chk 0 "real helm reports a supported version ($_nh)" ;;
    *)         chk 1 "real helm reports a supported version (got: ${_nh:-none})" ;;
  esac
  "$NPFX/kubectl" version --client >/dev/null 2>&1
  chk $? "real kubectl works"
  env -i PATH="$NPFX:$BASE_PATH" HOME="$HOME_T" TMPDIR="$PRQ_TMP" \
    bash "$SCRIPT" >"$TESTS_TMP/prq-net2.out" 2>&1
  [ $? = "0" ]; chk $? "real idempotent re-run exits 0"
  chk_nogrep "$TESTS_TMP/prq-net2.out" "Downloading and verifying" "real re-run downloads nothing"
else
  skip_note "real download test (set HC_TEST_NETWORK=1; needs curl+git)"
fi

finish
