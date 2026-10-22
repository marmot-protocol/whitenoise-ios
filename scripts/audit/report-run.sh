#!/usr/bin/env bash
# Write a Markdown phase breakdown and the 20 slowest suites for one test run.
#
# Usage:
#   scripts/audit/report-run.sh [XCRESULT] [--log RAW_LOG]
#
# XCRESULT defaults to build/TestResults.xcresult. The raw log defaults to
# WN_AUDIT_LOG, else the newest build/audit/xcodebuild-*.log (written when
# scripts/test.sh ran with WN_TEST_RAW_LOG=1); without one, only the xcresult's
# start/finish times and per-suite summed case durations are available. The
# report goes to $GITHUB_STEP_SUMMARY when set, else stdout, and a row is
# appended to build/audit/phases.csv. Missing inputs print a note and exit 0 so
# an `if: always()` CI step never fails the job on its own.
set -euo pipefail

cd "$(dirname "$0")/../.."

xcresult="build/TestResults.xcresult"
log="${WN_AUDIT_LOG:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --log) log="${2:-}"; shift 2 ;;
    *) xcresult="$1"; shift ;;
  esac
done

if [ -z "$log" ]; then
  log="$(ls -t build/audit/xcodebuild-*.log 2>/dev/null | head -n 1 || true)"
fi

args=(--markdown --top 20)
[ -e "$xcresult" ] && args+=(--xcresult "$xcresult")
[ -n "$log" ] && [ -e "$log" ] && args+=(--log "$log")
if [ -n "${GITHUB_RUN_ID:-}" ]; then
  args+=(--run-id "${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT:-1}")
fi

out="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
if [ ! -e "$xcresult" ] && { [ -z "$log" ] || [ ! -e "$log" ]; }; then
  note="report-run: no $xcresult and no raw log; nothing to report"
  echo "$note" >&2
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && echo "$note" >> "$out"
  exit 0
fi

python3 scripts/audit/phases.py "${args[@]}" >> "$out"
