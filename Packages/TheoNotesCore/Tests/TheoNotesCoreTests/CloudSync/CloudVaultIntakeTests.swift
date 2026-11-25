// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

@Suite struct CloudVaultIntakeTests {
    @Test func authenticatedVaultDeletionCountsAsAbsent() async throws {
        try await withBlobWorld(2) { world in
            let donor = world.devices[0], recipient = world.devices[1]
            try await recipient.db.pool.write { try $0.execute(sql: "UPDATE ck_state SET cloudUserHash=? WHERE id=1", arguments: [world.account.userHash]) }
            let privacy = NotePrivacy(store: donor.noteStore)
            let access = try privacy.setPassword("password")
            try await donor.publish()
            access.revoke()
            try privacy.deletePassword()
            try await donor.publish()
            let intake = CloudVaultIntake(database: recipient.db, gateway: recipient.gateway, accountID: recipient.accountID, vaultKey: recipient.key)
            #expect(try await intake.vaultIsAbsent())
            #expect(try await intake.scan(password: "password") == nil)
        }
    }
    @Test(arguments: ["match", "mismatch", "empty"]) func existingLockedRowsRequireMatchingKeyWhenSealed(kind: String) async throws {
        try await withBlobWorld(2) { world in
            let donor = world.devices[0], recipient = world.devices[1]
            try await recipient.db.pool.write { try $0.execute(sql: "UPDATE ck_state SET cloudUserHash=? WHERE id=1", arguments: [world.account.userHash]) }
            let access = try NotePrivacy(store: donor.noteStore).setPassword("password")
            defer { access.revoke() }
            try await donor.publish()
            let selected = try kind == "mismatch" ? SymmetricKey(size: .bits256) : access.journalKey()
            let body = kind == "empty" ? nil : try NoteCipher.seal(Data("sealed".utf8), vaultKey: selected, context: "locked")
            try await recipient.db.pool.write { db in
                try Note(id: "locked", text: "", title: "", titleKey: "", createdAt: .now, modifiedAt: .now,
                         isLocked: true, encryptedPayload: body).insert(db)
            }
            let intake = CloudVaultIntake(database: recipient.db, gateway: recipient.gateway, accountID: recipient.accountID, vaultKey: recipient.key)
            let candidate = try #require(try await intake.scan(password: "password"))
            if kind == "mismatch" {
                do {
                    _ = try await intake.install(candidate, fenced: { try await $0() })
                    Issue.record("A different locked-note key must be refused")
                } catch let error as VaultIntakeLockedNotesMismatch {
                    #expect(error.count == 1 && error.localizedDescription.contains("1 locked note"))
                    #expect(error.localizedDescription.contains("permanently delete"))
                }
                #expect(try NotePrivacy(store: recipient.noteStore).envelope() == nil)
                try recipient.noteStore.deletePermanently(["locked"])
                #expect(try await intake.install(candidate, fenced: { try await $0() }))
            } else {
                #expect(try await intake.install(candidate, fenced: { try await $0() }))
            }
        }
    }
    @Test func missingVaultReturnsWithoutChangingSyncState() async throws {
        try await withBlobWorld(1) { world in
            let device = world.devices[0], rig = BlobRig(device)
            try await device.db.pool.write { try $0.execute(sql: "UPDATE ck_state SET cloudUserHash=? WHERE id=1", arguments: [world.account.userHash]) }
            let intake = CloudVaultIntake(database: device.db, gateway: rig.gateway, accountID: device.accountID, vaultKey: device.key)
            #expect(try await intake.scan(password: "password") == nil)
            #expect(try device.rowCount("crypto_envelope") == 0 && device.rowCount("ck_inflight") == 0 && device.rowCount("ck_remote") == 0)
            #expect(rig.gateway.log.allSatisfy { !$0.hasPrefix("submit") })
        }
    }
    @Test func intakeFetchesOnlyVaultAndLeavesLibraryAndQueuesUntouched() async throws {
        try await withBlobWorld(2) { world in
            let donor = world.devices[0], recipient = world.devices[1]
            try await recipient.db.pool.write { try $0.execute(sql: "UPDATE ck_state SET cloudUserHash=? WHERE id=1", arguments: [world.account.userHash]) }
            let access = try NotePrivacy(store: donor.noteStore).setPassword("vault password")
            defer { access.revoke() }
            try await donor.publish()
            let note = try recipient.noteStore.create(text: "Local note stays unchanged")
            let rig = BlobRig(recipient)
            let intake = CloudVaultIntake(database: recipient.db, gateway: rig.gateway,
                                          accountID: recipient.accountID, vaultKey: recipient.key)
            let before = try recipient.dirtyCount()
            let candidate = try #require(try await intake.scan(password: "vault password"))
            #expect(try NotePrivacy(store: recipient.noteStore).envelope() == nil)
            await #expect(throws: CancellationError.self) { try await intake.install(candidate, fenced: { _ in throw CancellationError() }) }
            #expect(try NotePrivacy(store: recipient.noteStore).envelope() == nil)
            #expect(try await intake.install(candidate, fenced: { try await $0() }))
            #expect(try NotePrivacy(store: recipient.noteStore).envelope() != nil)
            #expect(try recipient.note(note.id)?.text == note.text)
            #expect(try recipient.dirtyCount() == before)
            #expect(try recipient.rowCount("ck_remote") == 0)
            #expect(try recipient.rowCount("ck_inflight") == 0)
            #expect(rig.gateway.log.allSatisfy { !$0.hasPrefix("submit") })
        }
    }

