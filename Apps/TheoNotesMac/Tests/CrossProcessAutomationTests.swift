// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import TheoNotes

/// What one run of the embedded CLI printed.
struct BinaryResult {
    var exit: Int32
    var out: String
    var err: String
}

/// The CLI embedded in the test host, `Theo Notes Dev.app/Contents/Helpers/theonotes`.
/// `Bundle.main.url(forAuxiliaryExecutable: "theonotes")` is not used: it looks in
/// `Contents/MacOS`, where on a case-insensitive volume `theonotes` names the app executable itself.
enum EmbeddedCLI {
    static var url: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/theonotes") }

    /// Runs the CLI as its own process and waits for it (blocking the caller, on purpose: the
    /// main actor runs no debounced commit meanwhile). `stdin` is a file piped in.
    static func run(_ args: [String], stdin: URL? = nil) throws -> BinaryResult {
        let process = Process()
        process.executableURL = url
        process.arguments = args
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = try stdin.map { try FileHandle(forReadingFrom: $0) } ?? FileHandle.nullDevice
        try process.run()
        nonisolated(unsafe) var errData = Data()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        drained.wait()
        process.waitUntilExit()
        return BinaryResult(
            exit: process.terminationStatus, out: String(decoding: outData, as: UTF8.self),
            err: String(decoding: errData, as: UTF8.self))
    }
}

/// The CLI (a separate process) writing to a library the app has open (M5 Task 16): a real
/// `AppEnvironment` on a temporary library, a fake editor page, the Darwin notification as the
/// only link between the two processes.
@MainActor
@Suite struct CrossProcessAutomationTests {
    let root: URL
    let environment: AppEnvironment
    let page = FakeEditorPage()
    let controller: EditorBridgeController
    let conflictCopies = Box<[String]>([])
    let notifications = NotificationCount()
    let notificationToken: ObservationToken

    final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    /// Darwin notifications received; the observer calls in on any thread.
    final class NotificationCount: Sendable {
        private let count = Mutex(0)
        func increment() { count.withLock { $0 += 1 } }
        var value: Int { count.withLock { $0 } }
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("TheoNotesCrossProcess-\(UUID().uuidString)")
        environment = try AppEnvironment(paths: AppPaths(root: root))
        controller = EditorBridgeController(
            environment: environment, page: page, openExternally: { _ in }, checksumInterval: nil)
        let copies = conflictCopies
        environment.addConflictCopyObserver { copies.value.append($0) }
        // Counts the Darwin notifications this process receives (every Theo Notes process posts the
        // same one), independent of the environment's own observer.
        let notifications = notifications
        notificationToken = ChangeNotifier().observe { notifications.increment() }
    }

    private func cli(_ args: String..., stdin: URL? = nil) throws -> BinaryResult {
        try EmbeddedCLI.run(["--data-dir", root.path] + args, stdin: stdin)
    }

    /// Opens `text` as a new note in the editor; returns its id and session.
    private func openNote(_ text: String) throws -> (String, NoteSession) {
        let id = try environment.store.create(text: text).id
        try controller.open(noteId: id)
        _ = controller.handle(.ready(version: EditorBridge.version))
        return (id, try environment.session(for: id))
    }

    private func insert(_ s: String, at pos: Int, into session: NoteSession, txId: String) -> ChangesReply? {
        let length = session.text.utf16.count
        var sections: [ChangeSet.Section] = []
        if pos > 0 { sections.append(.retain(pos)) }
        sections.append(.replace(deleteLength: 0, insert: s))
        if length - pos > 0 { sections.append(.retain(length - pos)) }
        return controller.handle(.changes(
            noteId: session.noteId, txId: txId, baseRevision: session.revision, revision: session.revision + 1,
            changeSet: ChangeSet(sections: sections)))
    }

    private func delete(_ count: Int, at pos: Int, in session: NoteSession, txId: String) -> ChangesReply? {
        let length = session.text.utf16.count
        var sections: [ChangeSet.Section] = []
        if pos > 0 { sections.append(.retain(pos)) }
        sections.append(.replace(deleteLength: count, insert: ""))
        if length - pos - count > 0 { sections.append(.retain(length - pos - count)) }
        return controller.handle(.changes(
            noteId: session.noteId, txId: txId, baseRevision: session.revision, revision: session.revision + 1,
            changeSet: ChangeSet(sections: sections)))
    }

