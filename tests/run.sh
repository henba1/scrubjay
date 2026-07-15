#!/usr/bin/env bash
# scrubjay's test runner. No frameworks, no dependencies beyond bash + jq + coreutils.
#
#   tests/run.sh                 run everything
#   tests/run.sh adapters ship   run only tests/test_adapters.sh and tests/test_ship.sh
#
# Each tests/test_*.sh runs in its own process with its own sandbox ($HOME moved into a temp dir —
# see tests/lib.sh), so tests cannot see each other's state, your ~/.claude, or your NAS. Exit code
# is non-zero if any check failed, which is what CI keys off.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
TESTS_DIR="tests"

command -v jq >/dev/null 2>&1 || { echo "tests: jq is required"; exit 1; }

# Which files to run: everything, or just the names given.
files=()
if [ $# -eq 0 ]; then
  for f in "$TESTS_DIR"/test_*.sh; do [ -f "$f" ] && files+=("$f"); done
else
  for name in "$@"; do
    f="$TESTS_DIR/test_${name#test_}.sh"; f="${f%.sh}.sh"
    [ -f "$f" ] || { echo "tests: no such test '$name' ($f)"; exit 1; }
    files+=("$f")
  done
fi
[ "${#files[@]}" -gt 0 ] || { echo "tests: nothing to run"; exit 1; }

pass=0; fail=0; skip=0; failed_files=()

for f in "${files[@]}"; do
  printf '\n\033[1;36m── %s\033[0m\n' "$(basename "$f")"
  out="$(bash "$f" 2>&1)"; rc=$?
  # Strip the machine-readable summary line before showing the human output.
  printf '%s\n' "$out" | grep -v '^__RESULT__' || true

  line="$(printf '%s\n' "$out" | grep '^__RESULT__' | tail -1)"
  if [ -n "$line" ]; then
    # shellcheck disable=SC2086  # three integers, deliberately word-split
    set -- $line
    pass=$((pass + $2)); fail=$((fail + $3)); skip=$((skip + $4))
  fi
  if [ "$rc" -ne 0 ]; then
    failed_files+=("$(basename "$f")")
    [ -n "$line" ] || fail=$((fail + 1))   # the file died before it could report
  fi
done

echo
printf '\033[1m─────────────────────────────────────────\033[0m\n'
printf '  \033[32m%d passed\033[0m' "$pass"
[ "$skip" -gt 0 ] && printf '   \033[33m%d skipped\033[0m' "$skip"
[ "$fail" -gt 0 ] && printf '   \033[31m%d FAILED\033[0m' "$fail"
echo
if [ "${#failed_files[@]}" -gt 0 ]; then
  printf '  failing files: %s\n' "${failed_files[*]}"
  exit 1
fi
exit 0
