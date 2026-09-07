// swift-tools-version:6.0
import PackageDescription

// Keep the release identifier, immutable tag, checksum, and generated Swift
// source synchronized. `scripts/sync-bindings.sh` updates them together from a
// published MarmotKit release.
let marmotKitReleaseID = "snapshot-5f8db5a546ae556f59622656866e21ac1e378be8"
let marmotKitReleaseTag = "marmotkit-snapshot-5f8db5a546ae556f59622656866e21ac1e378be8"
let marmotKitChecksum = "b46071beb1b399af041f1d82f21b6d8612fff7645cfc604adf18f2d73b5004a8"
let marmotKitBinaryURL = "https://github.com/marmot-protocol/mdk/releases/download/\(marmotKitReleaseTag)/MarmotKitFFI-\(marmotKitReleaseID).xcframework.zip"
let package = Package(
    name: "MarmotKit",
    platforms: [
        .iOS(.v18)
    ],
    products: [
        .library(name: "MarmotKit", targets: ["MarmotKit"])
    ],
    targets: [
        .binaryTarget(
            name: "MarmotKitFFI",
            url: marmotKitBinaryURL,
            checksum: marmotKitChecksum
        ),
        .target(
            name: "MarmotKit",
            dependencies: ["MarmotKitFFI"],
            path: "Sources/MarmotKit",
            // UniFFI's generated Swift relies on file-scope `let`/`var`
            // globals that don't satisfy Swift 6's strict concurrency
            // checking. The handle maps are protected internally by Rust-
            // side locks, so compiling this target as Swift 5 is safe and
            // doesn't infect the rest of the app.
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
