#!/usr/bin/env bash
# Runs the test suite against fake machines. Nothing on the real system changes.
#
#   tests/run.sh                    everything
#   tests/run.sh safety install     only these files (components, safety, install)
set -uo pipefail
TESTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
names=("$@")
((${#names[@]})) || names=(components safety install)
for t in "${names[@]}"; do
    [[ -f $TESTS/$t.sh ]] || { echo "unknown test file: $t (have: components, safety, install)" >&2; exit 2; }
done

source "$TESTS/lib.sh"   # creates the workspace: only once the names are valid

section "Syntax"
check "bash -n" bash -n "$SCRIPT"
for t in "${names[@]}"; do source "$TESTS/$t.sh"; done

section "Whole run"
check "no real system path touched anywhere" [ "$(cat "$BASE"/*/log 2>/dev/null | grep -c '^LEAK')" == 0 ]

if ((FAIL == 0)); then
    rm -rf "$BASE"
    printf '\n\033[1m%d passed, 0 failed\033[0m\n' "$PASS"
else
    printf '\n\033[1m%d passed, %d failed\033[0m  (fake machines kept in %s)\n' "$PASS" "$FAIL" "$BASE"
fi
((FAIL == 0))
