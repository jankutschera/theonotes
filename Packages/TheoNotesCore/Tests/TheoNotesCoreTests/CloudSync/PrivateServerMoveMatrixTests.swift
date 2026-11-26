// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// The owner's sequence: a Mac and an iPhone in step through the private server (real Cloudflare engine, fake server),
/// each moves with `PrivateServerMove.run`, then each switches iCloud on (real coordinator, fake iCloud); optionally an iPad that
/// was on iCloud first with notes of its own. Every note must arrive once, nothing identical is sent twice.
final class MovePair: @unchecked Sendable {
    static let password = "move note password"
    let key = SymmetricKey(size: .bits256)
    let mac: SyncMaterializerTests.Library
    let phone: SyncMaterializerTests.Library
    let server = SyncEngineTests.Server()
    let macEngine: SyncEngine
    let phoneEngine: SyncEngine
    let macAccess: LockedNoteAccess
    var phoneAccess: LockedNoteAccess?
    var ids: [String: String] = [:]
    let sketch: Data

    init() async throws {
        mac = try SyncMaterializerTests.Library(key: key, enabled: false)
        phone = try SyncMaterializerTests.Library(key: key, enabled: false)
        // Both apps were new once and made their own Getting Started notes (fixed ids).
        _ = try GettingStartedNotes.seedNewLibrary(in: mac.store, isNewLibrary: true)
        _ = try GettingStartedNotes.seedNewLibrary(in: phone.store, isNewLibrary: true)
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        sketch = try Data(contentsOf: repository.appendingPathComponent("Fixtures/sketch/one-stroke.png"))
        let s = mac.store
        ids["plain"] = try s.create(text: "# Plain\n#work/plans\nYears of notes").id
        ids["pinned"] = try s.create(text: "# Pinned\nkept on top").id
        ids["trashed"] = try s.create(text: "# Trashed\nin the trash").id
        ids["archived"] = try s.create(text: "# Archived\nput away").id
        ids["typed"] = try s.create(text: "# Typed\nan idea").id
        ids["file"] = try s.create(text: "# With a file\n[report](report.txt)").id
        ids["sketch"] = try s.create(text: "# With a sketch\n![](sketch.png)").id
        ids["locked"] = try s.create(text: "# Locked\nsecret body").id
        try s.setPinned([ids["pinned"]!], pinned: true)
        try s.trash([ids["trashed"]!]); try s.archive([ids["archived"]!])
        try s.setType(.idea, noteIds: [ids["typed"]!])
        let files = AttachmentStore(paths: mac.paths, database: mac.db)
        _ = try files.add(data: Data("quarterly report".utf8), filename: "report.txt", to: ids["file"]!)
        _ = try files.add(data: sketch, filename: "sketch.png", to: ids["sketch"]!)
        macAccess = try NotePrivacy(store: s).setPassword(Self.password)
        try macAccess.lock(noteId: ids["locked"]!)

        let blobs = SyncPrivacyTransitionTests.SharedBlobs(libraries: [(mac.db, mac.paths), (phone.db, phone.paths)])
        macEngine = SyncEngine(database: mac.db, paths: mac.paths, accountID: "account", vaultKey: key, transport: server, blobs: blobs)
        phoneEngine = SyncEngine(database: phone.db, paths: phone.paths, accountID: "account", vaultKey: key, transport: server, blobs: blobs)
        try mac.queue.enable(accountID: "account")
        _ = try await macEngine.synchronize(noteAccess: macAccess)
        _ = try await phoneEngine.synchronize()
        let access = try NotePrivacy(store: phone.store).unlock(password: Self.password)
        phoneAccess = access
        _ = try await phoneEngine.synchronize(noteAccess: access)
        try phone.queue.enable(accountID: "account")
        // The iPhone wrote a note of its own and edited one of the Mac's; both went through the server.
        ids["fromPhone"] = try phone.store.create(text: "# From the phone\nwritten on the go").id
        // A starter the owner edited on the Mac long ago.
        let starter = GettingStartedNotes.ids[1]
        let old = try #require(try s.note(id: starter))
        _ = try s.updateText(id: starter, text: old.text + "\nmy own line", expectedRevision: old.revision)
        ids["editedStarter"] = starter
        let plain = try #require(try phone.store.note(id: ids["plain"]!))
        _ = try phone.store.updateText(id: plain.id, text: plain.text + "\nadded on the phone", expectedRevision: plain.revision)
        try await settle()
    }

