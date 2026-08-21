// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Flit",
  platforms: [.macOS(.v13)],
  products: [
    .executable(name: "Flit", targets: ["Flit"])
  ],
  targets: [
    .executableTarget(
      name: "Flit",
      linkerSettings: [.linkedLibrary("sqlite3")]
    ),
    .testTarget(
      name: "FlitTests",
      dependencies: ["Flit"]
    ),
  ],
  swiftLanguageModes: [.v5]
)
