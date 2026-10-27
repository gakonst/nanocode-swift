// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "Console",
  platforms: [.macOS(.v14)],
  dependencies: [.package(path: "../..")],
  targets: [
    .executableTarget(name: "Console", dependencies: [.product(name: "Nanocode", package: "nanocode-swift")]),
  ]
)