    @Test func wrongPasswordAndConcurrentLocalEnvelopeNeverInstall() async throws {
        try await withBlobWorld(2) { world in
            let donor = world.devices[0], recipient = world.devices[1]
            try await recipient.db.pool.write { try $0.execute(sql: "UPDATE ck_state SET cloudUserHash=? WHERE id=1", arguments: [world.account.userHash]) }
            let access = try NotePrivacy(store: donor.noteStore).setPassword("vault password")
            defer { access.revoke() }
            try await donor.publish()
            let intake = CloudVaultIntake(database: recipient.db, gateway: recipient.gateway,
                                          accountID: recipient.accountID, vaultKey: recipient.key)
            await #expect(throws: (any Error).self) { try await intake.scan(password: "wrong") }
            let candidate = try #require(try await intake.scan(password: "vault password"))
            let localAccess = try NotePrivacy(store: recipient.noteStore).setPassword("local password")
            defer { localAccess.revoke() }
            await #expect(throws: (any Error).self) { try await intake.install(candidate, fenced: { try await $0() }) }
            let local = try #require(try NotePrivacy(store: recipient.noteStore).envelope())
            _ = try local.unwrap(password: "local password")
        }
    }

    @Test func staleWatermarkAndChangedAccountGenerationRefuseInstall() async throws {
        try await withBlobWorld(2) { world in
            let donor = world.devices[0], recipient = world.devices[1]
            try await recipient.db.pool.write { try $0.execute(sql: "UPDATE ck_state SET cloudUserHash=? WHERE id=1", arguments: [world.account.userHash]) }
            let access = try NotePrivacy(store: donor.noteStore).setPassword("vault password")
            defer { access.revoke() }
            try await donor.publish()
            let intake = CloudVaultIntake(database: recipient.db, gateway: recipient.gateway,
                                          accountID: recipient.accountID, vaultKey: recipient.key)
            let candidate = try #require(try await intake.scan(password: "vault password"))
            let id = CloudPayloadSealer.derivedEntityID(type: .keyBundle, semantic: "lock-vault", vaultKey: recipient.key)
            let record = try #require(await world.account.record(named: CloudRecordCodec.entityRecordName(type: .keyBundle, id: id)))
            guard case .entity(let header) = try CloudRecordCodec.decode(record) else { Issue.record("Expected vault record"); return }
            try await recipient.db.pool.write { db in
                try db.execute(sql: "INSERT INTO ck_record(entityType,entityId,systemFields,ancestor,ver,inc) VALUES('keyBundle',?,X'00',X'00',?,?)",
                               arguments: [id, header.ver + 1, header.inc])
            }
            #expect(try await !intake.install(candidate, fenced: { try await $0() }))
            try await recipient.db.pool.write { db in
                try db.execute(sql: "DELETE FROM ck_record WHERE entityType='keyBundle'")
                try db.execute(sql: "UPDATE ck_state SET generation=generation+1 WHERE id=1")
            }
            await #expect(throws: (any Error).self) { try await intake.install(candidate, fenced: { try await $0() }) }
            #expect(try NotePrivacy(store: recipient.noteStore).envelope() == nil)
        }
    }
}
