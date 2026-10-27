#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

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

phase() {
  local label="$1"
  shift
  local start=$SECONDS
  local status=0
  "$@" || status=$?
  echo "==> ${label}: $((SECONDS - start))s"
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

phase "test-without-building" run test-without-building \
  "${xcodebuild_args[@]}" \
  -resultBundlePath "$RESULT_BUNDLE"
