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
    ONLY_ACTIVE_ARCH=YES \
    CODE_SIGNING_ALLOWED=NO
}

if command -v xcbeautify >/dev/null 2>&1; then
  set -o pipefail
  run | xcbeautify
else
  run
fi
