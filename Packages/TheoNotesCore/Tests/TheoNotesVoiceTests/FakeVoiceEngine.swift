// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Synchronization
import Testing
@testable import TheoNotesCore
@testable import TheoNotesVoice

/// A scripted engine: `start` writes `audio` to the recording URL (standing in for the microphone)
/// and hands out a stream the test drives with `send` and `fail`. `finish` yields
/// `remainingOnFinish` (the results the analyzer still had) and ends the stream; `cancel` ends it.
/// Both tear the recording down like the live engine: after a short delay the file gets
/// `closeMarker` appended (the header a real close writes), so an attachment taken before the
/// teardown finished lacks it.
final class FakeVoiceEngine: VoiceEngine {
    func isRecordingReadable(at url: URL) -> Bool {
        validatesRealAudio ? VoiceRecordingRecovery.isPlayable(url) : ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
    }
    enum Call: Equatable, Sendable { case start(URL), finish, cancel }

    private struct State {
        var calls: [Call] = []
        var continuation: AsyncThrowingStream<VoiceEvent, any Error>.Continuation?
        var remainingOnFinish: [VoiceEvent] = []
        var startError: (any Error)?
        var recording: URL?
        var closed = false
        var holdNextStart: AsyncStream<Void>?
        var holdNextFinish: AsyncStream<Void>?
        var holdNextCancel: AsyncStream<Void>?
        var keepsStreamOpen = false
    }

    static let closeMarker = Data("+closed".utf8)

    let audio: Data
    /// Whether the teardown appends `closeMarker` (a real close writes a header). Off, an engine
    /// given empty audio leaves an empty recording, which Stop has nothing to attach from.
    let writesCloseMarker: Bool
    let validatesRealAudio: Bool
    private let state = Mutex(State())

    init(audio: Data = Data("fake m4a bytes".utf8), writesCloseMarker: Bool = true, validatesRealAudio: Bool = false) {
        self.audio = audio
        self.writesCloseMarker = writesCloseMarker
        self.validatesRealAudio = validatesRealAudio
    }

    var calls: [Call] { state.withLock { $0.calls } }

    func setRemainingOnFinish(_ events: [VoiceEvent]) { state.withLock { $0.remainingOnFinish = events } }
    func setStartError(_ error: any Error) { state.withLock { $0.startError = error } }
    /// `finish` and `cancel` no longer end the event stream (an engine whose stream never ends).
    func keepStreamOpen() { state.withLock { $0.keepsStreamOpen = true } }

    /// The next `start` waits until the returned continuation yields (or finishes).
    func holdNextStart() -> AsyncStream<Void>.Continuation {
        let (gate, opener) = AsyncStream.makeStream(of: Void.self)
        state.withLock { $0.holdNextStart = gate }
        return opener
    }

    /// The next `finish` waits until the returned continuation yields (or finishes) before it
    /// delivers its results and ends the stream.
    func holdNextFinish() -> AsyncStream<Void>.Continuation {
        let (gate, opener) = AsyncStream.makeStream(of: Void.self)
        state.withLock { $0.holdNextFinish = gate }
        return opener
    }

    /// The next `cancel` waits until the returned continuation yields (or finishes) before it
    /// ends the stream and tears the recording down.
    func holdNextCancel() -> AsyncStream<Void>.Continuation {
        let (gate, opener) = AsyncStream.makeStream(of: Void.self)
        state.withLock { $0.holdNextCancel = gate }
        return opener
    }

    /// How often the engine was asked to tear down (`finish` and `cancel` each do it once).
    var teardownCalls: Int { calls.filter { $0 == .finish || $0 == .cancel }.count }

    /// Whether `finish` or `cancel` tore the recording down.
    var isClosed: Bool { state.withLock { $0.closed } }

