#!/usr/bin/env bash
# Install a published immutable MarmotKit release into the local Swift package.
#
# Usage:
#   ./scripts/sync-bindings.sh <full-master-sha>
#   ./scripts/sync-bindings.sh <version>
#
# Examples:
#   ./scripts/sync-bindings.sh 4e056e708afeb86fb4e62049b73c8ad4155ddf1a
#   ./scripts/sync-bindings.sh 0.9.11

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <version-or-full-master-sha>" >&2
    exit 2
fi

RELEASE="$1"
if [[ "$RELEASE" =~ ^[0-9a-f]{40}$ ]]; then
    RELEASE_ID="snapshot-$RELEASE"
    RELEASE_TAG="marmotkit-snapshot-$RELEASE"
    REQUESTED_SHA="$RELEASE"
elif [[ "$RELEASE" =~ ^v?([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?)$ ]]; then
    RELEASE_ID="${BASH_REMATCH[1]}"
    RELEASE_TAG="marmotkit-v$RELEASE_ID"
    REQUESTED_SHA=""
else
    echo "error: release must be a semantic version or a full lowercase 40-character SHA" >&2
    exit 2
fi

IOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_DIR="$IOS_DIR/Packages/MarmotKit"
BASE_URL="https://github.com/marmot-protocol/mdk/releases/download/$RELEASE_TAG"
BINARY_ASSET="MarmotKitFFI-$RELEASE_ID.xcframework.zip"
SWIFT_ASSET="MarmotKit-$RELEASE_ID.swift"
MANIFEST_ASSET="marmotkit-ios-$RELEASE_ID.manifest.json"
CHECKSUMS_ASSET="marmotkit-ios-$RELEASE_ID.checksums.txt"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

download() {
    local asset="$1"
    curl --fail --location --retry 3 --silent --show-error \
        "$BASE_URL/$asset" \
        --output "$TEMP_DIR/$asset"
}

echo "==> Downloading immutable MarmotKit release $RELEASE_TAG"
download "$BINARY_ASSET"
download "$BINARY_ASSET.swiftpm-checksum"
download "$SWIFT_ASSET"
download "$MANIFEST_ASSET"
download "$CHECKSUMS_ASSET"

SOURCE_SHA="$(plutil -extract source_sha raw -o - "$TEMP_DIR/$MANIFEST_ASSET")"
if [[ ! "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]]; then
    echo "error: manifest contains an invalid source SHA: $SOURCE_SHA" >&2
    exit 1
fi
if [[ -n "$REQUESTED_SHA" && "$SOURCE_SHA" != "$REQUESTED_SHA" ]]; then
    echo "error: snapshot source SHA $SOURCE_SHA does not match $REQUESTED_SHA" >&2
    exit 1
fi

EXPECTED_BINARY_CHECKSUM="$(tr -d '[:space:]' < "$TEMP_DIR/$BINARY_ASSET.swiftpm-checksum")"
if [[ ! "$EXPECTED_BINARY_CHECKSUM" =~ ^[0-9a-f]{64}$ ]]; then
    echo "error: release contains an invalid SwiftPM checksum" >&2
    exit 1
fi
COMPUTED_BINARY_CHECKSUM="$(swift package compute-checksum "$TEMP_DIR/$BINARY_ASSET")"
if [[ "$COMPUTED_BINARY_CHECKSUM" != "$EXPECTED_BINARY_CHECKSUM" ]]; then
    echo "error: binary checksum mismatch" >&2
    exit 1
fi

EXPECTED_SWIFT_SHA="$(awk -v file="$SWIFT_ASSET" '$1 == "sha256" && $3 == file { print $2 }' "$TEMP_DIR/$CHECKSUMS_ASSET")"
COMPUTED_SWIFT_SHA="$(shasum -a 256 "$TEMP_DIR/$SWIFT_ASSET" | awk '{ print $1 }')"
if [[ -z "$EXPECTED_SWIFT_SHA" || "$COMPUTED_SWIFT_SHA" != "$EXPECTED_SWIFT_SHA" ]]; then
    echo "error: generated Swift source checksum mismatch" >&2
    exit 1
fi

RELEASE_JSON="$TEMP_DIR/release.json"
curl --fail --location --retry 3 --silent --show-error \
    "https://api.github.com/repos/marmot-protocol/mdk/releases/tags/$RELEASE_TAG" \
    --output "$RELEASE_JSON"
PUBLISHED_AT="$(plutil -extract published_at raw -o - "$RELEASE_JSON")"
RUST_OPT_LEVEL="$(plutil -extract rust_release_profile.opt_level raw -o - "$TEMP_DIR/$MANIFEST_ASSET")"
RUST_CODEGEN_UNITS="$(plutil -extract rust_release_profile.codegen_units raw -o - "$TEMP_DIR/$MANIFEST_ASSET")"
FEATURES_JSON="$(plutil -extract features json -o - "$TEMP_DIR/$MANIFEST_ASSET")"
FEATURES="$(printf '%s' "$FEATURES_JSON" | sed -E 's/^\["//; s/"\]$//; s/","/,/g')"

CARGO_TOML="$TEMP_DIR/marmot-uniffi-Cargo.toml"
curl --fail --location --retry 3 --silent --show-error \
    "https://raw.githubusercontent.com/marmot-protocol/mdk/$SOURCE_SHA/crates/marmot-uniffi/Cargo.toml" \
    --output "$CARGO_TOML"
UNIFFI_VERSION="$(sed -nE 's/^uniffi = \{ version = "([^"]+)".*/\1/p' "$CARGO_TOML" | head -1)"
if [[ -z "$UNIFFI_VERSION" ]]; then
    echo "error: could not determine UniFFI version for $SOURCE_SHA" >&2
    exit 1
fi

echo "==> Installing generated Swift source"
cp "$TEMP_DIR/$SWIFT_ASSET" "$PACKAGE_DIR/Sources/MarmotKit/MarmotKit.swift"
perl -pi -e 's/[ \t]+$//' "$PACKAGE_DIR/Sources/MarmotKit/MarmotKit.swift"

echo "==> Pinning remote binary target"
sed -i '' -E 's|^let marmotKitLocalPath: String\? = .*|let marmotKitLocalPath: String? = nil|' "$PACKAGE_DIR/Package.swift"
rm -f "$PACKAGE_DIR/LOCAL_BUILD.json"
sed -i '' -E \
    "s|^let marmotKitReleaseID = \".*\"|let marmotKitReleaseID = \"$RELEASE_ID\"|" \
    "$PACKAGE_DIR/Package.swift"
sed -i '' -E \
    "s|^let marmotKitReleaseTag = \".*\"|let marmotKitReleaseTag = \"$RELEASE_TAG\"|" \
    "$PACKAGE_DIR/Package.swift"
sed -i '' -E \
    "s|^let marmotKitChecksum = \".*\"|let marmotKitChecksum = \"$EXPECTED_BINARY_CHECKSUM\"|" \
    "$PACKAGE_DIR/Package.swift"

cat > "$PACKAGE_DIR/MARMOT_VERSION" <<EOF
mdk-sha: $SOURCE_SHA
mdk-branch: master
mdk-tag: $RELEASE_TAG
published-at: $PUBLISHED_AT
uniffi-version: $UNIFFI_VERSION
features: $FEATURES
ios-targets: aarch64-apple-ios, aarch64-apple-ios-sim
ios-deployment-target: 18.0
rust-release-opt-level: $RUST_OPT_LEVEL
rust-release-codegen-units: $RUST_CODEGEN_UNITS
swiftpm-checksum: $EXPECTED_BINARY_CHECKSUM

Notes:
- Refresh from a published immutable artifact with:
  whitenoise-ios/scripts/sync-bindings.sh <version-or-full-master-sha>
EOF

cat > "$PACKAGE_DIR/Sources/MarmotKit/MarmotKitVersion.swift" <<EOF
import Foundation

/// Build-time provenance for the pinned MarmotKit release.
/// Regenerated by whitenoise-ios/scripts/sync-bindings.sh on every refresh.
public enum MarmotKitVersion {
    public static let mdkSHA = "$SOURCE_SHA"
    public static let mdkTag = "$RELEASE_TAG"
    public static let builtAt = "$PUBLISHED_AT"
    public static let uniffiVersion = "$UNIFFI_VERSION"
    public static let features = "$FEATURES"
}
EOF

echo ""
echo "Installed MarmotKit $RELEASE_TAG"
echo "  source:   $SOURCE_SHA"
echo "  checksum: $EXPECTED_BINARY_CHECKSUM"
