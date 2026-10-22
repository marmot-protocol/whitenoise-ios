#!/usr/bin/env bash
# Capture the simulator's unified log around a test run.
#
# Usage:
#   pid=$(scripts/audit/simlog-capture.sh start <udid> <outfile>)
#   ... xcodebuild test-without-building ...
#   scripts/audit/simlog-capture.sh stop "$pid"
#
# `start` spawns `log stream --style compact` inside the simulator, in the
# background, writing to <outfile>, and prints the PID of the `xcrun simctl
# spawn` process on stdout. `stop` sends that PID SIGTERM (simctl forwards it,
# so the in-simulator `log` process ends with it) and waits briefly.
#
# Default predicate (override with WN_SIMLOG_PREDICATE):
#   process == "whitenoise-ios" OR process == "installd"
#     OR subsystem CONTAINS "com.apple.dt.xctest"
#
# Reading the capture. Compact style lines look like
#   2026-10-22 19:28:00.123 I  whitenoise-ios[812:0x1f2] [dev.ipf.whitenoise.ios:cold-bootstrap] runtime_constructed duration_ms=50
# i.e. `<date> <time> <type> <process>[<pid>:<tid>] [<subsystem>:<category>] <message>`.
#
# - Install completion: `installd` lines mentioning the host bundle id
#   (`dev.ipf.whitenoise.ios`, staging included). The last installd line before
#   the first `whitenoise-ios[` line is when the test host finished installing.
#   Compare its time with the `==> build-for-testing` marker in the raw
#   xcodebuild log to see how long simulator attach plus install took.
# - Host launches: each launch of the host app is a new pid in
#   `whitenoise-ios[<pid>:`. xcodebuild launches the host once to enumerate
#   the test bundle (discovery pass) and again to run it (run pass), so expect
#   two distinct pids; the time between the first line of each pid and the
#   previous pid's last line is launch overhead outside any test.
# - Runtime boot in the host: the app's own `[<bundle id>:cold-bootstrap]`
#   lines. `runtime_constructed duration_ms=` is how long constructing the
#   Marmot runtime took, and `local_ready phase=... total_ms=` is the full
#   bootstrap. One per host launch means the production bootstrap ran in the
#   test host; after the test-host guard lands, both should disappear.
# - Relay connection attempts: `whitenoise-ios` lines containing `wss://`,
#   `relay`, or the Network framework category `[com.apple.network:connection]`
#   (nw_connection start/ready/failed). Any of these during a unit-test run
#   means the host runtime reached for the network.
# - Swift Testing / XCTest harness lines carry the `com.apple.dt.xctest`
#   subsystem; their first line per host pid marks when the bundle was loaded.
set -euo pipefail

predicate="${WN_SIMLOG_PREDICATE:-process == \"whitenoise-ios\" OR process == \"installd\" OR subsystem CONTAINS \"com.apple.dt.xctest\"}"

usage() {
  echo "usage: $0 start <udid> <outfile> | stop <pid>" >&2
  exit 2
}

case "${1:-}" in
  start)
    udid="${2:-}"
    out="${3:-}"
    [ -n "$udid" ] && [ -n "$out" ] || usage
    mkdir -p "$(dirname "$out")"
    # Detach every stdio handle: the caller reads this script's stdout through
    # command substitution, which would otherwise wait for the stream to end.
    xcrun simctl spawn "$udid" log stream --style compact --predicate "$predicate" \
      >"$out" 2>&1 </dev/null &
    echo "$!"
    ;;
  stop)
    pid="${2:-}"
    [ -n "$pid" ] || usage
    if kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$pid" 2>/dev/null || exit 0
        sleep 0.5
      done
      kill -KILL "$pid" 2>/dev/null || true
    fi
    ;;
  *)
    usage
    ;;
esac
