// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Jutilities",
    platforms: [.macOS(.v15)],
    products: [.library(name: "JutilitiesCore", targets: ["JutilitiesCore"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "JutilitiesCore", dependencies: ["CSQLite"]),
        .testTarget(name: "JutilitiesCoreTests", dependencies: ["JutilitiesCore"])
    ],
    swiftLanguageModes: [.v5]
)
