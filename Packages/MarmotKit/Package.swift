// swift-tools-version:6.0
import PackageDescription

// Keep the release identifier, immutable tag, checksum, and generated Swift
// source synchronized. `scripts/sync-bindings.sh` updates them together from a
// published MarmotKit release.
let marmotKitReleaseID = "0.10.2"
let marmotKitReleaseTag = "marmotkit-v0.10.2"
let marmotKitChecksum = "959e86fb187038646782fdf3be73e1985a86ad7bac69ee1d2dc422e5004a1d8e"
let marmotKitBinaryURL = "https://github.com/marmot-protocol/mdk/releases/download/\(marmotKitReleaseTag)/MarmotKitFFI-\(marmotKitReleaseID).xcframework.zip"
// Explicit local pin: never silently link an older remote binary to new Swift.
let marmotKitLocalPath: String? = nil
let marmotKitBinaryTarget: Target = marmotKitLocalPath.map {
    .binaryTarget(name: "MarmotKitFFI", path: $0)
} ?? .binaryTarget(name: "MarmotKitFFI", url: marmotKitBinaryURL, checksum: marmotKitChecksum)
let package = Package(
    name: "MarmotKit",
    platforms: [
        .iOS(.v18)
    ],
    products: [
        .library(name: "MarmotKit", targets: ["MarmotKit"])
    ],
    targets: [
        marmotKitBinaryTarget,
        .target(
            name: "MarmotKit",
            dependencies: ["MarmotKitFFI"],
            path: "Sources/MarmotKit",
            resources: [.copy("Resources/PrivacyInfo.xcprivacy")],
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
