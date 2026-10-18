// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "FileProviderCore",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  products: [
    .library(
      name: "FileProviderCore",
      targets: ["FileProviderCore"]
    )
  ],
  dependencies: [
    .package(path: "../Common"),
    .package(path: "../DataModel"),
  ],
  targets: [
    // Pure rules for the File Provider extension: identifiers, file names, the
    // folder tree, snapshots and diffs, and domain reconciliation. No
    // FileProvider, UIKit or database import, so everything is host-tested.
    .target(
      name: "FileProviderCore",
      dependencies: [
        .product(name: "DataModel", package: "DataModel")
      ],
      path: "Sources",
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .enableExperimentalFeature("StrictConcurrency"),
      ]
    ),
    .testTarget(
      name: "FileProviderCoreTests",
      dependencies: [
        "FileProviderCore",
        .product(name: "Common", package: "Common"),
        .product(name: "DataModel", package: "DataModel"),
      ]
    ),
  ]
)