    private func storeText(_ id: String) throws -> String { try #require(try environment.store.note(id: id)).text }

    /// Polls (the main actor stays free, so notifications and debounced commits run) until true.
    private func eventually(_ seconds: Double = 5, _ condition: () throws -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try condition()
    }

    private var externalChanges: [ChangeSet] {
        page.delivered.compactMap { if case .applyExternalChange(_, _, let c) = $0 { c } else { nil } }
    }

    // MARK: -

    @Test func theCLIIsEmbedded() {
        #expect(FileManager.default.isExecutableFile(atPath: EmbeddedCLI.url.path), "\(EmbeddedCLI.url.path)")
    }

    /// Typing at the top (acked, not committed: 400 ms debounce) while the CLI appends at the end:
    /// the Darwin notification brings the change in, both edits are kept, no conflict copy.
    @Test func cliAppendWhileTypingMergesBothEdits() async throws {
        let (id, session) = try openNote("# T\nline\n")
        #expect(insert("A", at: 0, into: session, txId: "a") == .acked(revision: 1))
        let seen = notifications.value

        let result = try cli("append", id, "--content", "B")
        #expect(result.exit == 0, "\(result.err)")
        // The main actor was blocked meanwhile, so the session has not committed "A" yet.
        let remote = try storeText(id)
        #expect(remote.hasPrefix("# T\nline\n") && remote.contains("B"))

        #expect(try await eventually { notifications.value > seen })
        let expected = "A" + remote
        #expect(try await eventually { session.text == expected })
        session.flushIfNeeded()
        #expect(try storeText(id) == expected)
        #expect(session.committedText == expected)
        #expect(try externalChanges.last.map { try $0.apply(to: "A# T\nline\n") } == expected)
        #expect(page.loadNotes.count == 1)
        #expect(conflictCopies.value.isEmpty)
        #expect(try environment.store.allNotes().count == 1)
    }

    /// Typing and the CLI change the same line: the session keeps the typing, a conflict copy
    /// holds the CLI's version, and every window is told once.
    @Test func cliEditOverlappingTypingKeepsLocalAndMakesConflictCopy() async throws {
        let (id, session) = try openNote("# T\nline\n")
        #expect(insert(" local", at: 8, into: session, txId: "a") == .acked(revision: 1))

        let result = try cli("edit", id, "--find", "line", "--replace", "line cli")
        #expect(result.exit == 0, "\(result.err)")
        #expect(try storeText(id) == "# T\nline cli\n")

        #expect(try await eventually { !conflictCopies.value.isEmpty })
        #expect(session.text == "# T\nline local\n")
        #expect(try storeText(id) == "# T\nline local\n")
        #expect(conflictCopies.value.count == 1)
        let copy = try #require(conflictCopies.value.first)
        #expect(try storeText(copy) == "# T\nline cli\n")
        #expect(externalChanges.isEmpty) // the editor's text was never replaced
        // Later notifications (any process) do not make a second copy.
        try await Task.sleep(for: .milliseconds(600))
        #expect(conflictCopies.value.count == 1)
        #expect(try environment.store.allNotes().count == 2)
    }

    /// The session commits after the CLI wrote, before the notification is handled: the revision
    /// conflict is handled by merging, the typing is kept, nothing fails.
    ///
    /// The debounced commit is `flush()` once 400 ms passed. Which of it and the notification's
    /// `databaseDidChange` runs first is up to the main queue (blocking the main actor past the
    /// debounce, before or after the CLI ran, still put the notification first every time), so
    /// the test runs the commit itself, right after the CLI write and before the main actor yields.
    @Test func sessionCommitAfterCLIWriteDoesNotFailOrDropTyping() async throws {
        let (id, session) = try openNote("# T\nline\nmore\n")
        #expect(insert("A", at: 0, into: session, txId: "a") == .acked(revision: 1))
        let calls = environment.externalChangeCallCount
        let seen = notifications.value

        let result = try cli("edit", id, "--find", "more", "--replace", "more cli")
        #expect(result.exit == 0, "\(result.err)")
        #expect(try storeText(id) == "# T\nline\nmore cli\n")
        try session.flush() // what the debounce runs; throws if the revision conflict escaped

        let expected = "A# T\nline\nmore cli\n"
        #expect(try storeText(id) == expected)
        #expect(session.text == expected)
        #expect(session.committedText == expected)
        #expect(try externalChanges.last.map { try $0.apply(to: "A# T\nline\nmore\n") } == expected)

        // The notification arrives afterwards and finds the session current; the cancelled
        // debounce writes nothing.
        #expect(try await eventually { notifications.value > seen })
        try await Task.sleep(for: .milliseconds(600))
        #expect(environment.externalChangeCallCount == calls)
        #expect(try storeText(id) == expected)
        #expect(session.text == expected)
        #expect(conflictCopies.value.isEmpty)
        #expect(environment.unsavedNoteIds.isEmpty)
    }

    /// R9: a CLI tag rename reaches the open editor as an external change (which the editor
    /// applies outside its undo history), not as a reload; undoing the editor's own last edit then
    /// keeps the rename.
    @Test func cliTagRenameWhileNoteOpenUpdatesEditorWithoutUndoEntry() async throws {
        let (id, session) = try openNote("# T\nline #old\n")
        #expect(insert("A", at: 0, into: session, txId: "typed") == .acked(revision: 1))
        #expect(try await eventually { (try storeText(id)) == "A# T\nline #old\n" })

        let result = try cli("tags", "rename", "old", "new")
        #expect(result.exit == 0, "\(result.err)")
        #expect(try await eventually { session.text == "A# T\nline #new\n" })
        #expect(externalChanges.count == 1)
        #expect(page.loadNotes.count == 1) // no reload, which would reset the editor's history

        // The editor's history holds only "A": its undo removes that and nothing else.
        #expect(delete(1, at: 0, in: session, txId: "undo") == .acked(revision: 3))
        #expect(session.text == "# T\nline #new\n")
        session.flushIfNeeded()
        #expect(try storeText(id) == "# T\nline #new\n")
        #expect(conflictCopies.value.isEmpty)
    }

    /// An attachment the CLI adds to the open note survives the cleanup that runs when the note is
    /// closed and its session evicted, even past the grace period; an unreferenced file does not.
    @Test func cliAttachmentAddToOpenNoteKeepsFileThroughEvictionCleanup() async throws {
        let (id, session) = try openNote("# T\nline\n")
        let input = root.appendingPathComponent("input.png")
        try Data(repeating: 7, count: 512).write(to: input)

        let result = try cli("attachments", "add", id, "--filename", "pic.png", stdin: input)
        #expect(result.exit == 0, "\(result.err)")
        #expect(try await eventually { session.text.contains("pic.png") })

        let dir = environment.paths.attachments.appendingPathComponent(id)
        let file = dir.appendingPathComponent("pic.png")
        let stray = dir.appendingPathComponent("stray.txt")
        try Data("x".utf8).write(to: stray)
        let old = Date().addingTimeInterval(-3600)
        for url in [file, stray] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }

        controller.showNoNote()
        environment.setOpenNoteIds([], for: ObjectIdentifier(controller))
        #expect(environment.existingSession(for: id) == nil) // evicted: the cleanup ran
        #expect(!FileManager.default.fileExists(atPath: stray.path))
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try Data(contentsOf: file) == Data(repeating: 7, count: 512))
        #expect(try storeText(id).contains("pic.png"))
    }

    /// The CLI read the note's hash before the app committed its typing: its overwrite with that
    /// base fails with `stale_hash` and changes nothing.
    @Test func cliOverwriteWithStaleBaseWhileTypingIsRejected() async throws {
        let (id, session) = try openNote("# T\nline\n")
        #expect(insert("A", at: 0, into: session, txId: "a") == .acked(revision: 1))

        let read = try cli("cat", id, "--format", "json")
        #expect(read.exit == 0, "\(read.err)")
        // `cat`'s receipt: the first 7 hex digits of the SHA-256 (ContentHash).
        let hash = String(SHA256.hash(data: Data("# T\nline\n".utf8)).map { String(format: "%02x", $0) }.joined().prefix(7))
        #expect(read.out.contains("\"hash\":\"\(hash)\""), "\(read.out)") // the store text before the app's commit

        #expect(try await eventually { (try storeText(id)) == "A# T\nline\n" })
        // `overwrite` has no --format; stale_hash reports this message (exit 1).
        let write = try cli("overwrite", id, "--base", hash, "--content", "# T\nreplaced\n")
        #expect(write.exit == 1)
        #expect(write.err == "Error: The note changed since it was read. Re-read it and retry.\n", "\(write.err)")
        #expect(try storeText(id) == "A# T\nline\n")
        try await Task.sleep(for: .milliseconds(200))
        #expect(session.text == "A# T\nline\n")
        #expect(externalChanges.isEmpty)

        // Control: the current receipt is accepted, and the open session adopts the overwrite.
        let fresh = try cli("cat", id, "--format", "json")
        let current = String(SHA256.hash(data: Data("A# T\nline\n".utf8)).map { String(format: "%02x", $0) }.joined().prefix(7))
        #expect(fresh.out.contains("\"hash\":\"\(current)\""), "\(fresh.out)")
        let accepted = try cli("overwrite", id, "--base", current, "--content", "# T\nreplaced\n")
        #expect(accepted.exit == 0, "\(accepted.err)")
        #expect(try await eventually { session.text == "# T\nreplaced\n" })
        #expect(conflictCopies.value.isEmpty)
    }
}

private extension NoteSession {
    /// Commits pending text now (the debounce may not have fired yet).
    func flushIfNeeded() {
        do { try flush() } catch { Issue.record("flush failed: \(error)") }
    }
}
