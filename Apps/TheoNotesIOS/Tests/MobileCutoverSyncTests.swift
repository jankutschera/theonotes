// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import Testing
@testable import TheoNotesCore
@testable import BaerchenIOS

@Suite @MainActor struct MobileCutoverSyncTests {
    @Test func initialPullThenMergeKeepsRemoteSettingsAndBothLibraries() async throws {
        let helpers = MobileSyncResponsivenessTests()
        let remote = try helpers.temporaryLibrary()
        let oldPhone = try helpers.temporaryLibrary()
        let newPhone = try helpers.temporaryLibrary()
        defer {
            for library in [remote, oldPhone, newPhone] {
                try? library.close()
                try? FileManager.default.removeItem(at: library.paths.root)
            }
        }
        let key = SymmetricKey(size: .bits256)
        let server = MobileSyncResponsivenessTests.GatedTransport()
        try SyncQueue(database: remote.database).enable(accountID: "account")
        let remoteNote = try remote.store.create(text: "# Remote note")
        try Settings(db: remote.database).set(.hideMarkdown, to: false)
        let sender = helpers.engine(remote, server, key)
        _ = try await sender.synchronize()

        let offlineNote = try oldPhone.store.create(text: "# Offline note")
        try Settings(db: oldPhone.database).set(.hideMarkdown, to: true)
        let backup = try await oldPhone.makeBackup()
        try SyncQueue(database: newPhone.database).enable(accountID: "account")
        let receiver = helpers.engine(newPhone, server, key)
        _ = try await receiver.synchronize()
        #expect(try newPhone.store.note(id: remoteNote.id)?.text == "# Remote note")
        #expect(try Settings(db: newPhone.database).value(.hideMarkdown) == false)
        let result = try await newPhone.restoreBackup(backup, mode: .merge, backupPassword: nil, currentPassword: nil)
        #expect(result.restored == 1)
        #expect(try newPhone.store.note(id: offlineNote.id)?.text == "# Offline note")
        #expect(try newPhone.store.note(id: remoteNote.id)?.text == "# Remote note")
        #expect(try Settings(db: newPhone.database).value(.hideMarkdown) == false)
        _ = try await receiver.synchronize()
        _ = try await sender.synchronize()
        #expect(try remote.store.note(id: offlineNote.id)?.text == "# Offline note")
        #expect(try Settings(db: remote.database).value(.hideMarkdown) == false)
        await receiver.shutdown()
        await sender.shutdown()
    }
}
