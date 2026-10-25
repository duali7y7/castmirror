// swift-tools-version:5.9
// Everything the broadcast extension does except talk to ReplayKit: the
// encoders, the fragmented MP4 muxer, the Cast client and the servers the
// receiver connects to. It also builds for macOS, so CI can test it there.
import PackageDescription

let package = Package(
    name: "CastMirrorCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CastMirrorCore", targets: ["CastMirrorCore"]),
    ],
    targets: [
        .target(name: "CastMirrorCore"),
        .testTarget(name: "CastMirrorCoreTests", dependencies: ["CastMirrorCore"]),
    ]
)
