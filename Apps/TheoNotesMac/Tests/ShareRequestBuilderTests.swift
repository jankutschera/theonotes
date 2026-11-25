// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Testing
@testable import TheoNotes

/// The share extension's request building (C17, FOC-R334). The builder file is compiled into this
/// bundle as well as into the extension, so it is tested here without an extension host.
@Suite struct ShareRequestBuilderTests {
    let dir: URL

    init() throws {
        dir = URL(fileURLWithPath: "/tmp/theo-share-builder-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func cleanup() { try? FileManager.default.removeItem(at: dir) }

    // MARK: - Item ids

    @Test func itemIdsAreLowercaseUUIDv7InTimeOrder() {
        let early = ShareRequestBuilder.itemId(now: Date(timeIntervalSince1970: 1_700_000_000))
        let late = ShareRequestBuilder.itemId(now: Date(timeIntervalSince1970: 1_700_000_100))
        for id in [early, late] {
            #expect(id == id.lowercased())
            #expect(UUID(uuidString: id) != nil)
            #expect(id.split(separator: "-")[2].hasPrefix("7"))
        }
        #expect(early < late)
    }

    // MARK: - Text

    @Test func sharedTextIsKeptExactly() {
        let parts = [" A page title \n", "https://example.com/a", "", "https://example.com/a", "  ", "\tindented\n\n"]
        let joined = ShareRequestBuilder.joinText(parts)
        #expect(joined == " A page title \n\n\nhttps://example.com/a\n\nhttps://example.com/a\n\n  \n\n\tindented\n\n")
        #expect(ShareRequestBuilder.joinText(["only"]) == "only")
        #expect(ShareRequestBuilder.joinText(["  keep me  "]) == "  keep me  ")
        #expect(ShareRequestBuilder.joinText([]) == "")
    }

    // MARK: - File names

    @Test func fileNamesAreMadeSafeAndUnique() {
        var taken = Set<String>()
        let names = [
            "photo.png", "Photo.PNG", "a/b\\c:d.txt", "request.json", "", "..", "tab\tname\u{1}.md",
            String(repeating: "x", count: 400) + ".pdf",
        ].map { ShareRequestBuilder.safeFileName($0, taken: &taken) }

        #expect(names[0] == "photo.png")
        #expect(names[1] == "Photo 2.PNG", "same name apart from case")
        #expect(!names[2].contains("/") && !names[2].contains("\\"))
        #expect(names[3] != "request.json")
        #expect(!names[4].isEmpty && names[4] != "..")
        #expect(names[5] != "..")
        #expect(!names[6].unicodeScalars.contains { $0.value < 0x20 })
        #expect(names[7].utf8.count <= 200 && names[7].hasSuffix(".pdf"))
        #expect(Set(names.map { $0.lowercased() }).count == names.count)
    }

    @Test func stagingCopiesTheFileUnderASafeName() throws {
        defer { cleanup() }
        let source = dir.appendingPathComponent("src.bin")
        try Data([1, 2, 3]).write(to: source)
        let staging = dir.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var taken = Set<String>()

        let first = try ShareRequestBuilder.stage(source, suggestedName: "report.pdf", into: staging, taken: &taken)
        let second = try ShareRequestBuilder.stage(source, suggestedName: "report.pdf", into: staging, taken: &taken)

        #expect(first.lastPathComponent == "report.pdf" && second.lastPathComponent == "report 2.pdf")
        #expect(try Data(contentsOf: first) == Data([1, 2, 3]))
        #expect(try Data(contentsOf: source) == Data([1, 2, 3]), "the original stays")
    }

    // MARK: - Request

    @Test func aTargetMakesAnAppendRequestAndNoTargetASaveRequest() {
        let file = URL(fileURLWithPath: "/tmp/x/a.png")
        let target = UUID().uuidString.lowercased()
        let save = ShareRequestBuilder.request(itemId: "i", target: nil, text: "T", files: [file])
        #expect(save.mode == .save && save.targetNoteId == nil && save.files == ["a.png"] && save.text == "T")
        let append = ShareRequestBuilder.request(itemId: "i", target: target, text: "T", files: [])
        #expect(append.mode == .append && append.targetNoteId == target)
    }

    @Test func whatTheExtensionWritesIsWhatTheAppDrains() throws {
        defer { cleanup() }
        let paths = AppPaths(root: dir.appendingPathComponent("library", isDirectory: true))
        try paths.createDirectories()
        let database = try AppDatabase(path: paths.database)
        defer { try? database.pool.close() }
        let store = NoteStore(db: database, notifier: nil, paths: paths)
        let attachments = AttachmentStore(paths: paths, database: database)
        let inbox = CaptureInbox(directory: dir.appendingPathComponent("group/CaptureInbox", isDirectory: true))

        let source = dir.appendingPathComponent("picture.png")
        try Data([9, 9, 9]).write(to: source)
        let staging = dir.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var taken = Set<String>()
        let staged = try ShareRequestBuilder.stage(source, suggestedName: "My: picture.png", into: staging, taken: &taken)

        let existing = try store.create(text: "Existing")
        let saveId = ShareRequestBuilder.itemId()
        let appendId = ShareRequestBuilder.itemId(now: .now.addingTimeInterval(1))
        try inbox.enqueue(ShareRequestBuilder.request(itemId: saveId, target: nil, text: "Shared text", files: [staged]), files: [staged])
        try inbox.enqueue(ShareRequestBuilder.request(itemId: appendId, target: existing.id, text: "More", files: []), files: [])

        let done = try inbox.drain(into: store, attachments: attachments)

        #expect(done == [saveId, existing.id])
        let saved = try #require(try store.note(id: saveId))
        #expect(saved.text.hasPrefix("Shared text\n\n"))
        #expect(saved.text.contains("picture.png"))
        #expect(try store.captureSource(noteId: saveId) == .share)
        #expect(try store.note(id: existing.id)?.text == "Existing\n\nMore")
    }

    // MARK: - recent-notes.json

    @Test func recentNotesAreReadFromTheContainerFile() throws {
        defer { cleanup() }
        let ids = (0..<25).map { _ in UUID().uuidString.lowercased() }
        let file = RecentNotesFile(notes: ids.map { .init(id: $0, title: "Note \($0.prefix(4))") })
        try SharedContainerFiles.publish(file, in: dir)

        let entries = ShareRequestBuilder.recentNotes(inContainer: dir)

        #expect(entries.map(\.id) == Array(ids.prefix(20)), "at most twenty, in file order")
    }

    @Test func aMissingOrBrokenOrOversizedRecentNotesFileGivesNoPicker() throws {
        defer { cleanup() }
        #expect(ShareRequestBuilder.recentNotes(inContainer: dir).isEmpty)
        let target = dir.appendingPathComponent(RecentNotesFile.fileName)

        try Data("not json".utf8).write(to: target)
        #expect(ShareRequestBuilder.recentNotes(inContainer: dir).isEmpty)

        let padding = String(repeating: " ", count: 300_000)
        try Data(#"{"notes":[{"id":"\#(UUID().uuidString.lowercased())","title":"x"}]}"#.utf8 + Data(padding.utf8)).write(to: target)
        #expect(ShareRequestBuilder.recentNotes(inContainer: dir).isEmpty, "bigger than the app ever writes")
    }

    @Test func entriesWithABadIdOrNoTitleAreLeftOut() throws {
        defer { cleanup() }
        let good = UUID().uuidString.lowercased()
        let json = """
            {"notes":[{"id":"../../x","title":"Bad id"},{"id":"\(good)","title":""},\
            {"id":"\(UUID().uuidString)","title":"Upper case id"},{"id":"\(good)","title":"Fine"}]}
            """
        try Data(json.utf8).write(to: dir.appendingPathComponent(RecentNotesFile.fileName))
        let entries = ShareRequestBuilder.recentNotes(inContainer: dir)
        #expect(entries.map(\.title) == ["Fine"])
    }

    // MARK: - Entitlements

    @Test func bothEntitlementFilesNameTheAppGroupTheCodeUses() throws {
        let apps = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        #expect(ShareRequestBuilder.groupIdentifier == AppEnvironment.shareGroupIdentifier)
        for path in ["TheoNotesMac/TheoNotes.entitlements", "TheoNotesMacShare/TheoNotesMacShare.entitlements",
                     "TheoNotesMac/TheoNotes.dev.entitlements", "TheoNotesMacShare/TheoNotesMacShare.dev.entitlements"] {
            let data = try Data(contentsOf: apps.appendingPathComponent(path))
            let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
            #expect(plist["com.apple.security.application-groups"] as? [String] == ["$(THEONOTES_APP_GROUP)"], "\(path)")
        }
        let extensionData = try Data(contentsOf: apps.appendingPathComponent("TheoNotesMacShare/TheoNotesMacShare.entitlements"))
        let extensionPlist = try #require(try PropertyListSerialization.propertyList(from: extensionData, format: nil) as? [String: Any])
        #expect(extensionPlist["com.apple.security.app-sandbox"] as? Bool == true, "extensions must be sandboxed")
    }
}
