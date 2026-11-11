# shellcheck shell=bash disable=SC2181,SC2319,SC1091
# =============================================================================
# tests/lib.sh — shared helpers for tests/test-*.sh (bash 3.2+, Linux/macOS)
#
# Provides per-file PASS/FAIL/SKIP counters, tiny assertions, throwaway repo
# copies and one temp root cleaned on exit.
#
# Test files run WITHOUT `set -e` (failures must be counted, not fatal) and
# with `set -u`. CLUSTER SAFETY: tests never put real helm/kubectl on PATH —
# e2e runs use `env -i` with $STUBS FIRST on PATH, and BASE_PATH (the "system
# tools" PATH) is built without kubectl/helm so hosts that preinstall them
# don't leak in; see tests/README.md.
# =============================================================================

REPO_ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)" || exit 1
TESTS_DIR="$REPO_ROOT/tests"
STUBS="$TESTS_DIR/stubs"

T_PASS=0
T_FAIL=0
T_SKIP=0

TESTS_TMP="$(mktemp -d "${TMPDIR:-/tmp}/ha-tests.XXXXXX")" || exit 1
trap 'rm -rf "$TESTS_TMP"' EXIT

# BASE_PATH — hermetic "system tools" PATH: a directory of symlinks to every
# executable in /usr/bin and /bin EXCEPT the cluster tools. Hosts may
# preinstall kubectl or helm there (GitHub Actions runners ship kubectl in
# /usr/bin), and tests that exercise the missing-tool paths require those
# commands to be genuinely absent. Test files see BASE_PATH exactly as
# before; $STUBS still comes first wherever stubbed behavior is wanted.
SAFE_BIN="$TESTS_TMP/safebin"
mkdir -p "$SAFE_BIN" || exit 1
for _safe_dir in /usr/bin /bin; do
  [ -d "$_safe_dir" ] || continue
  for _safe_file in "$_safe_dir"/*; do
    _safe_base="${_safe_file##*/}"
    case $_safe_base in
      kubectl|helm) continue ;;
    esac
    [ -e "$SAFE_BIN/$_safe_base" ] || ln -s "$_safe_file" "$SAFE_BIN/$_safe_base" 2>/dev/null
  done
done
BASE_PATH="$SAFE_BIN"

chk() { # chk RC MSG — RC 0 counts as pass
  if [ "$1" = "0" ]; then
    T_PASS=$((T_PASS + 1))
    printf 'PASS: %s\n' "$2"
  else
    T_FAIL=$((T_FAIL + 1))
    printf 'FAIL: %s\n' "$2"
  fi
}
pass() { T_PASS=$((T_PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { T_FAIL=$((T_FAIL + 1)); printf 'FAIL: %s\n' "$1"; }
skip_note() { T_SKIP=$((T_SKIP + 1)); printf 'SKIP: %s\n' "$1"; }
section() { printf '\n== %s ==\n' "$1"; }

chk_grep() { # chk_grep FILE FIXED-STRING MSG
  grep -qF -- "$2" "$1"
  chk $? "$3"
}
chk_nogrep() { # chk_nogrep FILE FIXED-STRING MSG
  ! grep -qF -- "$2" "$1"
  chk $? "$3"
}
chk_regex() { # chk_regex FILE REGEX MSG
  grep -qE -- "$2" "$1"
  chk $? "$3"
}

expect_fail() { # expect_fail MSG CMD [ARGS...] — asserts exit 1; stderr in
  #              $TESTS_TMP/expect-fail.out for follow-up greps.
  local _msg="$1"
  shift
  "$@" >"$TESTS_TMP/expect-fail.out" 2>&1
  local _rc=$?
  [ "$_rc" = "1" ]
  chk $? "$_msg (exit 1, got $_rc)"
}

fresh_repo() { # fresh_repo DST — throwaway copy of scripts/, charts/ and the
  #             example env files; scripts that write repo-root artifacts run
  #             against this copy, never the real tree.
  local _dst="$1"
  rm -rf "$_dst"
  mkdir -p "$_dst"
  cp -a "$REPO_ROOT/scripts" "$_dst/scripts"
  cp -a "$REPO_ROOT/charts" "$_dst/charts"
  cp -a "$REPO_ROOT/.env.example" "$REPO_ROOT/secrets.env.example" "$_dst/"
}

# librun SNIPPET — run SNIPPET in a fresh bash with scripts/lib/common.sh
# sourced; die() inside only kills the subshell, so the harness survives.
# env-prefix the call (VAR=x librun '...') to pass knobs/variables in.
# The snippet shell gets REPO_ROOT and a default HC_STUB_LOG (so committed
# stubs never die on an unbound log file) exported.
librun() {
  HC_STUB_LOG="${HC_STUB_LOG:-$TESTS_TMP/librun-stub.log}" \
    REPO_ROOT="$REPO_ROOT" \
    bash -c '. "$REPO_ROOT/scripts/lib/common.sh"; eval "$1"' librun "$1"
}
# librun_stub SNIPPET — same, with the committed mocks first on PATH.
librun_stub() {
  PATH="$STUBS:$BASE_PATH" librun "$1"
}

finish() {
  printf '\nSummary: %d pass, %d fail, %d skip\n' "$T_PASS" "$T_FAIL" "$T_SKIP"
  [ "$T_FAIL" = "0" ]
}