    private func tearDown() async {
        try? await Task.sleep(for: .milliseconds(30))
        let url = state.withLock { state -> URL? in
            guard !state.closed else { return nil }
            state.closed = true
            return state.recording
        }
        guard writesCloseMarker, let url, let handle = try? FileHandle(forWritingTo: url) else { return }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Self.closeMarker)
        try? handle.close()
    }

    func start(recordingTo url: URL) async throws -> AsyncThrowingStream<VoiceEvent, any Error> {
        let (startError, hold) = state.withLock { state -> ((any Error)?, AsyncStream<Void>?) in
            state.calls.append(.start(url))
            defer { state.holdNextStart = nil }
            return (state.startError, state.holdNextStart)
        }
        if let hold { for await _ in hold { break } }
        if let startError { throw startError }
        try audio.write(to: url)
        state.withLock { $0.recording = url }
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: VoiceEvent.self)
        state.withLock { $0.continuation = continuation }
        return stream
    }

    func finish() async throws {
        let (continuation, remaining, hold) = state.withLock { state in
            state.calls.append(.finish)
            defer { state.holdNextFinish = nil }
            return (state.continuation, state.remainingOnFinish, state.holdNextFinish)
        }
        if let hold { for await _ in hold { break } }
        for event in remaining { continuation?.yield(event) }
        if !state.withLock({ $0.keepsStreamOpen }) { continuation?.finish() }
        await tearDown()
    }

    func cancel() async {
        let (continuation, hold) = state.withLock { state in
            state.calls.append(.cancel)
            defer { state.holdNextCancel = nil }
            return (state.continuation, state.holdNextCancel)
        }
        if let hold { for await _ in hold { break } }
        if !state.withLock({ $0.keepsStreamOpen }) { continuation?.finish() }
        await tearDown()
    }

    func send(_ event: VoiceEvent) {
        _ = state.withLock { $0.continuation }?.yield(event)
    }

    func final(_ text: String) { send(.transcript(TranscriptUpdate(text: text, isFinal: true))) }
    func partial(_ text: String) { send(.transcript(TranscriptUpdate(text: text, isFinal: false))) }

    func fail(_ error: any Error) {
        state.withLock { $0.continuation }?.finish(throwing: error)
    }
}

struct FakeEngineFailure: Error, Equatable {}

/// A counter any thread may bump.
final class TestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

/// A flag one thread sets and another polls.
final class TestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// A throw-away library under the temporary folder, with the app's session cache stand-in.
@MainActor
final class VoiceTestLibrary {
    let paths: AppPaths
    let db: AppDatabase
    let store: NoteStore
    let attachments: AttachmentStore
    private(set) var sessions: [String: NoteSession] = [:]

