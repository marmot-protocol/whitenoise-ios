// swift-tools-version:6.0
import PackageDescription

// Local Swift package that wraps the prebuilt MarmotKit.xcframework (the Rust
// `marmot-uniffi` crate, compiled for iOS device + simulator) together with
// the generated UniFFI Swift bindings.
//
// The iOS app depends on this package by adding it as a local package
// reference inside Xcode (File → Add Package Dependencies… → Add Local…).
//
// To refresh the bundle from a new darkmatter build:
//   1) Run `crates/marmot-uniffi/xcframework.sh` in the darkmatter repo.
//   2) Copy `crates/marmot-uniffi/output/MarmotKit.xcframework` into this
//      directory, replacing the existing one.
//   3) Copy `crates/marmot-uniffi/output/MarmotKit.swift` into
//      `Sources/MarmotKit/MarmotKit.swift`.
//   4) Update `MARMOT_VERSION` with the new darkmatter commit SHA.

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
            path: "MarmotKit.xcframework"
        ),
        .target(
            name: "MarmotKit",
            dependencies: ["MarmotKitFFI"],
            path: "Sources/MarmotKit",
            // UniFFI 0.28's generated Swift relies on file-scope `let`/`var`
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
