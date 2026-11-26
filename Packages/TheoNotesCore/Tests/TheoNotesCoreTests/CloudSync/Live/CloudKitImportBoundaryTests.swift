// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing

/// `import CloudKit` exists only under `Sources/TheoNotesCore/CloudSync/Live/`.
@Suite struct CloudKitImportBoundaryTests {
    private static let packageRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func swiftFiles(under directory: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    private func importsCloudKit(_ url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.split(separator: "\n", omittingEmptySubsequences: true).contains { line in
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let at = words.firstIndex(of: "import") else { return false }
            return words.count > at + 1 && words[at + 1].hasPrefix("CloudKit")
                && !words[..<at].contains(where: { $0.hasPrefix("//") })
        }
    }

    @Test func onlyTheLiveFolderImportsCloudKit() {
        let sources = Self.packageRoot.appendingPathComponent("Sources")
        let live = sources.appendingPathComponent("TheoNotesCore/CloudSync/Live").standardizedFileURL.path + "/"
        let files = swiftFiles(under: sources)
        #expect(files.count > 100, "the scan must see the sources (root: \(Self.packageRoot.path))")
        let offenders = files.filter { importsCloudKit($0) && !$0.standardizedFileURL.path.hasPrefix(live) }.map(\.lastPathComponent)
        #expect(offenders.isEmpty, "files outside CloudSync/Live import CloudKit: \(offenders)")
    }

    @Test func theLiveFolderDoesImportItSoTheScanMeansSomething() {
        let live = Self.packageRoot.appendingPathComponent("Sources/TheoNotesCore/CloudSync/Live")
        #expect(swiftFiles(under: live).contains { importsCloudKit($0) })
    }

    @Test func noOtherTargetOfThePackageImportsIt() {
        let tests = Self.packageRoot.appendingPathComponent("Tests")
        // Tests may exercise the mapping (the Live tests do); no other target under Sources imports it, which the first test covers.
        let outsideLive = swiftFiles(under: tests).filter { importsCloudKit($0) && !$0.path.contains("/CloudSync/Live/") }
        #expect(outsideLive.isEmpty, "\(outsideLive.map(\.lastPathComponent))")
    }
}
