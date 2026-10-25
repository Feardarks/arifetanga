// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "NitMath",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "NitMath", targets: ["NitMath"]),
    ],
    targets: [
        .target(name: "NitMath"),
        .testTarget(name: "NitMathTests", dependencies: ["NitMath"]),
    ]
)
