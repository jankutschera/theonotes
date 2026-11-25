// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import Testing
@testable import TheoNotesCore

/// REN2-R45 ... R49 (rename stage 2, task A2): every persisted identity string and every frozen crypto or
/// protocol label has ONE source (`LegacyNames`, `ProtocolLabels`). These pins hold today's bytes. A value that
/// changes here breaks data on disk (locked notes, edit journals), the Keychain items of the installed app or the
/// signatures the sync Worker verifies. The only legitimate way to change an identity string is the cutover
/// (task B7), which edits the pin and `scripts/check-identities.sh` in the same commit.
@Suite struct IdentityPinsTests {
    private static let frozenLabels: [(name: String, value: String)] = [
        ("envelope", "baerchen-envelope-v1"), ("journal", "baerchen-journal-v1"),
        ("syncCipher", "baerchen-sync:1"), ("account", "baerchen-account:1"),
        ("transfer", "baerchen-transfer:1"), ("transferKey", "baerchen-transfer-key:1"),
        ("transferWords", "baerchen-transfer-words:1"), ("deviceName", "baerchen-device-name:1"),
        ("conflict", "baerchen-conflict:1"), ("request", "baerchen-request:1"),
        ("recovery", "baerchen-recovery:1"), ("semanticID", "baerchen-semantic-id:1"),
    ]

    static let expectedSyncService = "com.truebrewbirdie.theonotes.sync"

    @Test func test_pinned_persisted_strings_are_unchanged() {
        #expect(AppIdentity.productionBundleIdentifier == "com.truebrewbirdie.theonotes")
        #expect(AppIdentity.devBundleIdentifier == "com.truebrewbirdie.theonotes.dev")
        #expect(AppIdentity.production.shareExtensionBundleIdentifier == "com.truebrewbirdie.theonotes.share")
        #expect(AppIdentity.production.urlSchemes == ["theonotes", "baerchen"])
        #expect(AppIdentity.dev.urlSchemes == ["theonotes-dev", "baerchen-dev"])
        #expect(AppIdentity.production.appGroupIdentifier(team: "TEAMID1234") == "TEAMID1234.com.truebrewbirdie.notes")
        #expect(AppIdentity.production.keychainAccessGroup(team: "TEAMID1234") == "TEAMID1234.com.truebrewbirdie.theonotes")
        #expect(KeychainSyncStore.keychainService == Self.expectedSyncService)
        #expect(AppPaths(root: URL(fileURLWithPath: "/tmp/pins")).database.lastPathComponent == "Baerchen.sqlite")
        #expect(AppPaths.legacyLibraryFolderName == "Baerchen")
        #expect(AppPaths.dataDirEnvironmentKey == "BAERCHEN_DATA_DIR")
        #expect(ThemeCatalog.defaultLightId == "baerchen-red")
        #expect(ThemeCatalog.defaultDarkId == "baerchen-dark")
    }

    @Test func test_frozen_labels_bytes() throws {
        #expect(Self.frozenLabels.count == 12)
        #expect(Set(Self.frozenLabels.map(\.value)).count == 12)
        try Self.assertEnumMatchesFrozenLabels()
    }

    @Test func test_frozen_label_vectors_still_decrypt_and_verify() throws {
        let f = try CanonicalCryptoV1Fixture.load()
        // baerchen-envelope-v1 is the AAD of the wrapped vault key.
        #expect(CanonicalCryptoV1Fixture.bytes(try f.envelope.unwrap(
            password: f.password, allowedIterations: CryptoEnvelope.testIterationRange)) == f.vaultKey)
        // baerchen-journal-v1 is in the AAD of the journal base and every entry.
        let dir = try CanonicalCryptoV1Fixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(f.bjb1.utf8).write(to: dir.appendingPathComponent(f.noteId + ".base"))
        try Data((f.bje1.joined(separator: "\n") + "\n").utf8).write(to: dir.appendingPathComponent(f.noteId + ".jsonl"))
        let journal = try EditJournal(directory: dir, noteId: f.noteId, encryptionKey: f.key)
        #expect(try journal.base()?.baseText == "Synthetic base 漢字")
        #expect(try journal.entries().count == 2)
        // baerchen-sync:1 is the cipher context of a sync payload.
        struct Wire: Decodable { let accountId: String; let mutation: SyncMutation; let cipherContext: String }
        let url = SchemaSnapshotTests.fixtureDir.deletingLastPathComponent().appendingPathComponent("sync/protocol-v1.json")
        let wire = try JSONDecoder().decode(Wire.self, from: Data(contentsOf: url))
        #expect(try SyncWire.cipherContext(accountID: wire.accountId, type: wire.mutation.entityType,
                                           entityID: wire.mutation.entityId) == wire.cipherContext)
        #expect(wire.cipherContext == "baerchen-sync:1:account-fixture-001:note:note-fixture-001:1")
    }
}