    init() throws {
        paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID())"))
        try paths.createDirectories()
        db = try AppDatabase(path: paths.database)
        store = NoteStore(db: db, notifier: nil, paths: paths)
        attachments = AttachmentStore(paths: paths, database: db)
    }

    /// The cached session for a note, as the app's `session(for:)`. Commits are left to `flush`,
    /// so what is journaled can be told apart from what is committed.
    func session(_ noteId: String) throws -> NoteSession {
        if let session = sessions[noteId] { return session }
        let session = try NoteSession(
            noteId: noteId, store: store, journalDirectory: paths.journal, commitDelay: .seconds(3600))
        sessions[noteId] = session
        return session
    }

    func capture(
        _ target: VoiceCapture.Target, engine: FakeVoiceEngine, now: Date = Date(timeIntervalSince1970: 1_800_000_000),
        session: (@MainActor (String) throws -> NoteSession)? = nil,
        finishTimeout: Duration = .seconds(15)
    ) -> VoiceCapture {
        VoiceCapture(
            target: target, store: store, attachments: attachments, session: session ?? { [unowned self] in try self.session($0) },
            engine: engine, recordingsDirectory: paths.recordings, now: { now }, finishTimeout: finishTimeout)
    }

    /// Locks `noteId` the way sync does: the materializer's row change plus `purgeRemoteLock`,
    /// in one transaction.
    func remoteLock(_ noteId: String) throws {
        try db.pool.write { db in
            try db.execute(sql: "UPDATE note SET text = '', isLocked = 1, encryptedPayload = ?, revision = revision + 1 WHERE id = ?",
                           arguments: [Data([1, 2, 3]), noteId])
            try FocusPurge.purgeRemoteLock(noteId: noteId, in: db)
        }
    }

    /// `remoteLock` from any thread, with `hold` running inside the transaction after the purge
    /// (so a test can keep the lock uncommitted while something else runs).
    nonisolated static func remoteLock(_ noteId: String, in database: AppDatabase, whileHolding hold: @Sendable () -> Void) throws {
        try database.pool.write { db in
            try db.execute(sql: "UPDATE note SET text = '', isLocked = 1, encryptedPayload = ?, revision = revision + 1 WHERE id = ?",
                           arguments: [Data([1, 2, 3]), noteId])
            try FocusPurge.purgeRemoteLock(noteId: noteId, in: db)
            hold()
        }
    }

    func withPermissionsAsync(_ mode: Int, on folder: URL, _ body: () async throws -> Void) async rethrows {
        let fm = FileManager.default
        let old = (try? fm.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int) ?? 0o755
        try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: folder.path)
        defer { try? fm.setAttributes([.posixPermissions: old], ofItemAtPath: folder.path) }
        try await body()
    }

    /// Runs `body` with `folder`'s permissions set to `mode`, restoring them afterwards.
    @discardableResult
    func withPermissions<T>(_ mode: Int, on folder: URL, _ body: () throws -> T) rethrows -> T {
        let fm = FileManager.default
        let old = (try? fm.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int) ?? 0o755
        try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: folder.path)
        defer { try? fm.setAttributes([.posixPermissions: old], ofItemAtPath: folder.path) }
        return try body()
    }

    func attachmentNames(_ noteId: String) -> [String] {
        let dir = paths.attachments.appendingPathComponent(noteId, isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { !$0.hasPrefix(".") }.sorted()
    }

    func recordingFiles() -> [String] {
        guard let walker = FileManager.default.enumerator(atPath: paths.recordings.path) else { return [] }
        return walker.compactMap { $0 as? String }.filter {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: paths.recordings.appendingPathComponent($0).path, isDirectory: &isDir)
            return !isDir.boolValue
        }
    }

    func access() throws -> LockedNoteAccess {
        let (envelope, key) = try CryptoEnvelope.create(password: "fixture-password", iterations: 1)
        try db.pool.write {
            try $0.execute(sql: "INSERT INTO crypto_envelope(id,envelope) VALUES(1,?)", arguments: [try JSONEncoder().encode(envelope)])
        }
        return LockedNoteAccess(store: store, key: key)
    }

    /// Labels of `markers` found in any file name or file content under the library folder
    /// (labels only, so a failure never prints a secret).
    func canaryHits(_ markers: [String: String]) throws -> Set<String> {
        var found = Set<String>()
        let walker = try #require(FileManager.default.enumerator(at: paths.root, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let file as URL in walker {
            let name = Data(file.lastPathComponent.utf8)
            var data = Data()
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { data = try Data(contentsOf: file) }
            for (label, marker) in markers where name.range(of: Data(marker.utf8)) != nil || data.range(of: Data(marker.utf8)) != nil {
                found.insert(label)
            }
        }
        return found
    }

    func cleanup() {
        sessions.values.forEach { $0.removeAllListeners() }
        sessions = [:]
        try? db.pool.close()
        try? FileManager.default.removeItem(at: paths.root)
    }
}

/// Waits (polling the main actor) until `condition` holds; records an issue after two seconds.
@MainActor
func eventually(_ what: String = "condition", _ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
    for _ in 0..<400 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    if !condition() { Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation) }
}

/// How many times `needle` occurs in `text`.
func occurrences(of needle: String, in text: String) -> Int {
    text.components(separatedBy: needle).count - 1
}
