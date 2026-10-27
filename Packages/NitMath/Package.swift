// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "NitMath",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "NitMath", targets: ["NitMath"]),
        // Saf Swift kapsayıcı/bit akışı yardımcıları (NAL birimleri, hvcC/avcC); Linux'ta test edilir.
        .library(name: "MediaFormat", targets: ["MediaFormat"]),
        // Saf Swift ses DSP'si (loudness, F1 merkez çıkarma, M9 diyalog çekirdeği); Linux'ta test edilir.
        .library(name: "AudioDSP", targets: ["AudioDSP"]),
    ],
    targets: [
        .target(name: "NitMath"),
        .target(name: "MediaFormat"),
        .target(name: "AudioDSP"),
        .testTarget(name: "NitMathTests", dependencies: ["NitMath"]),
        .testTarget(name: "MediaFormatTests", dependencies: ["MediaFormat"]),
        .testTarget(name: "AudioDSPTests", dependencies: ["AudioDSP"]),
    ]
)
