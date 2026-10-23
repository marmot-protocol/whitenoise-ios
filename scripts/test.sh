#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# --tier pr|full selects TestPlans/PR.xctestplan (skips tests tagged runtime or
# uiHosting and the runtime/hosting XCTest classes) or TestPlans/Full.xctestplan.
# WN_TEST_TIER=pr|full sets the same default; --tier overrides it. With neither,
# the Staging scheme's default plan (Full) runs, as before.
usage() {
  echo "usage: scripts/test.sh [--tier pr|full]   (or WN_TEST_TIER=pr|full)" >&2
  exit 2
}
TIER="${WN_TEST_TIER:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --tier)
      [ $# -ge 2 ] && [ -n "$2" ] || usage
      TIER="$2"; shift 2 ;;
    --tier=*) TIER="${1#--tier=}"; [ -n "$TIER" ] || usage; shift ;;
    *) usage ;;
  esac
done
case "$TIER" in
  "") TEST_PLAN="" ;;
  pr) TEST_PLAN="PR" ;;
  full) TEST_PLAN="Full" ;;
  *) echo "scripts/test.sh: unknown tier '$TIER' (pr or full)" >&2; exit 2 ;;
esac
# scripts/audit/report-run.sh prints the tier in the step summary.
mkdir -p build
echo "${TIER:-default}" > build/test-tier

DESTINATION="${WN_TEST_DESTINATION:-$(scripts/pick-simulator.sh)}"
RESULT_BUNDLE="${WN_TEST_RESULT_BUNDLE:-build/TestResults.xcresult}"

rm -rf "$RESULT_BUNDLE"

xcodebuild_args=(
  -project whitenoise-ios.xcodeproj
  -scheme "Whitenoise (Staging)"
  -destination "$DESTINATION"
  -skipPackagePluginValidation
  -skipMacroValidation
)

# Opt-in cache locations. Unset locally so developers keep sharing Xcode's
# DerivedData with the IDE; CI points them at gitignored build/ subdirectories
# it can restore between runs.
if [ -n "${WN_TEST_DERIVED_DATA:-}" ]; then
  xcodebuild_args+=(-derivedDataPath "$WN_TEST_DERIVED_DATA")
fi
if [ -n "${WN_TEST_SOURCE_PACKAGES:-}" ]; then
  xcodebuild_args+=(-clonedSourcePackagesDirPath "$WN_TEST_SOURCE_PACKAGES")
fi

build_settings=(
  ONLY_ACTIVE_ARCH=YES
  CODE_SIGN_STYLE=Manual
  DEVELOPMENT_TEAM=""
  PROVISIONING_PROFILE_SPECIFIER=""
  CODE_SIGN_IDENTITY="-"
  CODE_SIGNING_ALLOWED=YES
)
# Sign ad-hoc with no team rather than skipping signing. The App Group
# entitlement is embedded only when signing runs; without it,
# containerURL(forSecurityApplicationGroupIdentifier:) returns nil and the test
# host fatal-errors initializing Marmot storage at launch. The simulator reads
# the app group from the simulated entitlements, which carry no team prefix, so
# manual ad-hoc signing works on a CI runner with no signing identity.

# Nothing indexes a CI checkout, so skip index-while-building there. Local runs
# keep writing the index store the IDE reads.
if [ -n "${CI:-}" ]; then
  build_settings+=(COMPILER_INDEX_STORE_ENABLE=NO)
fi

# Content-addressed compiler caching. Cache keys hash compiler inputs, not file
# mtimes, so a fresh clone still replays cached objects; prefix mapping keeps
# keys independent of the checkout path.
if [ -n "${WN_TEST_COMPILATION_CACHE:-}" ]; then
  build_settings+=(
    COMPILATION_CACHE_ENABLE_CACHING=YES
    COMPILATION_CACHE_CAS_PATH="$WN_TEST_COMPILATION_CACHE"
    COMPILATION_CACHE_KEEP_CAS_DIRECTORY=YES
    COMPILATION_CACHE_LIMIT_SIZE="${WN_TEST_COMPILATION_CACHE_LIMIT:-2000000000}"
    SWIFT_ENABLE_COMPILE_CACHE=YES
    CLANG_ENABLE_COMPILE_CACHE=YES
    SWIFT_ENABLE_EXPLICIT_MODULES=YES
    CLANG_ENABLE_EXPLICIT_MODULES=YES
    SWIFT_ENABLE_PREFIX_MAPPING=YES
  )
