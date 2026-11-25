// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

@Suite struct EditJournalCreationAttributesTests {
    @Test func explicitAttributesExistBeforeBasePayloadAndSurviveReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try EditJournal(directory: root, noteId: "draft",
            creationAttributes: [.protectionKey: FileProtectionType.complete, .posixPermissions: 0o600])
        var observed = 0
        journal.beforeBaseWrite = { temporary in
            observed += 1
            #expect(try Data(contentsOf: temporary).isEmpty, "Protection must precede every payload write")
            let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            #if os(iOS) && !targetEnvironment(simulator)
            let protection = (attributes[.protectionKey] as? FileProtectionType)?.rawValue ?? attributes[.protectionKey] as? String
            #expect(protection == FileProtectionType.complete.rawValue)
            #endif
        }
        try journal.writeBase(JournalBase(storeRevision: 1, baseText: "first private snapshot"))
        try journal.writeBase(JournalBase(storeRevision: 2, baseText: "second private snapshot"))
        #expect(observed == 2)
        #expect(try journal.base()?.baseText == "second private snapshot")
        for file in [journal.fileURL, journal.baseURL] {
            #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
    }
}
