#!/usr/bin/env bash
# Builds both Release apps unsigned and runs scripts/check-privacy-release-config.py
# on each: permission strings and their translations, app/extension versions, and
# both host privacy manifests. CI's Privacy workflow runs exactly this, so a CI
# failure reproduces locally with `scripts/check-privacy.sh`.
set -euo pipefail

cd "$(dirname "$0")/.."

# Kept apart from the test build so Release products never mix with Debug ones.
DERIVED_DATA="${WN_PRIVACY_DERIVED_DATA:-build/DerivedData-privacy}"

xcodebuild_args=(
  -project whitenoise-ios.xcodeproj
  -destination 'generic/platform=iOS'
  -derivedDataPath "$DERIVED_DATA"
  -quiet
)
# Opt-in package cache; CI restores it between runs.
if [ -n "${WN_PRIVACY_SOURCE_PACKAGES:-}" ]; then
  xcodebuild_args+=(-clonedSourcePackagesDirPath "$WN_PRIVACY_SOURCE_PACKAGES")
fi

for pair in "Whitenoise (Production):Release-Production" "Whitenoise (Staging):Release-Staging"; do
  scheme="${pair%%:*}"
  configuration="${pair##*:}"
  echo "==> Building $scheme ($configuration)"
  xcodebuild build "${xcodebuild_args[@]}" -scheme "$scheme" -configuration "$configuration" \
    CODE_SIGNING_ALLOWED=NO
done

apps=("$DERIVED_DATA"/Build/Products/Release-*-iphoneos/*.app)
if [ "${#apps[@]}" -ne 2 ] || [ ! -d "${apps[0]}" ]; then
  echo "Expected 2 Release apps under $DERIVED_DATA, found: ${apps[*]}" >&2
  exit 1
fi
for app in "${apps[@]}"; do
  echo "==> Checking $app"
  python3 scripts/check-privacy-release-config.py "$app"
done
