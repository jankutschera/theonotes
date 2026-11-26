// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// The share inbox (C4,...): the app drains what share extensions
/// leave in the App Group, and treats every item as hostile input.
@Suite struct CaptureInboxTests {
    let library: PrivacyTestLibrary
    let attachments: AttachmentStore
    let inboxDir: URL
    let inbox: CaptureInbox
    let source: URL

    private struct Crash: Error {}
    private static func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + seconds) }

    init() throws {
        library = try PrivacyTestLibrary()
        attachments = AttachmentStore(paths: library.paths, database: library.db)
        let root = library.paths.root.appendingPathComponent("group", isDirectory: true)
        inboxDir = root.appendingPathComponent("CaptureInbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)
        inbox = CaptureInbox(directory: inboxDir)
        source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    }

    private func file(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let url = source.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    private func request(
        _ id: String = UUIDv7.make(), mode: CaptureRequest.Mode = .save, target: String? = nil,
        text: String = "", files: [String] = []
    ) -> CaptureRequest {
        CaptureRequest(itemId: id, mode: mode, targetNoteId: target, text: text, files: files)
    }

    /// Writes an item by hand, the way a hostile or broken extension might.
    private func plant(_ id: String, json: String, files: [String: [UInt8]] = [:]) throws {
        let dir = inboxDir.appendingPathComponent("\(id).capture", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: dir.appendingPathComponent("request.json"))
        for (name, bytes) in files { try Data(bytes).write(to: dir.appendingPathComponent(name)) }
    }

    private func items() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: inboxDir.path)) ?? []).sorted()
    }

    private func rejected() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: inboxDir.appendingPathComponent("rejected").path)) ?? []).sorted()
    }

    private func noteCount() throws -> Int {
        try library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note")! }
    }

    private func attachmentNames(_ noteId: String) -> [String] {
        let dir = library.paths.attachments.appendingPathComponent(noteId)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    private func receipt(_ itemId: String) throws -> (noteId: String?, processedAt: Date)? {
        try library.db.pool.read { db in
            try Row.fetchOne(db, sql: "SELECT noteId, processedAt FROM capture_receipt WHERE itemId = ?", arguments: [itemId])
                .map { ($0["noteId"], $0["processedAt"]) }
        }
    }

    // MARK: - Save

    @Test func saveCreatesOneNoteWithThePayloadText() throws {
        defer { library.cleanup() }
        let req = request(text: "Buy oat milk\nand tea")
        try inbox.enqueue(req, files: [])
        let done = try inbox.drain(into: library.store, attachments: attachments, now: Self.at(0))
        #expect(done == [req.itemId])
        let note = try #require(try library.store.note(id: req.itemId))
        #expect(note.text == "Buy oat milk\nand tea")
        #expect(note.title == "Buy oat milk")
        #expect(note.location == .notes)
        #expect(try library.store.captureSource(noteId: req.itemId) == .share)
        #expect(try noteCount() == 1)
        #expect(items().filter { $0.hasSuffix(".capture") }.isEmpty)
        #expect(rejected().isEmpty)
    }

    @Test func saveWithAFileAttachesIt() throws {
        defer { library.cleanup() }
        let req = request(text: "See this", files: ["photo.png", "notes.txt"])
        try inbox.enqueue(req, files: [file("photo.png", [1, 2, 3]), file("notes.txt", [4, 5])])
        _ = try inbox.drain(into: library.store, attachments: attachments, now: Self.at(0))
        let note = try #require(try library.store.note(id: req.itemId))
        #expect(attachmentNames(req.itemId) == ["notes.txt", "photo.png"])
        let photo = try #require(attachments.url(for: "photo.png", noteId: req.itemId))
        #expect(try Data(contentsOf: photo) == Data([1, 2, 3]))
        #expect(note.text.hasPrefix("See this"))
        #expect(note.text.contains(AttachmentMarkdown.link(for: "photo.png")))
        #expect(note.text.contains(AttachmentMarkdown.link(for: "notes.txt")))
    }

    @Test func savedFilesGetCleanedUniqueNamesThatTheLinksUse() throws {
        defer { library.cleanup() }
        let id = UUIDv7.make()
        // Two different files whose names clean up to the same name, plus a repeated listing.
        try plant(
            id, json: "{\"version\":1,\"itemId\":\"\(id)\",\"mode\":\"save\",\"text\":\"t\",\"files\":[\"a:b.png\",\"a-b.png\",\"a-b.png\"]}",
            files: ["a:b.png": [1], "a-b.png": [2]])
        _ = try inbox.drain(into: library.store, attachments: attachments, now: Self.at(0))
        #expect(attachmentNames(id) == ["a-b 2.png", "a-b 3.png", "a-b.png"])
        let note = try #require(try library.store.note(id: id))
        for name in ["a-b.png", "a-b 2.png", "a-b 3.png"] { #expect(note.text.contains(AttachmentMarkdown.link(for: name))) }
        #expect(try Data(contentsOf: #require(attachments.url(for: "a-b.png", noteId: id))) == Data([1]))
    }

    @Test func drainTwiceNeverDuplicates() throws {
        defer { library.cleanup() }
        let req = request(text: "Once only", files: ["a.png"])
        try inbox.enqueue(req, files: [file("a.png", [9, 9])])
        // Crash right after the store write: the note exists, the file is not placed yet.
        #expect(throws: Crash.self) {
            _ = try inbox.drain(into: library.store, attachments: attachments, now: Self.at(0)) { _ in throw Crash() }
        }
        #expect(try noteCount() == 1)
        #expect(attachmentNames(req.itemId).isEmpty)
        #expect(items().contains("\(req.itemId).capture"))

        let first = try inbox.drain(into: library.store, attachments: attachments, now: Self.at(10))
        #expect(first == [req.itemId])
        #expect(try noteCount() == 1)
        #expect(attachmentNames(req.itemId) == ["a.png"])
        let text = try #require(try library.store.note(id: req.itemId)).text

        // The same item shows up again (the extension re-delivered it): nothing changes.
        try inbox.enqueue(req, files: [file("a.png", [9, 9])])
        _ = try inbox.drain(into: library.store, attachments: attachments, now: Self.at(20))
        #expect(try noteCount() == 1)
        #expect(attachmentNames(req.itemId) == ["a.png"])
        #expect(try library.store.note(id: req.itemId)?.text == text)
        #expect(items().filter { $0.hasSuffix(".capture") }.isEmpty)
    }

    @Test func vanishedFileAfterValidationIsQuarantined() throws {
        defer { library.cleanup() }
        let req = request(text: "Keep the request", files: ["a.png"])
        try inbox.enqueue(req, files: [file("a.png", [9])])
        let item = inboxDir.appendingPathComponent("\(req.itemId).capture")
        let done = try inbox.drain(into: library.store, attachments: attachments, now: Self.at(0)) { _ in
            try FileManager.default.removeItem(at: item.appendingPathComponent("a.png"))
        }
        #expect(done.isEmpty)
        #expect(!items().contains("\(req.itemId).capture"))
        #expect(rejected().contains("\(req.itemId).capture"))
        #expect(try library.store.note(id: req.itemId)?.text.contains("Keep the request") == true)
    }

    @Test func temporarilyUnreadableFileAfterValidationRemainsForRetry() throws {
        defer { library.cleanup() }
        let req = request(text: "Keep the attachment", files: ["a.png"])
        try inbox.enqueue(req, files: [file("a.png", [9])])
        let item = inboxDir.appendingPathComponent("\(req.itemId).capture")
        let capturedFile = item.appendingPathComponent("a.png")
        let first = try inbox.drain(into: library.store, attachments: attachments, now: Self.at(0)) { _ in
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: capturedFile.path)
        }
        #expect(first.isEmpty)
        #expect(items().contains("\(req.itemId).capture"))
        #expect(rejected().isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: capturedFile.path)
        #expect(try inbox.drain(into: library.store, attachments: attachments, now: Self.at(1)) == [req.itemId])
        #expect(try Data(contentsOf: #require(attachments.url(for: "a.png", noteId: req.itemId))) == Data([9]))
    }

    @Test func temporarilyUnreadableRequestRemainsForRetry() throws {
        defer { library.cleanup() }
        let req = request(text: "Keep the request")
        try inbox.enqueue(req, files: [])
        let json = inboxDir.appendingPathComponent("\(req.itemId).capture/request.json")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: json.path)
        #expect(try inbox.drain(into: library.store, attachments: attachments, now: Self.at(0)).isEmpty)
        #expect(items().contains("\(req.itemId).capture"))
        #expect(rejected().isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: json.path)
        #expect(try inbox.drain(into: library.store, attachments: attachments, now: Self.at(1)) == [req.itemId])
    }

    // MARK: - Append

    @Test func appendAddsTextOnceAndRecordsAReceipt() throws {
        defer { library.cleanup() }
        let target = try library.store.create(text: "# Groceries\nmilk", now: Self.at(0))
        let req = request(mode: .append, target: target.id, text: "bread")
        try inbox.enqueue(req, files: [])
        let done = try inbox.drain(into: library.store, attachments: attachments, now: Self.at(100))
        #expect(done == [target.id])
        let after = try #require(try library.store.note(id: target.id))
        #expect(after.text == "# Groceries\nmilk\n\nbread")
        #expect(after.revision == target.revision + 1)
        let row = try #require(try receipt(req.itemId))
        #expect(row.noteId == target.id)
        #expect(row.processedAt == Self.at(100))

        // Delivered again: the receipt says it is done, so the text is not appended twice.
        try inbox.enqueue(req, files: [])
        _ = try inbox.drain(into: library.store, attachments: attachments, now: Self.at(200))
        #expect(try library.store.note(id: target.id)?.text == "# Groceries\nmilk\n\nbread")
        #expect(try noteCount() == 1)
    }

    @Test func appendWithAFileKeepsExistingAttachmentsAndLinksTheNewOne() throws {
        defer { library.cleanup() }
        let target = try library.store.create(text: "# Pics")
        _ = try attachments.add(data: Data([1]), filename: "photo.png", to: target.id)
        let req = request(mode: .append, target: target.id, text: "", files: ["photo.png"])
        try inbox.enqueue(req, files: [file("photo.png", [2])])
        _ = try inbox.drain(into: library.store, attachments: attachments, now: Self.at(0))
        #expect(attachmentNames(target.id) == ["photo 2.png", "photo.png"])
        let text = try #require(try library.store.note(id: target.id)).text
        #expect(text == "# Pics\n\n" + AttachmentMarkdown.link(for: "photo 2.png"))
    }

    @Test func appendToAMissingOrLockedNoteSavesANewNoteInstead() throws {
        defer { library.cleanup() }
        let access = try library.access()
        let locked = try library.store.create(text: "# Secret\nkeep")
        try access.lock(noteId: locked.id)
        let lockedBefore = try #require(try library.store.note(id: locked.id))
        let trashed = try library.store.create(text: "# Gone")
        try library.store.trash([trashed.id])
        let frozen = try library.store.create(text: "# Frozen")
        try library.store.setReadOnly(frozen.id, readOnly: true)
        let frozenBefore = try #require(try library.store.note(id: frozen.id))

        var ids: [String] = []
        let missing = UUIDv7.make()
        for (n, target) in [missing, locked.id, trashed.id, frozen.id].enumerated() {
            let withFile = n == 0
            let req = request(mode: .append, target: target, text: "payload \(n)", files: withFile ? ["a.png"] : [])
            try inbox.enqueue(req, files: withFile ? [file("a.png", [1])] : [])
            ids.append(req.itemId)
        }
        let done = try inbox.drain(into: library.store, attachments: attachments, now: Self.at(0))
        #expect(Set(done) == Set(ids))
        // The file followed the payload into the new note, not into the note that was asked for.
        #expect(attachmentNames(ids[0]) == ["a.png"])
        #expect(attachmentNames(missing).isEmpty)
        for (n, id) in ids.enumerated() {
            let note = try #require(try library.store.note(id: id))
            #expect(note.text == (n == 0 ? "payload 0\n\n" + AttachmentMarkdown.link(for: "a.png") : "payload \(n)"))
            #expect(note.location == .notes)
            #expect(try library.store.captureSource(noteId: id) == .share)
        }
        // The locked, trashed and read-only notes were not touched.
        #expect(try library.store.note(id: locked.id) == lockedBefore)
        #expect(try library.store.note(id: frozen.id) == frozenBefore)
        #expect(try library.store.note(id: trashed.id)?.text == "# Gone")
    }

    // MARK: - Hostile input

    @Test func halfWrittenTmpIsIgnoredThenSwept() throws {
        defer { library.cleanup() }
        let id = UUIDv7.make()
        let tmp = inboxDir.appendingPathComponent("\(id).tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data("{\"version\":1,\"itemId\":\"".utf8).write(to: tmp.appendingPathComponent("request.json"))
        let written = Self.at(0)
        try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: tmp.path)

        let early = try inbox.drain(into: library.store, attachments: attachments, now: written.addingTimeInterval(60))
        #expect(early.isEmpty)
        #expect(try noteCount() == 0)
        #expect(items() == ["\(id).tmp"])

        let late = try inbox.drain(into: library.store, attachments: attachments, now: written.addingTimeInterval(2 * 3600))
        #expect(late.isEmpty)
        #expect(try noteCount() == 0)
        #expect(items().isEmpty)
        #expect(rejected().isEmpty)
    }

    @Test(arguments: [
        "badVersion", "slashName", "dotDotName", "missingFile", "badTarget", "badItemId", "idMismatch",
        "garbage", "symlinkFile", "oversizedText", "tooManyFiles", "appendWithoutTarget", "requestJsonAsFile",
    ])
    func hostileRequestIsRejectedWithoutWriting(_ kind: String) throws {
        defer { library.cleanup() }
        // A well-formed folder name that is not an id: only the id rule can reject it.
        let id = kind == "badItemId" ? "evil-id" : UUIDv7.make()
        func json(version: Int = 1, itemId: String? = nil, mode: String = "save", target: String? = nil,
                  text: String = "x", files: [String] = []) -> String {
            let names = files.map { "\"\($0)\"" }.joined(separator: ",")
            let targetJSON = target.map { ",\"targetNoteId\":\"\($0)\"" } ?? ""
            return "{\"version\":\(version),\"itemId\":\"\(itemId ?? id)\",\"mode\":\"\(mode)\"\(targetJSON),\"text\":\"\(text)\",\"files\":[\(names)]}"
        }
        switch kind {
        case "badVersion": try plant(id, json: json(version: 2))
        case "slashName":
            // The file exists outside the item folder: only the name rule keeps it out.
            try Data([1]).write(to: inboxDir.appendingPathComponent("escape.txt"))
            try plant(id, json: json(files: ["../escape.txt"]))
        case "dotDotName": try plant(id, json: json(files: [".."]))
        case "missingFile": try plant(id, json: json(files: ["gone.png"]))
        case "badTarget": try plant(id, json: json(mode: "append", target: "../../etc/passwd"))
        case "badItemId": try plant(id, json: json())
        case "idMismatch": try plant(id, json: json(itemId: UUIDv7.make(now: Self.at(5))))
        case "garbage": try plant(id, json: "not json at all")
        case "symlinkFile":
            try plant(id, json: json(files: ["link.png"]))
            let secret = try file("secret.txt", [7])
            try FileManager.default.createSymbolicLink(
                at: inboxDir.appendingPathComponent("\(id).capture/link.png"), withDestinationURL: secret)
        case "oversizedText": try plant(id, json: json(text: String(repeating: "a", count: CaptureInbox.maxTextBytes + 1)))
        case "tooManyFiles":
            let names = (0...CaptureInbox.maxFiles).map { "f\($0).txt" }
            try plant(id, json: json(files: names), files: Dictionary(uniqueKeysWithValues: names.map { ($0, [UInt8(1)]) }))
        case "appendWithoutTarget": try plant(id, json: json(mode: "append"))
        case "requestJsonAsFile": try plant(id, json: json(files: ["request.json"]))
        default: Issue.record("unknown case")
        }
        let done = try inbox.drain(into: library.store, attachments: attachments, now: Self.at(0))
        #expect(done.isEmpty)
        #expect(try noteCount() == 0)
        #expect(try receipt(id) == nil)
        #expect(items().filter { $0.hasSuffix(".capture") }.isEmpty)
        #expect(rejected().contains { $0.hasPrefix(id) })
        #expect(!FileManager.default.fileExists(atPath: library.paths.attachments.appendingPathComponent(id).path))
        #expect(attachmentNames(id).isEmpty)
    }

    @Test func aSymlinkedItemDirectoryIsRejectedNotFollowed() throws {
        defer { library.cleanup() }
        let id = UUIDv7.make()
        let outside = library.paths.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let json = "{\"version\":1,\"itemId\":\"\(id)\",\"mode\":\"save\",\"text\":\"leak\",\"files\":[]}"
        try Data(json.utf8).write(to: outside.appendingPathComponent("request.json"))
        try FileManager.default.createSymbolicLink(
            at: inboxDir.appendingPathComponent("\(id).capture"), withDestinationURL: outside)
        let done = try inbox.drain(into: library.store, attachments: attachments, now: Self.at(0))
        #expect(done.isEmpty)
        #expect(try noteCount() == 0)
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("request.json").path))
        #expect(rejected().contains { $0.hasPrefix(id) })
    }

    @Test func oneRejectedItemDoesNotBlockTheNext() throws {
        defer { library.cleanup() }
        let bad = UUIDv7.make(now: Self.at(0))
        try plant(bad, json: "nope")
        let good = request(UUIDv7.make(now: Self.at(1)), text: "fine")
        try inbox.enqueue(good, files: [])
        let done = try inbox.drain(into: library.store, attachments: attachments, now: Self.at(5))
        #expect(done == [good.itemId])
        #expect(try noteCount() == 1)
        #expect(rejected().count == 1)
    }

    // MARK: - Held appends

    @Test func anAppendForAHeldNoteStaysInTheInboxUntilItIsReleased() throws {
        defer { library.cleanup() }
        let held = try library.store.create(text: "Held")
        let free = try library.store.create(text: "Free")
        let toHeld = request(UUIDv7.make(now: Self.at(0)), mode: .append, target: held.id, text: "for held")
        let toFree = request(UUIDv7.make(now: Self.at(1)), mode: .append, target: free.id, text: "for free")
        let saved = request(UUIDv7.make(now: Self.at(2)), text: "new note")
        for item in [toHeld, toFree, saved] { try inbox.enqueue(item, files: []) }

        let first = try inbox.drain(into: library.store, attachments: attachments, now: Self.at(5), holdingAppendsTo: [held.id])
        #expect(first == [free.id, saved.itemId])
        #expect(try library.store.note(id: held.id)?.text == "Held", "nothing was appended or saved instead")
        #expect(try noteCount() == 3)
        #expect(items().filter { $0.hasSuffix(".capture") } == ["\(toHeld.itemId).capture"])
        #expect(try receipt(toHeld.itemId) == nil)

        let second = try inbox.drain(into: library.store, attachments: attachments, now: Self.at(6))
        #expect(second == [held.id])
        #expect(try library.store.note(id: held.id)?.text == "Held\n\nfor held")
    }

    // MARK: - Rejected items do not pile up

    @Test func aRejectedItemIsKeptForSevenDaysThenDeleted() throws {
        defer { library.cleanup() }
        let day = 86400.0
        let id = UUIDv7.make(now: Self.at(0))
        try plant(id, json: "nope")
        _ = try inbox.drain(into: library.store, attachments: attachments, now: Self.at(10 * day))
        #expect(rejected().count == 1, "moved aside when it was rejected")

        _ = try inbox.drain(into: library.store, attachments: attachments, now: Self.at(16 * day))
        #expect(rejected().count == 1, "six days after the rejection, not the item's own age")

        _ = try inbox.drain(into: library.store, attachments: attachments, now: Self.at(18 * day))
        #expect(rejected().isEmpty, "more than seven days after the rejection")
    }

    @Test func theRejectedFolderKeepsTheNewestTwentyItems() throws {
        defer { library.cleanup() }
        var ids: [String] = []
        for index in 0..<25 {
            let id = UUIDv7.make(now: Self.at(Double(index)))
            ids.append(id)
            try plant(id, json: "nope")
            _ = try inbox.drain(into: library.store, attachments: attachments, now: Self.at(100 + Double(index)))
        }
        let left = rejected()
        #expect(left.count == 20)
        #expect(ids.suffix(20).allSatisfy { id in left.contains { $0.hasPrefix(id) } }, "the newest ones stay")
        #expect(ids.prefix(5).allSatisfy { id in !left.contains { $0.hasPrefix(id) } }, "the oldest go first")
    }

    @Test func aRejectedItemDatedInTheFutureStillExpires() throws {
        defer { library.cleanup() }
        let rejectedDir = inboxDir.appendingPathComponent("rejected", isDirectory: true)
        try FileManager.default.createDirectory(at: rejectedDir, withIntermediateDirectories: true)
        let odd = rejectedDir.appendingPathComponent("odd")
        try Data([1]).write(to: odd)
        try FileManager.default.setAttributes([.modificationDate: Self.at(400 * 86400)], ofItemAtPath: odd.path)
        _ = try inbox.drain(into: library.store, attachments: attachments, now: Self.at(0))
        #expect(rejected().isEmpty)
    }

    @Test func pruningNeverFollowsASymlinkOutOfTheRejectedFolder() throws {
        defer { library.cleanup() }
        let outside = library.paths.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let keep = outside.appendingPathComponent("keep.txt")
        try Data([1]).write(to: keep)
        let id = UUIDv7.make(now: Self.at(0))
        try FileManager.default.createSymbolicLink(at: inboxDir.appendingPathComponent("\(id).capture"), withDestinationURL: outside)
        _ = try inbox.drain(into: library.store, attachments: attachments, now: Self.at(0))
        #expect(rejected().count == 1)
        _ = try inbox.drain(into: library.store, attachments: attachments, now: Self.at(30 * 86400))
        #expect(rejected().isEmpty)
        #expect(FileManager.default.fileExists(atPath: keep.path), "only the link was removed")
    }

    @Test func oldReceiptsAreDeletedDuringDrain() throws {
        defer { library.cleanup() }
        try library.db.pool.write { db in
            try db.execute(sql: "INSERT INTO capture_receipt(itemId, noteId, processedAt) VALUES('old', 'n', ?), ('fresh', 'n', ?)",
                           arguments: [Self.at(0), Self.at(40 * 86400)])
        }
        _ = try inbox.drain(into: library.store, attachments: attachments, now: Self.at(40 * 86400 + 60))
        #expect(try receipt("old") == nil)
        #expect(try receipt("fresh") != nil)
    }

    // MARK: - Recent notes file

    @Test func recentNotesFileIsNilWhenAppLockIsEnabledAndSkipsLockedNotes() throws {
        defer { library.cleanup() }
        let access = try library.access()
        let a = try library.store.create(text: "# Alpha", now: Self.at(1))
        let secret = try library.store.create(text: "# Secret", now: Self.at(2))
        try access.lock(noteId: secret.id)
        let trashed = try library.store.create(text: "# Trashed", now: Self.at(3))
        try library.store.trash([trashed.id])
        let frozen = try library.store.create(text: "# Frozen", now: Self.at(4))
        try library.store.setReadOnly(frozen.id, readOnly: true)
        let untitled = try library.store.create(text: "", now: Self.at(5))
        let b = try library.store.create(text: "# Beta", now: Self.at(6))

        #expect(try RecentNotesFile.make(store: library.store, appLockEnabled: true) == nil)
        let file = try #require(try RecentNotesFile.make(store: library.store, appLockEnabled: false))
        #expect(file.notes.map(\.id) == [b.id, untitled.id, a.id])
        #expect(file.notes.map(\.title) == ["Beta", "Untitled", "Alpha"])
        #expect(!String(decoding: try JSONEncoder().encode(file), as: UTF8.self).contains("Secret"))
    }

    @Test func recentNotesFileHoldsAtMostTwentyNotes() throws {
        defer { library.cleanup() }
        for n in 0..<25 { _ = try library.store.create(text: "# Note \(n)", now: Self.at(Double(n))) }
        let file = try #require(try RecentNotesFile.make(store: library.store, appLockEnabled: false))
        #expect(file.notes.count == 20)
        #expect(file.notes.first?.title == "Note 24")
    }

    // MARK: - Shared container files

    @Test func publishNilDeletesAStaleFile() throws {
        defer { library.cleanup() }
        let container = library.paths.root.appendingPathComponent("container", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let target = container.appendingPathComponent(RecentNotesFile.fileName)
        let file = RecentNotesFile(notes: [.init(id: "x", title: "One")])

        try SharedContainerFiles.publish(file, in: container)
        #expect(try JSONDecoder().decode(RecentNotesFile.self, from: Data(contentsOf: target)) == file)
        #expect(try FileManager.default.contentsOfDirectory(atPath: container.path) == [RecentNotesFile.fileName])

        try SharedContainerFiles.publish(nil, in: container)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        // Nothing to delete is not an error.
        try SharedContainerFiles.publish(nil, in: container)
    }

    @Test func validateFailsForAnUnwritableContainer() throws {
        defer { library.cleanup() }
        let container = library.paths.root.appendingPathComponent("probe", isDirectory: true)
        #expect(!SharedContainerFiles.validate(container: container))
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        #expect(SharedContainerFiles.validate(container: container))
        #expect(try FileManager.default.contentsOfDirectory(atPath: container.path).isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: container.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: container.path) }
        #expect(!SharedContainerFiles.validate(container: container))
    }
}
