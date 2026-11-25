// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing

@testable import TheoNotesCore

/// The Acknowledgements list (LIC-R*): `Apps/TheoNotesMac/Resources/Acknowledgements.json` is written
/// by `scripts/gen-acknowledgements.py`; this is the app-side reading of it.
@Suite struct AcknowledgementsCatalogTests {
    private static let json = """
        {
         "schemaVersion": 1,
         "texts": {
          "t1": "MIT License\\n\\n{{copyright}}\\n\\nPermission is hereby granted.",
          "t2": "Apache License text",
          "n1": "A NOTICE file"
         },
         "entries": [
          {"name": "alpha", "version": "1.0", "kind": "npm", "licence": "MIT", "copyright": "Copyright (c) 2020 Alpha",
           "copyrightBlock": "Copyright (c) 2020 Alpha\\nCopyright (c) 2021 Beta", "textId": "t1", "source": "https://example.com/alpha", "usedIn": "Editor"},
          {"name": "Zed", "version": "2.0", "kind": "swiftpm", "licence": "Apache-2.0", "copyright": "Copyright held by the Zed authors",
           "textId": "t2", "noticeId": "n1", "source": "", "usedIn": "App", "note": "Source code: https://example.com/zed"},
          {"name": "ghost", "version": "3", "kind": "npm", "licence": "MIT", "copyright": "Copyright (c) Ghost",
           "textId": "missing", "source": "", "usedIn": "Editor"}
         ]
        }
        """

    private func catalog() throws -> AcknowledgementsCatalog {
        try AcknowledgementsCatalog(jsonData: Data(Self.json.utf8))
    }

    @Test func decodesEntriesInFileOrder() throws {
        let catalog = try catalog()
        #expect(catalog.entries.map(\.name) == ["alpha", "Zed", "ghost"])
        #expect(catalog.entries[0].kind == .npm)
        #expect(catalog.entries[1].kind == .swiftpm)
        #expect(catalog.entries[1].note == "Source code: https://example.com/zed")
        #expect(catalog.entries[0].id == "npm:alpha@1.0")
    }

    @Test func theCopyrightBlockGoesBackIntoTheText() throws {
        let catalog = try catalog()
        let text = try #require(catalog.licenceText(for: catalog.entries[0]))
        #expect(text == "MIT License\n\nCopyright (c) 2020 Alpha\nCopyright (c) 2021 Beta\n\nPermission is hereby granted.")
        #expect(catalog.licenceText(for: catalog.entries[1]) == "Apache License text")
    }

    @Test func aMissingTextIsNilNotEmpty() throws {
        let catalog = try catalog()
        #expect(catalog.licenceText(for: catalog.entries[2]) == nil)
        #expect(catalog.entriesWithoutLicenceText.map(\.name) == ["ghost"])
    }

    @Test func noticeTextIsOptional() throws {
        let catalog = try catalog()
        #expect(catalog.noticeText(for: catalog.entries[0]) == nil)
        #expect(catalog.noticeText(for: catalog.entries[1]) == "A NOTICE file")
    }

    @Test func searchMatchesNameLicenceCopyrightAndUseIgnoringCaseAndAccents() throws {
        let catalog = try catalog()
        #expect(catalog.search("").map(\.name) == ["alpha", "Zed", "ghost"])
        #expect(catalog.search("ZED").map(\.name) == ["Zed"])
        #expect(catalog.search("apache").map(\.name) == ["Zed"])
        #expect(catalog.search("ghost beta").isEmpty)
        #expect(catalog.search("  mit  ").map(\.name) == ["alpha", "ghost"])
        #expect(catalog.search("swiftpm").isEmpty)
        #expect(catalog.search("copyright 2020").map(\.name) == ["alpha"])
    }

    @Test func aNewerSchemaIsRefused() {
        let data = Data(#"{"schemaVersion": 99, "texts": {}, "entries": []}"#.utf8)
        #expect(throws: AcknowledgementsCatalog.LoadError.self) { try AcknowledgementsCatalog(jsonData: data) }
    }

    @Test func notJSONIsRefused() {
        #expect(throws: (any Error).self) { try AcknowledgementsCatalog(jsonData: Data("nope".utf8)) }
    }

    // MARK: the committed file

    private static var committed: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()  // TheoNotesCoreTests, Tests
            .deletingLastPathComponent().deletingLastPathComponent()  // TheoNotesCore, Packages
            .deletingLastPathComponent()
            .appendingPathComponent("Apps/TheoNotesMac/Resources/Acknowledgements.json")
    }

    @Test func theCommittedFileNamesGRDBAndCodeMirrorButNotElkjs() throws {
        let catalog = try AcknowledgementsCatalog(jsonData: Data(contentsOf: Self.committed))
        let grdb = try #require(catalog.entries.first { $0.name == "GRDB.swift" })
        #expect(grdb.licence == "MIT" && grdb.kind == .swiftpm)
        let codemirror = try #require(catalog.entries.first { $0.name == "@codemirror/view" })
        #expect(codemirror.licence == "MIT" && codemirror.kind == .npm)
        // REN2-R10: elkjs (EPL-2.0) is not part of the app.
        #expect(catalog.entries.contains { $0.name == "elkjs" } == false)
        #expect(catalog.entries.contains { $0.licence == "EPL-2.0" } == false)
    }

    @Test func sourceCodeLinkIsOptional() throws {
        let catalog = try catalog()
        #expect(catalog.entries.allSatisfy { $0.sourceCode == nil })
        let data = Data(#"{"schemaVersion": 1, "texts": {"a": "x"}, "entries": [{"name": "p", "version": "1", "kind": "npm", "licence": "EPL-2.0", "copyright": "c", "textId": "a", "source": "", "sourceCode": "https://example.com/p/tree/1", "usedIn": ""}]}"#.utf8)
        #expect(try AcknowledgementsCatalog(jsonData: data).entries[0].sourceCode == "https://example.com/p/tree/1")
    }

    @Test func everyCommittedEntryHasLicenceTextAndCopyright() throws {
        let catalog = try AcknowledgementsCatalog(jsonData: Data(contentsOf: Self.committed))
        #expect(catalog.entries.count > 50)
        #expect(catalog.entriesWithoutLicenceText.isEmpty)
        for entry in catalog.entries {
            #expect(!entry.copyright.isEmpty, "\(entry.name) has no copyright line")
            let text = catalog.licenceText(for: entry) ?? ""
            #expect(text.count > 200, "\(entry.name) has no real licence text")
            #expect(!text.contains("{{copyright}}"), "\(entry.name) still has the placeholder")
        }
    }
}
