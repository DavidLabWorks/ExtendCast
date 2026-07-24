// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ExtendCastIOS",
    platforms: [
        .iOS(.v13)
    ],
    products: [
        .executable(name: "BetterCastReceiverIOS", targets: ["BetterCastReceiverIOS"])
    ],
    targets: [
        .executableTarget(
            name: "BetterCastReceiverIOS",
            path: "Sources",
            exclude: [
                "Assets.xcassets",
                "Info.plist",
            ],
            linkerSettings: [
                .linkedFramework("UIKit"),
                .linkedFramework("Network"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("AVFoundation"),
            ]
        )
    ]
)
