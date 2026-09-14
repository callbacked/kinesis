// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kinesis",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Kinesis", targets: ["Kinesis"])],
    targets: [
        .target(name: "KinesisCore"),
        .executableTarget(name: "Kinesis", dependencies: ["KinesisCore"], resources: [.process("Resources")]),
        .testTarget(name: "KinesisCoreTests", dependencies: ["KinesisCore"]),
        .testTarget(name: "KinesisTests", dependencies: ["Kinesis", "KinesisCore"]),
    ]
)