    func settle() async throws {
        for _ in 0..<3 {
            _ = try await phoneEngine.synchronize(noteAccess: phoneAccess)
            _ = try await macEngine.synchronize(noteAccess: macAccess)
        }
    }

    static func backup(_ library: SyncMaterializerTests.Library) throws -> String {
        let backup = LibraryBackup(database: library.db, paths: library.paths)
        _ = try backup.createRolling()
        return try #require(try backup.localBackups().first).id
    }

    func moveMac(withoutMissingFiles: Bool = false) async throws {
        try await PrivateServerMove.run(database: mac.db, paths: mac.paths, finalSync: { _ = try await self.macEngine.synchronize(noteAccess: self.macAccess) },
                                        makeBackup: { try Self.backup(self.mac) }, withoutMissingFiles: withoutMissingFiles)
    }

    func movePhone() async throws {
        try await PrivateServerMove.run(database: phone.db, paths: phone.paths, finalSync: { _ = try await self.phoneEngine.synchronize(noteAccess: self.phoneAccess) },
                                        makeBackup: { try Self.backup(self.phone) })
    }

    /// The library folder handed to the iCloud side (the Cloudflare side lets go of its database first).
    func icloudDevice(_ library: SyncMaterializerTests.Library, engine: SyncEngine, name: String, world: MoveWorld) async throws -> CoordDevice {
        await engine.shutdown()
        try library.db.pool.close()
        let device = try CoordDevice(name, cloud: world.cloud, keychain: world.keychain, root: library.paths.root)
        device.realBackups = true
        return device
    }

    func cleanup() {
        macAccess.revoke(); phoneAccess?.revoke()
        mac.cleanup(); phone.cleanup()
    }
}

struct MoveWorld {
    let cloud = FakeCloudKitAccount(user: "owner")
    let keychain = InMemoryCloudKeychain()
}

@Suite(.serialized) struct PrivateServerMoveMatrixTests {
    /// What the owner would compare between devices: every note's id, place, pin, lock, text and its attachments' bytes.
    static func library(_ device: CoordDevice) throws -> [String] {
        try device.database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id, location, isPinnedGlobal, isLocked, text FROM note ORDER BY id").map { row in
                let id: String = row["id"]
                let text: String = row["text"]
                let digest = SHA256.hash(data: Data(text.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
                let files = try String.fetchAll(db, sql: "SELECT filename FROM attachment WHERE noteId=? AND deletedAt IS NULL ORDER BY filename", arguments: [id]).map { name in
                    let bytes = (try? Data(contentsOf: device.paths.attachments.appendingPathComponent(id).appendingPathComponent(name))) ?? Data()
                    return name + ":" + SHA256.hash(data: bytes).prefix(6).map { String(format: "%02x", $0) }.joined()
                }
                return "\(id)|\(row["location"] as String)|pin \(row["isPinnedGlobal"] as Bool)|lock \(row["isLocked"] as Bool)|\(digest)|\(files.joined(separator: ","))"
            }
        }
    }

    static func entitySaves(_ device: CoordDevice) -> [String] {
        device.gateway.saves.map(\.record).filter { $0.type != .keyBundle }.map(\.name)
    }

    static func converge(_ devices: [CoordDevice]) async throws {
        for _ in 0..<6 {
            for device in devices {
                // A device without the note password's vault yet (the iPad before the locked notes arrive) syncs without it.
                _ = try await device.coordinator.syncNow(notePassword: try device.count("crypto_envelope") > 0 ? MovePair.password : nil)
            }
        }
    }

