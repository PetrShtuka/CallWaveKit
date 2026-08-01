// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CallWaveKit",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "CallWaveKit",
            targets: ["CallWaveKit"]
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
            publicHeadersPath: ".",
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
                .linkedFramework("PushKit"),
                .linkedFramework("UIKit"),
                .linkedLibrary("m"),
                .linkedLibrary("pthread")
            ]
        )
    ]
)