fi

run() {
  if command -v xcbeautify >/dev/null 2>&1; then
    xcodebuild "$@" | xcbeautify
  else
    xcodebuild "$@"
  fi
}

# Measurement runs (WN_TEST_RAW_LOG=1) keep xcodebuild's raw test output with a
# wall-clock prefix per line, plus the simulator log around it, under
# build/audit/. scripts/audit/phases.py and report-run.sh read them. xcbeautify
# buffers, so its output cannot place the test phase's markers in time.
RAW_LOG=""
if [ "${WN_TEST_RAW_LOG:-}" = "1" ]; then
  RAW_LOG=1
  audit_stamp="$(date +%Y%m%dT%H%M%S)"
  export WN_AUDIT_LOG="${WN_AUDIT_LOG:-build/audit/xcodebuild-${audit_stamp}.log}"
  mkdir -p "$(dirname "$WN_AUDIT_LOG")" build/audit
  # Tell scripts/audit/report-run.sh which log this run wrote instead of
  # letting it guess from file ages.
  echo "$WN_AUDIT_LOG" > build/audit/latest-log
  if [ -n "${GITHUB_ENV:-}" ]; then
    echo "WN_AUDIT_LOG=$WN_AUDIT_LOG" >> "$GITHUB_ENV"
  fi
fi

run_timed() {
  scripts/audit/timed-xcodebuild.sh "$@"
}

phase() {
  local label="$1"
  shift
  local start=$SECONDS
  local status=0
  "$@" || status=$?
  local marker="==> ${label}: $((SECONDS - start))s"
  echo "$marker"
  if [ -n "$RAW_LOG" ]; then
    echo "$(date +%Y-%m-%dT%H:%M:%S) $marker" >> "$WN_AUDIT_LOG"
  fi
  return "$status"
}

# Booting the simulator is dead time on the critical path, so overlap it with
# the build instead of letting `xcodebuild test` serialize the two.
boot_pid=""
case "$DESTINATION" in
  *id=*)
    udid="${DESTINATION##*id=}"
    udid="${udid%%,*}"
    ;;
  *) udid="" ;;
esac
if [ -n "$udid" ]; then
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 &
  boot_pid=$!
fi

phase "build-for-testing" run build-for-testing "${xcodebuild_args[@]}" "${build_settings[@]}"

if [ -n "$boot_pid" ]; then
  wait "$boot_pid" || true
fi

test_runner=run
simlog_pid=""
stop_simlog() {
  if [ -n "$simlog_pid" ]; then
    scripts/audit/simlog-capture.sh stop "$simlog_pid" || true
    simlog_pid=""
  fi
}
if [ -n "$RAW_LOG" ]; then
  test_runner=run_timed
  if [ -n "$udid" ]; then
    simlog_pid="$(scripts/audit/simlog-capture.sh start "$udid" "$(dirname "$WN_AUDIT_LOG")/simulator-${audit_stamp}.log")" || simlog_pid=""
    trap stop_simlog EXIT INT TERM
  fi
fi

test_plan_args=()
if [ -n "$TEST_PLAN" ]; then
  test_plan_args=(-testPlan "$TEST_PLAN")
fi
# xcodebuild (Xcode 27.1) applies a plan's skippedTests and skippedTags only to
# XCTest; Swift Testing honours -skip-testing, so repeat the plan's list there.
if [ "$TEST_PLAN" = "PR" ]; then
  # Capture first so a failed read stops the run instead of silently
  # running the PR tier with no Swift Testing skips.
  if ! skip_list="$(python3 -c 'import json, sys
entries = [e for t in json.load(open(sys.argv[1]))["testTargets"] for e in t.get("skippedTests", [])]
if not entries:
    sys.exit("PR plan has no skippedTests")
print("\n".join(entries))' TestPlans/PR.xctestplan)"; then
    echo "scripts/test.sh: could not read the skip list from TestPlans/PR.xctestplan" >&2
    exit 1
  fi
  while IFS= read -r skipped; do
    [ -n "$skipped" ] && test_plan_args+=("-skip-testing:whitenoise-iosTests/$skipped")
  done <<< "$skip_list"
fi

test_status=0
phase "test-without-building" "$test_runner" test-without-building \
  "${xcodebuild_args[@]}" \
  ${test_plan_args[@]+"${test_plan_args[@]}"} \
  -resultBundlePath "$RESULT_BUNDLE" || test_status=$?
stop_simlog
exit "$test_status"
