#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

DESTINATION="${WN_TEST_DESTINATION:-$(scripts/pick-simulator.sh)}"
RESULT_BUNDLE="${WN_TEST_RESULT_BUNDLE:-build/TestResults.xcresult}"

rm -rf "$RESULT_BUNDLE"

run() {
  xcodebuild test \
    -project whitenoise-ios.xcodeproj \
    -scheme "Whitenoise (Staging)" \
    -destination "$DESTINATION" \
    -resultBundlePath "$RESULT_BUNDLE" \
    -enableCodeCoverage YES \
    ONLY_ACTIVE_ARCH=YES \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_ALLOWED=YES
}
# Sign ad-hoc with no team rather than skipping signing. The App Group
# entitlement is embedded only when signing runs; without it,
# containerURL(forSecurityApplicationGroupIdentifier:) returns nil and the test
# host fatal-errors initializing Marmot storage at launch. The simulator reads
# the app group from the simulated entitlements, which carry no team prefix, so
# manual ad-hoc signing works on a CI runner with no signing identity.

if command -v xcbeautify >/dev/null 2>&1; then
  set -o pipefail
  run | xcbeautify
else
  run
fi
