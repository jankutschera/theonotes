// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Darwin

/// One shared item, once loaded.
enum SharedPart: Sendable {
    case text(String)
    case file(URL)
    /// The item named a type it could not deliver.
    case failed
}

/// The private temporary folder the shared files are copied into before they are queued.
@MainActor
final class StagingArea {
    let directory: URL
    private var taken = Set<String>()
    private var bytes = 0
    private var count = 0

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
    }

    func stage(_ source: URL, suggestedName: String?) throws -> URL {
        guard count < 10 else { throw CaptureInboxError.invalidRequest("too many files") }
        let file = try ShareRequestBuilder.stage(source, suggestedName: suggestedName, into: directory, taken: &taken)
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        guard bytes + size <= 50 * 1024 * 1024 else {
            try? FileManager.default.removeItem(at: file)
            throw CaptureInboxError.invalidRequest("files too large")
        }
        bytes += size
        count += 1
        return file
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// Collects a complete payload before allowing a durable handover to the existing inbox.
@MainActor
final class ShareSheetModel {
    enum Phase: Equatable {
        /// No usable App Group container: nothing can be saved.
        case unavailable
        /// Shared items are still being read; the text is not editable and nothing can be saved yet.
        case collecting
        case ready
        case submitting
    }

    private(set) var phase: Phase
    private(set) var text = ""
    private var sharedText = ""
    private var failedCollection = false
    private(set) var files: [URL] = []
    private(set) var recentNotes: [RecentNotesFile.Entry] = []
    private(set) var status: String
    /// Called after every change the view needs to show.
    var onChange: () -> Void = {}

    private let container: URL?
    private let enqueue: @Sendable (CaptureRequest, [URL]) throws -> Void
    private var watcher: DispatchSourceFileSystemObject?

    var canEdit: Bool { phase == .ready }
    var canSave: Bool { phase == .ready && !failedCollection && (!text.isEmpty || !sharedText.isEmpty || !files.isEmpty) }
    var canAppend: Bool { canSave && !recentNotes.isEmpty }

    /// `container` is the probed App Group folder, or nil when there is none. `enqueue` is what hands an
    /// item to the app; the default writes into the container's `CaptureInbox`.
    init(container: URL?, enqueue: (@Sendable (CaptureRequest, [URL]) throws -> Void)? = nil) {
        self.container = container
        if let container {
            let inbox = CaptureInbox(directory: container.appendingPathComponent("CaptureInbox", isDirectory: true))
            self.enqueue = enqueue ?? { try inbox.enqueue($0, files: $1) }
            phase = .collecting
            status = ""
            recentNotes = ShareRequestBuilder.recentNotes(inContainer: container)
        } else {
            self.enqueue = enqueue ?? { _, _ in throw CocoaError(.fileNoSuchFile) }
            phase = .unavailable
            status = "Theo Notes can't take shared items right now."
        }
    }

    isolated deinit { watcher?.cancel() }

    // MARK: - Collecting

    /// Reads every shared item and fills the text. `texts` are the texts the sharing app sent along; each
    /// `load` reads one attachment. Editing is off until this returns, and what was typed meanwhile (a
    /// view that ignored that) is kept: loaded text goes after it, never over it. Items that could not
    /// be read (or all of them, when there is no staging folder) are counted in the status.
    func collect(texts: [String], loads: [@MainActor (StagingArea) async -> SharedPart], staging: StagingArea?) async {
        guard phase == .collecting else { return }
        var parts = texts.filter { $0.utf8.count <= 2 * 1024 * 1024 }
        var loaded: [URL] = []
        var failures = texts.count - parts.count
        var textBytes = parts.reduce(0) { $0 + $1.utf8.count + 2 }
        if textBytes > 2 * 1024 * 1024 { parts = []; failures += 1 }
        for load in loads {
            // With no staging folder nothing can be copied: every item counts as unread.
            guard let staging else { failures += 1; continue }
            switch await load(staging) {
            case .text(let part):
                textBytes += part.utf8.count + 2
                if textBytes <= 2 * 1024 * 1024 { parts.append(part) } else { failures += 1 }
            case .file(let url): loaded.append(url)
            case .failed: failures += 1
            }
        }
        let joined = ShareRequestBuilder.joinText(parts)
        sharedText = joined
        failedCollection = failures > 0 || joined.utf8.count > 2 * 1024 * 1024
        if text.isEmpty {
            text = joined
        } else if !joined.isEmpty {
            text += "\n\n" + joined
        }
        files = loaded
        status = failedCollection ? "Some shared content could not be read or is too large. Cancel and share fewer items." : Self.status(fileCount: loaded.count, failures: failures)
        phase = .ready
        onChange()
    }

    /// The user changed the text.
    func userEdited(_ newText: String) {
        text = newText
        onChange()
    }

    private static func status(fileCount: Int, failures: Int) -> String {
        var lines: [String] = []
        if fileCount == 1 { lines.append("1 file will be attached.") }
        if fileCount > 1 { lines.append("\(fileCount) files will be attached.") }
        if failures == 1 { lines.append("1 shared item could not be read and is not included.") }
        if failures > 1 { lines.append("\(failures) shared items could not be read and are not included.") }
        return lines.joined(separator: " ")
    }

    // MARK: - The picker follows the app

    /// Reads `recent-notes.json` again. The app rewrites it when notes change and deletes it when App
    /// Lock is turned on or a note is locked, and an open sheet must not keep offering what is gone.
    func refreshRecentNotes() {
        guard let container else { return }
        let fresh = ShareRequestBuilder.recentNotes(inContainer: container)
        guard fresh != recentNotes else { return }
        recentNotes = fresh
        onChange()
    }

    /// Watches the container folder and refreshes the picker whenever it changes.
    func startWatching() {
        guard let container, watcher == nil else { return }
        let descriptor = open(container.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.refreshRecentNotes() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }

    // MARK: - Hand over

    /// Queues the item: a save, or an append to `target`. An append is checked against the list as it is
    /// now (the note may have been locked, or App Lock turned on, since the sheet opened). Returns true
    /// when the item is in the inbox.
    func submit(target: String?) async -> Bool {
        guard canSave else { return false }
        if let target {
            refreshRecentNotes()
            guard recentNotes.contains(where: { $0.id == target }) else {
                status = "That note is not available any more."
                onChange()
                return false
            }
        }
        phase = .submitting
        onChange()
        let request = ShareRequestBuilder.request(
            itemId: ShareRequestBuilder.itemId(), target: target, text: text.isEmpty ? sharedText : text, files: files)
        let files = files
        let enqueue = enqueue
        do {
            try await Task.detached { try enqueue(request, files) }.value
            return true
        } catch {
            phase = .ready
            status = "Theo Notes could not take this. It may be too large or have too many files."
            onChange()
            return false
        }
    }
}
