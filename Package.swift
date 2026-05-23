// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Bettery",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "Bettery",
            path: "Sources/Bettery",
            resources: [
                .copy("Resources/betterywhiteicon.png")
            ]
        )
    ]
)