    @Test func macThenIPhoneMoveAndEveryNoteCollapsesToOneWithNothingSentTwice() async throws {
        let pair = try await MovePair(); defer { pair.cleanup() }
        let world = MoveWorld()
        let notesBefore = try await pair.mac.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note")! }
        let conflictsBefore = try await pair.mac.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_conflict")! }
        #expect(try await pair.phone.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note")! } == notesBefore)

        try await pair.moveMac()
        let mac = try await pair.icloudDevice(pair.mac, engine: pair.macEngine, name: "mac", world: world)
        defer { mac.cleanup() }
        try await mac.enable(notePassword: MovePair.password)
        try await pair.movePhone()
        let phone = try await pair.icloudDevice(pair.phone, engine: pair.phoneEngine, name: "phone", world: world)
        defer { phone.cleanup() }
        let phoneSavesBefore = Self.entitySaves(phone).count
        try await phone.enable(notePassword: MovePair.password)
        try await Self.converge([mac, phone])

        #expect(try Self.library(mac) == Self.library(phone))
        #expect(try mac.count("note") == notesBefore && phone.count("note") == notesBefore, "no conflict copies, nothing lost")
        #expect(try mac.conflictCopies() == conflictsBefore && phone.conflictCopies() == conflictsBefore)
        #expect(Self.entitySaves(phone).count == phoneSavesBefore, "the iPhone sent nothing the Mac had already uploaded: \(Self.entitySaves(phone))")
        let ids = pair.ids
        #expect(try phone.note(ids["trashed"]!)?.location == .trash && phone.note(ids["archived"]!)?.location == .archive)
        #expect(try phone.note(ids["pinned"]!)?.isPinnedGlobal == true && phone.note(ids["locked"]!)?.isLocked == true)
        #expect(try phone.note(ids["typed"]!)?.text.contains("#idea") == true)
        #expect(try phone.note(ids["plain"]!)?.text.hasSuffix("added on the phone") == true)
        #expect(try mac.note(ids["fromPhone"]!) != nil && mac.note(ids["editedStarter"]!)?.text.hasSuffix("my own line") == true)
        let sketchOnPhone = try Data(contentsOf: phone.paths.attachments.appendingPathComponent(ids["sketch"]!).appendingPathComponent("sketch.png"))
        #expect(sketchOnPhone == pair.sketch)
        for id in GettingStartedNotes.ids { #expect(try mac.note(id) != nil && phone.note(id) != nil, "starter \(id) kept") }
    }

    @Test func anIPadAlreadyOnICloudKeepsItsNotesAndTheMovedLibraryKeepsAllOfItsOwn() async throws {
        let pair = try await MovePair(); defer { pair.cleanup() }
        let world = MoveWorld()
        let ipad = try CoordDevice("ipad", cloud: world.cloud, keychain: world.keychain)
        defer { ipad.cleanup() }
        _ = try GettingStartedNotes.seedNewLibrary(in: ipad.noteStore, isNewLibrary: true)
        let ipadNote = try ipad.noteStore.create(text: "# From the iPad\nApp Store version")
        try await ipad.enable()
        let notesBefore = try await pair.mac.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note")! }

        try await pair.moveMac()
        let mac = try await pair.icloudDevice(pair.mac, engine: pair.macEngine, name: "mac", world: world)
        defer { mac.cleanup() }
        try await mac.enable(notePassword: MovePair.password)
        try await pair.movePhone()
        let phone = try await pair.icloudDevice(pair.phone, engine: pair.phoneEngine, name: "phone", world: world)
        defer { phone.cleanup() }
        try await phone.enable(notePassword: MovePair.password)
        try await Self.converge([ipad, mac, phone])

        #expect(try Self.library(mac) == Self.library(phone))
        #expect(try Self.library(ipad) == Self.library(mac))
        #expect(try mac.count("note") == notesBefore + 1, "the moved notes plus the iPad's own note, starters once")
        #expect(try mac.note(ipadNote.id) != nil && ipad.note(pair.ids["fromPhone"]!) != nil)
        #expect(try ipad.note(pair.ids["editedStarter"]!)?.text.hasSuffix("my own line") == true, "the edited starter wins over the untouched one")
        #expect(try mac.conflictCopies() == 0 && phone.conflictCopies() == 0 && ipad.conflictCopies() == 0)
        for device in [mac, phone] {
            #expect(try device.string("SELECT value FROM setting WHERE key='gettingStartedDroppedBySync'") == nil,
                    "the first-bind guard stands down: a moved library has notes of its own")
        }
    }

