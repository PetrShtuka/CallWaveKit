// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CallWaveSIP",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "CallWaveSIP",
            targets: ["CallWaveSIP"]
        )
    ],
    targets: [
        .target(
            name: "CallWaveSIPObjC",
            dependencies: [],
            path: "Sources/CallWaveSIPObjC",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include")
            ]
        ),
        .target(
            name: "CallWaveSIP",
            dependencies: ["CallWaveSIPObjC"],
            path: "Sources/CallWaveSIP"
        ),
        .testTarget(
            name: "CallWaveSIPTests",
            dependencies: ["CallWaveSIP"],
            path: "Tests/CallWaveSIPTests"
        )
    ]
)
