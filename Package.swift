// swift-tools-version:6.0
import Foundation
import PackageDescription

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let local = root.appendingPathComponent("build/NanocodeFFI.xcframework")
let release = (try? JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("ffi-release.json")))) as? [String: String]

let ffi: Target = if FileManager.default.fileExists(atPath: local.path) || release == nil {
  .binaryTarget(name: "NanocodeFFI", path: "build/NanocodeFFI.xcframework")
} else {
  .binaryTarget(name: "NanocodeFFI", url: release!["url"]!, checksum: release!["checksum"]!)
}

let package = Package(
  name: "Nanocode",
  platforms: [.macOS(.v14), .iOS(.v17)],
  products: [
    .library(name: "NanocodeCore", targets: ["NanocodeCore"]),
    .library(name: "NanocodeViews", targets: ["NanocodeViews"]),
    .library(name: "Nanocode", targets: ["Nanocode"]),
    .library(name: "NanocodeKit", targets: ["NanocodeKit"]),
  ],
  targets: [
    ffi,
    .target(name: "NanocodeCore"),
    .target(name: "NanocodeViews", dependencies: ["NanocodeCore"]),
    .target(
      name: "Nanocode",
      dependencies: ["NanocodeCore", "NanocodeFFI"],
      resources: [.copy("Resources/python.js"), .copy("Resources/pyodide-host.js"), .copy("Resources/shell")],
      linkerSettings: [
        .linkedFramework("Security"),
        .linkedFramework("SystemConfiguration"),
        .linkedFramework("CoreFoundation"),
        .linkedLibrary("resolv"),
        .linkedFramework("WebKit"),
      ]
    ),
    .target(name: "NanocodeKit", dependencies: ["NanocodeCore", "Nanocode"]),
  ]
)
