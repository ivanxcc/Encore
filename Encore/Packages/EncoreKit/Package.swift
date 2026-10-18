// swift-tools-version:6.0
import PackageDescription

// EncoreKit is the whole "engine": the Stremio add-on protocol, the Stremio account + library API,
// stream ranking, and household/profile storage. Pure Swift on Foundation, so it builds for every
// Apple platform (and both Mac architectures) with no Rust, no FFI, and no private dependencies,
// and its tests run on Linux CI too.
let package = Package(
    name: "EncoreKit",
    platforms: [.iOS(.v18), .tvOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "EncoreKit", targets: ["EncoreKit"]),
    ],
    targets: [
        .target(name: "EncoreKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "EncoreKitTests", dependencies: ["EncoreKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
