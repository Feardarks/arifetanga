// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "NitMath",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "NitMath", targets: ["NitMath"]),
        // Saf Swift kapsayıcı/bit akışı yardımcıları (NAL birimleri, hvcC/avcC); Linux'ta test edilir.
        .library(name: "MediaFormat", targets: ["MediaFormat"]),
    ],
    targets: [
        .target(name: "NitMath"),
        .target(name: "MediaFormat"),
        .testTarget(name: "NitMathTests", dependencies: ["NitMath"]),
        .testTarget(name: "MediaFormatTests", dependencies: ["MediaFormat"]),
    ]
)
