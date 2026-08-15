#!/usr/bin/env bash
# Launches the app with the automation server and runs every tests/rpc/test_*.py
# against it (fresh app instance per test). Windowed when a display exists,
# else headless. Exits non-zero on any failure.
#
# Usage: tools/run_rpc_tests.sh [name-filter]
#   GODOT=/path/to/godot HEADLESS=1 PORT=4777 tools/run_rpc_tests.sh

set -u
cd "$(dirname "$0")/.."

GODOT="${GODOT:-/nix/store/9zi5r792h6gab0zw3z4xcmydgzjzdird-godot-4.7.1/bin/godot4.7.1}"
PORT="${PORT:-4777}"
FILTER="${1:-}"

if [ ! -x "$GODOT" ]; then
    echo "error: godot binary not found at $GODOT (set GODOT=...)" >&2
    exit 2
fi

HEADLESS_FLAG=""
if [ "${HEADLESS:-}" = "1" ] || { [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; }; then
    HEADLESS_FLAG="--headless"
fi

pass=0
fail=0
for t in tests/rpc/test_*.py; do
    name="$(basename "$t" .py)"
    [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]] && continue
    "$GODOT" --path . $HEADLESS_FLAG -- "--automation-port=$PORT" \
        > /dev/null 2>&1 &
    APP_PID=$!
    if ECHOCAD_PORT="$PORT" python3 "$t"; then
        pass=$((pass + 1))
    else
        echo "FAIL $name"
        fail=$((fail + 1))
    fi
    # test_shell quits the app itself via app.quit; reap or kill leftovers.
    kill "$APP_PID" 2>/dev/null
    wait "$APP_PID" 2>/dev/null
done

echo "rpc passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
