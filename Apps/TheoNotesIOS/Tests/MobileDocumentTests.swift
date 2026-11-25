// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import BaerchenIOS

@Suite struct MobileDocumentTests {
    @Test func packageSnapshotWritesNestedFilesWithoutReadingDirectoryAsRegularFile() throws {
        let bytes = Data([0, 255, 128, 1])
        let source = Data("# Export 🐻\n![](assets/photo.png)".utf8)
        let wrapper = FileWrapper(directoryWithFileWrappers: [
            "text.md": FileWrapper(regularFileWithContents: source),
            "info.json": FileWrapper(regularFileWithContents: Data("{\"version\":2}".utf8)),
            "assets": FileWrapper(directoryWithFileWrappers: [
                "photo.png": FileWrapper(regularFileWithContents: bytes),
                "empty": FileWrapper(directoryWithFileWrappers: [:])
            ])
        ])
        // Foundation raises an Objective-C exception for regularFileContents on a directory.
        // Building this document exercised that fatal path before the type guards existed.
        let document = try MobileExportDocument(wrapper: wrapper)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".textbundle")
        defer { try? FileManager.default.removeItem(at: path) }
        try document.fileSnapshot.write(to: path, options: .atomic, originalContentsURL: nil)
        #expect(try Data(contentsOf: path.appendingPathComponent("text.md")) == source)
        #expect(try Data(contentsOf: path.appendingPathComponent("assets/photo.png")) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: path.appendingPathComponent("assets/empty").path).isEmpty)
    }

    @Test func ordinaryFileRoundTripsAndSymbolicLinkIsRejectedWithoutFoundationException() throws {
        let bytes = Data("Plain text café".utf8)
        let document = try MobileExportDocument(wrapper: FileWrapper(regularFileWithContents: bytes))
        #expect(document.fileSnapshot.regularFileContents == bytes)
        let link = FileWrapper(symbolicLinkWithDestinationURL: URL(fileURLWithPath: "/nonexistent-export-fixture"))
        #expect(throws: (any Error).self) { _ = try MobileExportDocument(wrapper: link) }
        #expect(throws: (any Error).self) {
            _ = try MobileExportDocument(wrapper: FileWrapper(directoryWithFileWrappers: ["link": link]))
        }
    }
}
