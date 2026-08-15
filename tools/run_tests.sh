#!/usr/bin/env bash
# Runs every headless test in tests/*.gd. Prints FAIL <name> per failure;
# exits non-zero if any test fails.
#
# Usage: tools/run_tests.sh [name-filter]
#   GODOT=/path/to/godot tools/run_tests.sh      # override binary
#   tools/run_tests.sh m00                       # only tests matching "m00"

set -u
cd "$(dirname "$0")/.."

GODOT="${GODOT:-/nix/store/9zi5r792h6gab0zw3z4xcmydgzjzdird-godot-4.7.1/bin/godot4.7.1}"
FILTER="${1:-}"

if [ ! -x "$GODOT" ]; then
    echo "error: godot binary not found at $GODOT (set GODOT=...)" >&2
    exit 2
fi

pass=0
fail=0
for f in tests/*.gd; do
    t="$(basename "$f" .gd)"
    [ -n "$FILTER" ] && [[ "$t" != *"$FILTER"* ]] && continue
    if "$GODOT" --headless --path . --script "res://tests/$t.gd" > /dev/null 2>&1; then
        pass=$((pass + 1))
    else
        echo "FAIL $t"
        fail=$((fail + 1))
    fi
done

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
