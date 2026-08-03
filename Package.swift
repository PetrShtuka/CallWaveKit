// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CallWaveKit",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        // Depending on this product gives both modules: `CallWaveKit` for the
        // Objective-C API and `CallWaveKitAsync` for the Swift concurrency
        // conveniences layered on top of it.
        .library(
            name: "CallWaveKit",
            targets: ["CallWaveKit", "CallWaveKitAsync"]
        )
    ],
    targets: [
        .binaryTarget(
            name: "PJSIP",
            path: "Vendor/PJSIP.xcframework"
        ),
        .target(
            name: "CallWaveKit",
            dependencies: ["PJSIP"],
            path: "CallWaveKit",
            exclude: ["README.md"],
            resources: [
                .copy("PrivacyInfo.xcprivacy")
            ],
            publicHeadersPath: "include",
            cSettings: [
                .define("PJ_AUTOCONF", to: "1")
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CallKit"),
                .linkedFramework("CFNetwork"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Network"),
                .linkedFramework("PushKit"),
                .linkedFramework("Security"),
                .linkedFramework("UIKit"),
                .linkedLibrary("m"),
                .linkedLibrary("pthread")
            ]
        ),
        .target(
            name: "CallWaveKitAsync",
            dependencies: ["CallWaveKit"],
            path: "CallWaveKitAsync"
        ),
        .testTarget(
            name: "CallWaveKitTests",
            dependencies: ["CallWaveKit", "CallWaveKitAsync"],
            path: "Tests/CallWaveKitTests"
        ),
        // CallWaveCallRegistry is an implementation detail behind a private
        // header, so its tests are Objective-C and reach it through a header
        // search path rather than through the module. Keeping them out of the
        // Swift target is what avoids widening the public API for testing.
        .testTarget(
            name: "CallWaveKitRegistryTests",
            dependencies: ["CallWaveKit"],
            path: "Tests/CallWaveKitRegistryTests",
            cSettings: [
                .headerSearchPath("../../CallWaveKit")
            ]
        )
    ]
)
