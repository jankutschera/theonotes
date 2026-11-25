// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Observation
import TheoNotesCore
import VisionKit

/// One queue for system capture deliveries; the scene connects its current library and UI readiness.
@MainActor @Observable final class MobileCaptureRouter {
    enum Action: Equatable, Sendable { case newNote, newTodo, scan, search, thought, voice }

    enum Failure: LocalizedError, Equatable {
        case libraryChanged, captureUnavailable, scanUnavailable, voiceUnavailable
        var errorDescription: String? {
            switch self {
            case .libraryChanged: "The library changed before this action could finish. Run the action again."
            case .captureUnavailable: "The captured note is no longer editable. Run the action again."
            case .scanUnavailable: "Document scanning is unavailable on this device."
            case .voiceUnavailable: "Voice capture is not available yet."
            }
        }
    }

    struct Presentation: Equatable, Identifiable {
        let id: UUID
        let action: Action
        let noteID: String?
        let libraryRoot: URL
    }

    private struct Request {
        let id: UUID
        let action: Action
        let source: CaptureSource
        var libraryRoot: URL?
        var noteID: String?
    }

    private(set) var presentation: Presentation?
    private(set) var presentationOwner: UUID?
    var pendingCount: Int { pending.count }
    @ObservationIgnored private weak var library: MobileLibrary?
    @ObservationIgnored private var ready = false
    @ObservationIgnored private var draining = false
    private var pending: [Request] = []
    // Pending IDs are retained until completion; completed IDs have a bounded replay window.
    // Persist receipts if cross-launch replay protection is required.
    private static let completedDeliveryLimit = 1024
    @ObservationIgnored private var completedIDs: [UUID] = []
    @ObservationIgnored private var received: Set<UUID> = []
    @ObservationIgnored private let canScan: @MainActor () -> Bool
    @ObservationIgnored private let afterCreate: (@MainActor (Action, String) async throws -> Void)?

    init(canScan: @escaping @MainActor () -> Bool = { VNDocumentCameraViewController.isSupported },
         afterCreate: (@MainActor (Action, String) async throws -> Void)? = nil) {
        self.canScan = canScan
        self.afterCreate = afterCreate
    }

    func connect(_ library: MobileLibrary?, ready: Bool) {
        if self.library !== library { presentation = nil; presentationOwner = nil }
        self.library = library
        self.ready = ready
        if let library {
            for index in pending.indices where pending[index].libraryRoot == nil {
                pending[index].libraryRoot = library.paths.root
            }
        }
    }

    /// Reuse the delivery ID when the system forwards the same event through another lifecycle callback.
    @discardableResult func enqueue(_ action: Action, deliveryID: UUID = UUID(), source: CaptureSource = .command) -> Bool {
        guard received.insert(deliveryID).inserted else { return false }
        pending.append(Request(id: deliveryID, action: action, source: source, libraryRoot: library?.paths.root, noteID: nil))
        return true
    }

    func drain() async throws {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while presentation == nil, !pending.isEmpty, let library = availableLibrary {
            try Task.checkCancellation()
            let request = pending[0]
            do {
                guard request.libraryRoot == library.paths.root else { throw Failure.libraryChanged }
                if request.action == .scan, !canScan() { throw Failure.scanUnavailable }
                var noteID = request.noteID
                if request.action != .search && request.action != .voice, noteID == nil {
                    let created: String
                    switch request.action {
                    case .newNote:
                        created = try library.createNote()
                    case .newTodo:
                        try library.flush()
                        let note = try library.store.create(text: "- [ ] ")
                        library.pendingCaret[note.id] = note.text.utf16.count
                        created = note.id
                    case .thought, .scan:
                        // This helper has no suspension or throwing work after its transactional create.
                        created = try await MobileShortcutRouter.newCapture(source: request.source, library: library)
                    case .search, .voice:
                        preconditionFailure("Non-creating action reached note creation")
                    }
                    pending[0].noteID = created
                    noteID = created
                    // Test seam at the committed-create/navigation boundary.
                    try await afterCreate?(request.action, created)
                }
                try Task.checkCancellation()
                guard availableLibrary === library else { return }
                if let noteID {
                    if request.action == .scan {
                        guard let note = try library.store.note(id: noteID), note.deletedAt == nil,
                              !note.isLocked, !note.isReadOnly, note.location == .notes else { throw Failure.captureUnavailable }
                    }
                    try library.reveal(noteID)
                }
                if request.action == .scan || request.action == .search || request.action == .voice {
                    presentation = Presentation(id: request.id, action: request.action,
                                                noteID: noteID, libraryRoot: library.paths.root)
                }
                completeFirstRequest()
            } catch let failure as Failure {
                completeFirstRequest()
                throw failure
            } catch let error as StoreError {
                if case .noteNotFound = error { completeFirstRequest() }
                throw error
            }

        }
    }

    private func completeFirstRequest() {
        let deliveryID = pending.removeFirst().id
        completedIDs.append(deliveryID)
        if completedIDs.count > Self.completedDeliveryLimit {
            received.remove(completedIDs.removeFirst())
        }
    }

    /// A scan waiting for its editor must not block later actions after the user navigates away.
    @discardableResult func discardUnclaimedStaleScan() -> Bool {
        guard let target = presentation, target.action == .scan, presentationOwner == nil,
              let library = availableLibrary, target.libraryRoot == library.paths.root,
              let noteID = target.noteID, library.selectedID != noteID else { return false }
        presentation = nil
        return true
    }

    /// The media owner must also validate its originating editor/session/caret before inserting bytes.
    func canAcceptScan(_ target: Presentation, owner: UUID? = nil) -> Bool {
        guard target.action == .scan, presentation == target, presentationOwner == owner, let library = availableLibrary,
              target.libraryRoot == library.paths.root, let noteID = target.noteID,
              library.selectedID == noteID, let note = try? library.store.note(id: noteID) else { return false }
        return !note.isLocked && !note.isReadOnly && note.deletedAt == nil && note.location == .notes
    }

    /// Voice creates its own note only after microphone/model preflight succeeds.
    func canAcceptVoice(_ target: Presentation, owner: UUID? = nil) -> Bool {
        guard target.action == .voice, target.noteID == nil, presentation == target,
              presentationOwner == owner, let library = availableLibrary else { return false }
        return target.libraryRoot == library.paths.root
    }

    /// Claim before awaiting an editor barrier; another scene cannot present the same request.
    @discardableResult func claimPresentation(_ target: Presentation, owner: UUID) -> Bool {
        guard presentation == target, let library = availableLibrary, target.libraryRoot == library.paths.root,
              presentationOwner == nil || presentationOwner == owner else { return false }
        if target.action == .scan, !canAcceptScan(target, owner: presentationOwner) { return false }
        if target.action == .voice, !canAcceptVoice(target, owner: presentationOwner) { return false }
        presentationOwner = owner
        return true
    }

    @discardableResult func releasePresentation(deliveryID: UUID, owner: UUID) -> Bool {
        guard presentation?.id == deliveryID, presentationOwner == owner else { return false }
        presentationOwner = nil
        return true
    }

    /// Dismissal writes no attachment and never trashes a note that may have unacknowledged edits.
    @discardableResult func finishPresentation(deliveryID: UUID, owner: UUID? = nil) -> Bool {
        guard presentation?.id == deliveryID, presentationOwner == owner else { return false }
        presentation = nil
        presentationOwner = nil
        return true
    }

    private var availableLibrary: MobileLibrary? {
        guard ready, let library, !library.appLocked, !library.libraryOperationBusy,
              !library.isClosed, !library.isClosing else { return nil }
        return library
    }
}
