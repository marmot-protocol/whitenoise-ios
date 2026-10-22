#!/usr/bin/env bash
# Run `xcodebuild "$@"` for a measurement run: no xcbeautify, stdout and stderr
# merged, every raw line prefixed with a wall-clock timestamp, and the stream
# teed to WN_AUDIT_LOG (default build/audit/xcodebuild-<timestamp>.log).
#
# xcbeautify buffers and rewrites xcodebuild's output, so the per-line
# timestamps CI attaches to the pretty log say nothing about when `Testing
# started`, XCTest's suite clocks, Swift Testing's `Test run started.` or the
# `IDETestOperationsObserverDebug` summary actually happened. This wrapper keeps
# the raw lines so scripts/audit/phases.py can put them on one timeline.
#
# Usage:
#   scripts/audit/timed-xcodebuild.sh test-without-building -project ... -scheme ...
#   WN_AUDIT_LOG=build/audit/run.log scripts/audit/timed-xcodebuild.sh ...
#
# The exit status is xcodebuild's own (pipefail). Timestamps are local time at
# second resolution, which matches the local-time clocks XCTest and xcodebuild
# print themselves. The log is appended to, so a caller may write its own
# marker lines (scripts/test.sh adds `==> <phase>: Ns`) before and after.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
log="${WN_AUDIT_LOG:-$root/build/audit/xcodebuild-$(date +%Y%m%dT%H%M%S).log}"
mkdir -p "$(dirname "$log")"

stamp() {
  # macOS ships BWK awk, which has no strftime, so stamp with perl (present on
  # every macOS and GitHub runner image) with autoflush on.
  perl -MPOSIX -ne 'BEGIN { $| = 1 } print strftime("%Y-%m-%dT%H:%M:%S", localtime), " ", $_'
}

echo "timed-xcodebuild: raw log at $log" >&2
xcodebuild "$@" 2>&1 | stamp | tee -a "$log"