    /// The gap handed back to the coordinator: an edit made on the Mac after it moved and before the iPhone moved meets
    /// the iPhone's older, untouched copy with no common base. keeps both: nothing is lost, one linked conflict copy appears.
    @Test func anEditOnTheMacBetweenTheTwoMovesIsKeptAsOneLinkedConflictCopy() async throws {
        let pair = try await MovePair(); defer { pair.cleanup() }
        let world = MoveWorld()
        try await pair.moveMac()
        let mac = try await pair.icloudDevice(pair.mac, engine: pair.macEngine, name: "mac", world: world)
        defer { mac.cleanup() }
        try await mac.enable(notePassword: MovePair.password)
        let id = pair.ids["plain"]!
        try mac.edit(id, try #require(try mac.note(id)).text + "\nedited on the Mac after it moved")
        _ = try await mac.coordinator.syncNow(notePassword: MovePair.password)
        let notesBefore = try mac.count("note")

        try await pair.movePhone()
        let phone = try await pair.icloudDevice(pair.phone, engine: pair.phoneEngine, name: "phone", world: world)
        defer { phone.cleanup() }
        try await phone.enable(notePassword: MovePair.password)
        try await Self.converge([mac, phone])

        #expect(try Self.library(mac) == Self.library(phone))
        let texts = try await phone.database.pool.read { try String.fetchAll($0, sql: "SELECT text FROM note") }
        #expect(texts.contains { $0.hasSuffix("edited on the Mac after it moved") }, "the newer edit survives")
        #expect(try phone.count("note") == notesBefore + 1, "exactly one extra note, no other note doubled")
        #expect(try phone.count("sync_conflict WHERE noteId<>originalNoteId AND originalNoteId='\(id)'") == 1, "the extra note is a linked copy")
        // Today's rule keeps the iPhone's older text at the note and the Mac's newer edit in the copy: the gap names.
        #expect(try phone.note(id)?.text.hasSuffix("added on the phone") == true)
    }

    /// The other side of the iPhone edits after the Mac moved (the edit reaches the server, which the Mac no longer reads).
    /// The newer edit stays at the note; the Mac's older, untouched text becomes one linked copy. Nothing is lost.
    @Test func anEditOnTheIPhoneBetweenTheTwoMovesStaysAtTheNoteAndTheOlderTextBecomesOneCopy() async throws {
        let pair = try await MovePair(); defer { pair.cleanup() }
        let world = MoveWorld()
        try await pair.moveMac()
        let mac = try await pair.icloudDevice(pair.mac, engine: pair.macEngine, name: "mac", world: world)
        defer { mac.cleanup() }
        try await mac.enable(notePassword: MovePair.password)
        let id = pair.ids["pinned"]!
        let note = try #require(try pair.phone.store.note(id: id))
        _ = try pair.phone.store.updateText(id: id, text: note.text + "\nedited on the iPhone after the Mac moved", expectedRevision: note.revision)
        let notesBefore = try mac.count("note")

        try await pair.movePhone()
        let phone = try await pair.icloudDevice(pair.phone, engine: pair.phoneEngine, name: "phone", world: world)
        defer { phone.cleanup() }
        try await phone.enable(notePassword: MovePair.password)
        try await Self.converge([mac, phone])

        #expect(try Self.library(mac) == Self.library(phone))
        #expect(try mac.note(id)?.text.hasSuffix("edited on the iPhone after the Mac moved") == true)
        #expect(try mac.count("note") == notesBefore + 1)
        #expect(try mac.count("sync_conflict WHERE noteId<>originalNoteId AND originalNoteId='\(id)'") == 1)
    }

    // MARK: known limits: a deletion or a move to the Trash between the two moves does not stand

    static func macMovedThenPhone(_ between: (CoordDevice, MovePair) async throws -> Void) async throws -> (MovePair, CoordDevice, CoordDevice) {
        let pair = try await MovePair()
        let world = MoveWorld()
        try await pair.moveMac()
        let mac = try await pair.icloudDevice(pair.mac, engine: pair.macEngine, name: "mac", world: world)
        try await mac.enable(notePassword: MovePair.password)
        try await between(mac, pair)
        _ = try await mac.coordinator.syncNow(notePassword: MovePair.password)
        try await pair.movePhone()
        let phone = try await pair.icloudDevice(pair.phone, engine: pair.phoneEngine, name: "phone", world: world)
        try await phone.enable(notePassword: MovePair.password)
        try await converge([mac, phone])
        return (pair, mac, phone)
    }

    /// KNOWN LIMIT, pinned on purpose: the iPhone's copy has no base, so the Mac's deletion is undone everywhere. The
    /// confirmation and the lasting notice ask the owner not to delete until every device has moved. Change this test only with.
    @Test func knownLimitADeletionOnTheMacBetweenTheMovesComesBackOnEveryDevice() async throws {
        var id = ""
        let (pair, mac, phone) = try await Self.macMovedThenPhone { mac, pair in
            id = pair.ids["archived"]!
            try mac.hardDelete(id)
        }
        defer { mac.cleanup(); phone.cleanup(); pair.cleanup() }
        for device in [mac, phone] {
            #expect(try device.note(id)?.location == .archive, "\(device.name): the deleted note is back")
        }
        #expect(try Self.library(mac) == Self.library(phone))
    }

    /// KNOWN LIMIT, pinned on purpose: the Mac's move to the Trash meets the iPhone's untouched copy with no base; the note is back
    /// in Notes and one linked copy sits in the Trash, on every device.
    @Test func knownLimitAMoveToTheTrashOnTheMacBetweenTheMovesComesBackWithOneLinkedCopy() async throws {
        var id = ""
        let (pair, mac, phone) = try await Self.macMovedThenPhone { mac, pair in
            id = pair.ids["typed"]!
            try mac.trash(id)
        }
        defer { mac.cleanup(); phone.cleanup(); pair.cleanup() }
        for device in [mac, phone] {
            #expect(try device.note(id)?.location == .notes, "\(device.name): the note is back in Notes")
            let target = id
            let copies = try await device.database.pool.read {
                try String.fetchAll($0, sql: "SELECT n.location FROM sync_conflict c JOIN note n ON n.id=c.noteId WHERE c.originalNoteId=? AND c.noteId<>c.originalNoteId", arguments: [target])
            }
            #expect(copies == ["trash"], "\(device.name): one linked copy, in the Trash")
        }
        #expect(try Self.library(mac) == Self.library(phone))
    }

    // MARK: Move Without These Files on the first device

    /// The owner's case: notes whose image files never reached the Mac (one in Notes, one in the Trash). The Mac moves without them,
    /// the iPhone (which holds the same notes with the same placeholder rows, sent through the server) moves normally, and an iPad
    /// already on iCloud joins. Nothing blocks, nothing doubles, every device shows the same notes with the missing image.
    @Test func theMacMovesWithoutFilesNoDeviceEverHadAndEveryDeviceEndsTheSame() async throws {
        let pair = try await MovePair(); defer { pair.cleanup() }
        let inNotes = try pair.mac.store.create(text: "# Imported cover\n![](cover-001.jpg)\nbody")
        let inTrash = try pair.mac.store.create(text: "# Imported image\n![](image-002.jpg)\nbody")
        try pair.mac.store.trash([inTrash.id])
        try await pair.settle()
        let missing = try await pair.mac.db.pool.read { try SyncQueue.unavailableAttachments(paths: pair.mac.paths, in: $0) }
        #expect(missing.count == 2)
        #expect(try await pair.phone.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM attachment WHERE noteId IN (?,?)", arguments: [inNotes.id, inTrash.id]) } == 2,
                "the iPhone holds the same placeholder rows (from the notes it received), with no file and nothing to send")
        let world = MoveWorld()
        let ipad = try CoordDevice("ipad", cloud: world.cloud, keychain: world.keychain); defer { ipad.cleanup() }
        _ = try ipad.noteStore.create(text: "# From the iPad")
        try await ipad.enable()
        let notesBefore = try await pair.mac.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note")! }

        await #expect(throws: PrivateServerMoveRefusal.self) { try await pair.moveMac() }
        try await pair.moveMac(withoutMissingFiles: true)
        let mac = try await pair.icloudDevice(pair.mac, engine: pair.macEngine, name: "mac", world: world)
        defer { mac.cleanup() }
        #expect(try await mac.enable(notePassword: MovePair.password) != .syncing, "the missing files do not hold the first sync")
        try await pair.movePhone()
        let phone = try await pair.icloudDevice(pair.phone, engine: pair.phoneEngine, name: "phone", world: world)
        defer { phone.cleanup() }
        try await phone.enable(notePassword: MovePair.password)
        try await Self.converge([ipad, mac, phone])

        #expect(try Self.library(mac) == Self.library(phone))
        #expect(try Self.library(ipad) == Self.library(mac))
        #expect(try mac.count("note") == notesBefore + 1 && mac.conflictCopies() == 0)
        for device in [ipad, mac, phone] {
            #expect(try device.note(inNotes.id)?.text.contains("![](cover-001.jpg)") == true && device.note(inNotes.id)?.location == .notes, "\(device.name)")
            #expect(try device.note(inTrash.id)?.location == .trash, "\(device.name)")
            #expect(try device.count("ck_remote") == 0, "\(device.name): nothing waits for the missing file")
        }
        #expect(try mac.count("sync_dirty WHERE entityType='attachment'") == 2, "the Mac keeps the two rows as unsent local rows")
    }

