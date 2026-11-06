#!/usr/bin/env bash
# =============================================================================
# tests/run-tests.sh — single entry point for the suite.
#
# Usage: tests/run-tests.sh [names...]     (e.g. `common`, `bootstrap install`)
#        names: common install update bootstrap install-prereqs chart
#
# Cluster safety: the suite never touches a cluster. install/update tests use
# their built-in --dry-run; cluster calls run against committed mock binaries
# first on PATH inside `env -i` environments; this runner additionally fails
# when any test leaks artifacts (.env, secrets.env, backups) into the real
# repo tree. See tests/README.md for the full guarantees.
# =============================================================================
set -u

REPO_ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)" || exit 1
cd "$REPO_ROOT" || exit 1

RUNTMP="$(mktemp -d "${TMPDIR:-/tmp}/ha-runtests.XXXXXX")" || exit 1
trap 'rm -rf "$RUNTMP"' EXIT

FAILURES=0

# --- static gate: bash -n over every shell file ---------------------------------
printf '\n== bash -n ==\n'
for f in scripts/*.sh scripts/lib/*.sh tests/*.sh tests/stubs/*; do
  [ -f "$f" ] || continue
  if bash -n "$f" 2>"$RUNTMP/syntax.out"; then
    printf 'syntax-ok: %s\n' "$f"
  else
    printf 'SYNTAX-FAIL: %s\n' "$f"
    cat "$RUNTMP/syntax.out"
    FAILURES=$((FAILURES + 1))
  fi
done

# --- shellcheck (optional tool) ----------------------------------------------------
printf '\n== shellcheck ==\n'
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -x scripts/*.sh scripts/lib/*.sh tests/*.sh tests/stubs/* \
     2>"$RUNTMP/shellcheck.out"; then
    printf 'shellcheck: ok\n'
  else
    printf 'SHELLCHECK-FAIL:\n'
    cat "$RUNTMP/shellcheck.out"
    FAILURES=$((FAILURES + 1))
  fi
else
  printf 'SKIP: shellcheck not installed (optional)\n'
fi

# --- coverage: every script has a committed test file -------------------------------
printf '\n== coverage ==\n'
for pair in install:test-install update:test-update bootstrap-cluster:test-bootstrap \
            install-prereqs:test-install-prereqs uninstall:test-uninstall; do
  _s="${pair%%:*}"
  _t="${pair#*:}"
  if [ -f "tests/$_t.sh" ]; then
    printf 'covered: scripts/%s.sh -> tests/%s.sh\n' "$_s" "$_t"
  else
    printf 'COVERAGE-FAIL: scripts/%s.sh has no tests/%s.sh\n' "$_s" "$_t"
    FAILURES=$((FAILURES + 1))
  fi
done

# --- select test files ----------------------------------------------------------------
SELECTED=""
if [ "$#" -gt 0 ]; then
  for name in "$@"; do
    f="tests/test-$name.sh"
    if [ ! -f "$f" ]; then
      printf 'error: no test file matches "%s" (expected tests/test-%s.sh)\n' "$name" "$name" >&2
      exit 1
    fi
    SELECTED="$SELECTED $f"
  done
else
  for f in tests/test-*.sh; do
    [ -f "$f" ] || continue
    SELECTED="$SELECTED $f"
  done
fi

# --- run the tests -----------------------------------------------------------------------
snapshot() { # snapshot FILE — record repo-root artifacts (.env*, secrets.env*)
  : > "$1"
  for p in .env .env.* secrets.env secrets.env.*; do
    [ -e "$p" ] && printf '%s\n' "$p" >> "$1"
  done
  return 0
}

printf '\n== tests ==\n'
snapshot "$RUNTMP/before"
# shellcheck disable=SC2086  # SELECTED is a plain space-separated file list
for f in $SELECTED; do
  printf '\n----- %s -----\n' "$f"
  if bash "$f"; then
    :
  else
    printf '>>> %s FAILED\n' "$f"
    FAILURES=$((FAILURES + 1))
  fi
done

# --- leak check: no new artifacts in the real repo tree ------------------------------------
printf '\n== repo leak check ==\n'
snapshot "$RUNTMP/after"
new="$(comm -13 <(sort "$RUNTMP/before") <(sort "$RUNTMP/after"))"
if [ -n "$new" ]; then
  printf 'LEAK-FAIL: new repo-root artifacts appeared:\n%s\n' "$new"
  FAILURES=$((FAILURES + 1))
else
  printf 'ok: no new artifacts in the repo tree\n'
fi

# --- summary ----------------------------------------------------------------------------------
printf '\n==========================================\n'
if [ "$FAILURES" -eq 0 ]; then
  printf 'ALL CHECKS PASSED\n'
  exit 0
fi
printf 'FAILURES: %d\n' "$FAILURES"
exit 1
