// swift-tools-version: 6.0
import PackageDescription

// MARK: - Build configuration
//
// Deployment target — measured limits of the Xcode 27 / Swift 6.4 toolchain:
//
//   * Swift Package Manager cannot express anything below macOS 12.0. Setting
//     `.v10_15` or `.v11` here is silently raised to 12.0 (verified by
//     inspecting LC_BUILD_VERSION on the built binary).
//   * The toolchain's own floor is macOS 11.0: even `swiftc -target
//     arm64-apple-macosx10.13` emits minos 11.0.
//
// So `.v12` is the lowest value this declaration can honour, and the build
// script supplies the extra target override when a genuinely 11.0 build is
// wanted (`./scripts/build_universal.sh --min-os 11.0`).
//
// Universal arm64 + x86_64 is likewise the build script's job, not this file's.
let deploymentTarget: SupportedPlatform.MacOSVersion = .v12

let package = Package(
    name: "GraphDigger",
    platforms: [.macOS(deploymentTarget)],
    products: [
        .executable(name: "GraphDigger", targets: ["GraphDiggerApp"]),
        .library(name: "GDCore", targets: ["GDCore"]),
    ],
    targets: [
        // Pure domain logic: no AppKit, no UI. Ported from the Phase 0 Python
        // reference implementation (proto/) and regression-tested against the
        // same synthetic charts.
        .target(name: "GDCore"),

        // AppKit shell. Grows into the full UI per the architecture doc.
        //
        // `Resources/` holds the two payment QR images shown in the About panel.
        // They are **excluded from SwiftPM on purpose**, and the build script
        // copies them into the .app's `Contents/Resources` instead. The
        // alternative — SwiftPM's own resource bundle — needs `Bundle.module`,
        // which **traps at launch** when the bundle is not beside the executable,
        // and this app is packaged by hand (binary + Info.plist + icns). A
        // missing image should show a placeholder, not kill the app.
        .executableTarget(
            name: "GraphDiggerApp",
            dependencies: ["GDCore"],
            exclude: ["Resources"]
        ),

        .testTarget(
            name: "GDCoreTests",
            dependencies: ["GDCore"]
        ),
    ],
    // Swift 5 language mode for the skeleton: keeps AppKit delegate code free of
    // strict-concurrency annotation churn. Migrate to v6 deliberately later.
    swiftLanguageModes: [.v5]
)