    // MARK: the trial on a writable COPY of a real library

    /// A private-server stand-in for the trial: it has nothing new, accepts what is sent and acknowledges any cursor.
    actor TrialServer: SyncTransport {
        var pushed = 0
        func push(_ mutations: [SyncMutation]) async throws -> SyncPushResult {
            pushed += mutations.count
            return .init(results: mutations.map { .init(mutationId: $0.mutationId, status: .accepted,
                entity: SyncEntity(mutation: $0, revision: $0.parentRevision + 1, sequence: 1, receivedAt: 1), current: nil) })
        }
        func pull(after cursor: Int64) async throws -> SyncPullResult { .init(changes: [], cursor: cursor, hasMore: false) }
        func acknowledge(_ cursor: Int64) async throws {}
    }

    static func counts(_ db: AppDatabase) throws -> [String] {
        try db.pool.read { db in
            try ["SELECT 'notes ' || COUNT(*) FROM note WHERE location='notes'", "SELECT 'trash ' || COUNT(*) FROM note WHERE location='trash'",
                 "SELECT 'archive ' || COUNT(*) FROM note WHERE location='archive'", "SELECT 'attachments ' || COUNT(*) FROM attachment",
                 "SELECT 'tags ' || COUNT(*) FROM tag", "SELECT 'pinned ' || COUNT(*) FROM note WHERE isPinnedGlobal=1",
                 "SELECT 'locked ' || COUNT(*) FROM note WHERE isLocked=1"].compactMap { try String.fetchOne(db, sql: $0) }
        }
    }

