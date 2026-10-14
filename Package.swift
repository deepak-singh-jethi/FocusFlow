// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FocusFlow",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "FocusFlow",
            targets: ["FocusFlow"]
        )
    ],
    targets: [
        .executableTarget(
            name: "FocusFlow",
            path: "Sources/FocusFlow"
        ),
        .testTarget(
            name: "FocusFlowTests",
            dependencies: ["FocusFlow"],
            path: "Tests/FocusFlowTests"
        )
    ]
)
