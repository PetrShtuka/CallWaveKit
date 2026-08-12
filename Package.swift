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
        // Prebuilt PJSIP 2.17 with Opus and SHA-256 digest support; rebuild
        // instructions live in Vendor/PJSIP-BUILD.txt.
        .binaryTarget(
            name: "PJSIP",
            url: "https://github.com/PetrShtuka/CallWaveKit/releases/download/pjsip-2.17-ios15-opus-sha256.1/PJSIP.xcframework.zip",
            checksum: "f534773f4dc0e813d0e7a7e3be10a751804232721876d1bad286ab3cba0d16a4"
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
                .headerSearchPath("../../CallWaveKit"),
                // The capability tests import the PJSIP module directly, so
                // the target needs the same autoconf switch as the library.
                .define("PJ_AUTOCONF", to: "1")
            ]
        )
    ]
)