    /// `THEONOTES_MOVE_TRIAL="<writable copy folder>" swift test --package-path Packages/TheoNotesCore --filter trialMoveOfALibraryCopy`
    /// Runs the whole Core move on the copy (a stand-in server for the final sync, a real backup, "Move Without These Files" when
    /// offered), then the iCloud first sync of the copy and of a second, fresh device on the fake iCloud. Prints counts only. The
    /// real library folder is refused. The copy is changed: make it for this run and delete it afterwards.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["THEONOTES_MOVE_TRIAL"] != nil))
    func trialMoveOfALibraryCopy() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["THEONOTES_MOVE_TRIAL"]!)
        guard !AppPaths.isRealLibrary(root) else { Issue.record("This is the real library. Copy it first."); return }
        let paths = AppPaths(root: root)
        var db: AppDatabase? = try AppDatabase(path: paths.database)
        let before = try Self.counts(db!)
        print("MOVE-TRIAL before:", before.joined(separator: ", "))
        let account = try #require(try await db!.pool.read { try String.fetchOne($0, sql: "SELECT accountId FROM sync_control") })
        let server = TrialServer()
        let engine = SyncEngine(database: db!, paths: paths, accountID: account, vaultKey: SymmetricKey(size: .bits256),
                                transport: server, blobs: SyncPayloadReaderTests.Blobs())
        let refusals = try PrivateServerMove.refusals(in: db!, paths: paths)
        print("MOVE-TRIAL refusals before:", refusals.map { String(describing: $0) }.joined(separator: " | "))
        let offered: Bool = { if case .unavailableAttachments(_, _, true)? = refusals.first { true } else { false } }()
        let library = db!
        try await PrivateServerMove.run(database: library, paths: paths, finalSync: { _ = try await engine.synchronize() }, makeBackup: {
            let backup = LibraryBackup(database: library, paths: paths)
            return try #require(try backup.catalogID(of: try backup.createRolling()))
        }, withoutMissingFiles: offered)
        await engine.shutdown()
        print("MOVE-TRIAL moved: backend", try CloudSyncStore(database: library).backend(), "pushed to the stand-in", await server.pushed,
              "moved mark", try PrivateServerMove.hasLeft(library), "after:", try Self.counts(library).joined(separator: ", "))
        #expect(try Self.counts(library) == before)
        try db!.pool.close(); db = nil

        let world = MoveWorld()
        let mac = try CoordDevice("trial-mac", cloud: world.cloud, keychain: world.keychain, root: root)
        mac.realBackups = true
        let first = try await mac.enable()
        let fresh = try CoordDevice("trial-fresh", cloud: world.cloud, keychain: world.keychain)
        defer { fresh.cleanup(); try? mac.database.pool.close() }
        try await fresh.enable()
        for _ in 0..<4 { for device in [mac, fresh] { _ = try await device.coordinator.syncNow() } }
        print("MOVE-TRIAL iCloud first sync:", first, "copy after:", try Self.counts(mac.database).joined(separator: ", "),
              "| fresh device:", try Self.counts(fresh.database).joined(separator: ", "),
              "| copies", try mac.conflictCopies(), "| waiting", try mac.count("ck_remote"), try fresh.count("ck_remote"),
              "| unsent attachment rows on the copy", try mac.count("sync_dirty WHERE entityType='attachment'"))
        #expect(try Self.counts(mac.database) == before)
    }
}