extension IdentityPinsTests {
    static func assertEnumMatchesFrozenLabels() throws {
        let actual: [(String, String)] = [
            ("envelope", ProtocolLabels.envelope), ("journal", ProtocolLabels.journal),
            ("syncCipher", ProtocolLabels.syncCipher), ("account", ProtocolLabels.account),
            ("transfer", ProtocolLabels.transfer), ("transferKey", ProtocolLabels.transferKey),
            ("transferWords", ProtocolLabels.transferWords), ("deviceName", ProtocolLabels.deviceName),
            ("conflict", ProtocolLabels.conflict), ("request", ProtocolLabels.request),
            ("recovery", ProtocolLabels.recovery), ("semanticID", ProtocolLabels.semanticID),
        ]
        #expect(actual.count == frozenLabels.count)
        for (name, value) in frozenLabels {
            let match = actual.first { $0.0 == name }
            #expect(match?.1 == value, "ProtocolLabels.\(name) changed")
            #expect(Array((match?.1 ?? "").utf8) == Array(value.utf8), "ProtocolLabels.\(name) bytes changed")
        }
    }

    @Test func test_legacy_names_hold_todays_values() {
        #expect(LegacyNames.libraryFolder == "Baerchen")
        #expect(LegacyNames.databaseFile == "Baerchen.sqlite")
        #expect(LegacyNames.backupExtension == "baerchen-backup")
        #expect(LegacyNames.backupUTI == "com.truebrewbirdie.baerchen.backup")
        #expect(LegacyNames.bundleRoot == "com.truebrewbirdie.theonotes")
        #expect(LegacyNames.urlScheme == "baerchen")
        #expect(LegacyNames.dataDirEnvironment == "BAERCHEN_DATA_DIR")
        #expect(LegacyNames.themeIDs == ["baerchen-red": "theo-red", "baerchen-dark": "theo-dark"])
        #expect(LegacyNames.noteIDsUTI == "com.truebrewbirdie.theonotes.note-ids")
        #expect(LegacyNames.tagPathUTI == "com.truebrewbirdie.theonotes.tag-path")
        #expect(LegacyNames.syncKeychainService == "com.truebrewbirdie.theonotes.sync")
        #expect(LegacyNames.preCutoverBundleRoot == "com.truebrewbirdie.baerchen")
        #expect(LegacyNames.vaultKeychainService == "com.truebrewbirdie.theonotes.note-vault")
        #expect(AppIdentity.productionBundleIdentifier == LegacyNames.bundleRoot)
    }

    /// REN2-R51 (task B3): the stores read their Keychain services from `AppIdentity`, which reads the bundle root, so the
    /// cutover moves them with the bundle id. Today's bytes are the ones the installed app's items live under.
    @Test func test_keychain_services_follow_the_bundle_root_and_keep_todays_bytes() {
        #expect(AppIdentity.syncKeychainService == AppIdentity.productionBundleIdentifier + ".sync")
        #expect(AppIdentity.vaultKeychainService == AppIdentity.productionBundleIdentifier + ".note-vault")
        #expect(KeychainSyncStore.keychainService == AppIdentity.syncKeychainService)
        #expect(Array(AppIdentity.syncKeychainService.utf8) == Array(Self.expectedSyncService.utf8))
        #expect(Array(AppIdentity.vaultKeychainService.utf8) == Array("com.truebrewbirdie.theonotes.note-vault".utf8))
        // The dev build is told apart by its access group, not by a second service name.
        #expect(AppIdentity.dev.keychainAccessGroup(team: "TEAMID1234") != AppIdentity.production.keychainAccessGroup(team: "TEAMID1234"))
    }

    /// `config/identity.env` is what project.yml feeds to every bundle id, UTType and URL type; the Swift
    /// source of the same string must equal it (scripts/check-identities.sh checks the built settings too).
    @Test func test_identity_env_equals_the_swift_bundle_root() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("config/identity.env"), encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines == ["THEONOTES_BUNDLE_ROOT=" + LegacyNames.bundleRoot])
    }
}
