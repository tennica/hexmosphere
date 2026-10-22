// swift-tools-version:5.9
// Uber's H3 v4.1.0 C library (Apache-2.0), vendored as a SwiftPM C target.
import PackageDescription

let package = Package(
    name: "CH3",
    products: [.library(name: "CH3", targets: ["CH3"])],
    targets: [
        .target(
            name: "CH3",
            path: "Sources/CH3",
            linkerSettings: [.linkedLibrary("m")]
        )
    ]
)
