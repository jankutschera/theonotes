// swift-tools-version: 6.2
// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import PackageDescription

// The developer compatibility checker `bear-oracle` and its tests live only in the private repository;
// the public export leaves `Sources/bear-oracle` out, so the package declares them only when they are there.
let hasOracle = FileManager.default.fileExists(atPath: Context.packageDirectory + "/Sources/bear-oracle")
let oracleTargets: [Target] = hasOracle ? [
    .executableTarget(
        name: "bear-oracle",
        dependencies: ["TheoNotesCore", "TheoNotesAutomation", .product(name: "GRDB", package: "GRDB.swift")]
    ),
    .testTarget(name: "BearOracleTests", dependencies: ["bear-oracle", "TheoNotesCore", "TheoNotesAutomation"]),
] : []

let package = Package(
    name: "TheoNotesCore",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "TheoNotesCore", targets: ["TheoNotesCore"]),
        .library(name: "TheoNotesAutomation", targets: ["TheoNotesAutomation"]),
        .library(name: "TheoNotesVoice", targets: ["TheoNotesVoice"]),
        .executable(name: "theonotes", targets: ["theonotes"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
    ],
    targets: [
        .target(
            name: "TheoNotesCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift"), .product(name: "ZIPFoundation", package: "ZIPFoundation")],
            resources: [.process("Resources")]
        ),
        .target(
            name: "TheoNotesAutomation",
            dependencies: ["TheoNotesCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .executableTarget(name: "theonotes", dependencies: ["TheoNotesAutomation"]),
        // Voice capture (Speech, AVFoundation) stays out of the CLI and the automation layer.
        .target(name: "TheoNotesVoice", dependencies: ["TheoNotesCore"]),
        .testTarget(name: "TheoNotesCoreTests", dependencies: ["TheoNotesCore"]),
        .testTarget(
            name: "TheoNotesAutomationTests",
            dependencies: ["TheoNotesAutomation", "theonotes", "TheoNotesCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(name: "TheoNotesVoiceTests", dependencies: ["TheoNotesVoice", "TheoNotesCore"]),
    ] + oracleTargets
)
