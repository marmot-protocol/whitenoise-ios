#!/usr/bin/env bash
# Write a Markdown phase breakdown and the 20 slowest suites for one test run.
#
# Usage:
#   scripts/audit/report-run.sh [XCRESULT] [--log RAW_LOG]
#
# XCRESULT defaults to build/TestResults.xcresult. The raw log is, in order,
# --log, $WN_AUDIT_LOG (scripts/test.sh exports it to $GITHUB_ENV on CI), the
# path in $WN_AUDIT_DIR/latest-log, else the newest $WN_AUDIT_DIR/xcodebuild-*.log.
# WN_AUDIT_DIR defaults to build/audit. Without a raw log only the xcresult's
# per-suite summed case durations are reported and no phases.csv row is written,
# so an ordinary (xcbeautify) CI run leaves nothing under build/audit to upload.
# The report goes to $GITHUB_STEP_SUMMARY when set, else stdout. Missing or
# unreadable inputs print a note and exit 0 so an `if: always()` step never
# fails the job on its own.
set -euo pipefail

cd "$(dirname "$0")/../.."

audit_dir="${WN_AUDIT_DIR:-build/audit}"
xcresult="build/TestResults.xcresult"
log="${WN_AUDIT_LOG:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --log) log="${2:-}"; shift 2 ;;
    *) xcresult="$1"; shift ;;
  esac
done

if [ -z "$log" ] && [ -s "$audit_dir/latest-log" ]; then
  log="$(head -n 1 "$audit_dir/latest-log")"
fi
if [ -z "$log" ]; then
  # The simulator capture lives beside the xcodebuild log as simulator-*.log;
  # keep any older *-simulator.log naming out of the candidates too.
  log="$(ls -t "$audit_dir"/xcodebuild-*.log 2>/dev/null | grep -v -- '-simulator\.log$' | head -n 1 || true)"
fi
[ -n "$log" ] && [ -e "$log" ] || log=""

args=(--markdown --top 20 --csv "$audit_dir/phases.csv")
[ -e "$xcresult" ] && args+=(--xcresult "$xcresult")
if [ -n "$log" ]; then
  args+=(--log "$log")
else
  args+=(--no-csv)
fi
if [ -n "${GITHUB_RUN_ID:-}" ]; then
  args+=(--run-id "${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT:-1}")
fi

out="${GITHUB_STEP_SUMMARY:-/dev/stdout}"

# Tier written by scripts/test.sh --tier; the PR plan's skippedTests names
# whole suites, or Suite/test() for individually tagged tests.
tier="$(head -n 1 build/test-tier 2>/dev/null || echo unknown)"
case "$tier" in
  pr)
    python3 - TestPlans/PR.xctestplan >> "$out" <<'PY' || echo "**Tier:** pr" >> "$out"
import json, sys
plan = json.load(open(sys.argv[1]))
entries = [e for t in plan["testTargets"] for e in t.get("skippedTests", [])]
suites = sorted({e for e in entries if "/" not in e})
tests = [e for e in entries if "/" in e]
print("**Tier:** pr (`TestPlans/PR.xctestplan`): %d suites skipped, plus %d tests in otherwise running suites\n"
      % (len(suites), len(tests)))
PY
    ;;
  full) printf '**Tier:** full (`TestPlans/Full.xctestplan`): 0 suites skipped\n\n' >> "$out" ;;
  *) printf '**Tier:** %s (scheme default plan)\n\n' "$tier" >> "$out" ;;
esac

if [ ! -e "$xcresult" ] && [ -z "$log" ]; then
  note="report-run: no $xcresult and no raw log; nothing to report"
  echo "$note" >&2
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && echo "$note" >> "$out"
  exit 0
fi

if ! python3 scripts/audit/phases.py "${args[@]}" >> "$out"; then
  echo "report-run: phases.py failed; see the log above" >&2
fi
exit 0
