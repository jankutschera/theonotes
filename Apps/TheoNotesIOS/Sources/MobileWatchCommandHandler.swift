// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import TheoNotesCore

@MainActor enum MobileWatchCommandHandler {
    /// A returned ACK represents a committed receipt; temporary errors must leave the Watch pending.
    static func handle(_ command: WatchWireCommand, library: MobileLibrary) async throws -> WatchWireAck {
        try command.validate()
        guard command.libraryID == (try library.store.watchLibraryID()) else { throw WatchWireError.binding }
        let result: WatchWireResult
        do {
            guard !library.sceneEditorAdmissionBlocked else { throw MobileEditorDrainError.busy }
            let action: WatchNoteCommand.Action
            switch command.action {
            case .create(let text): action = .create(text: text)
            case .append(let id, let revision, let text): action = .append(noteID: id, revision: revision, text: text)
            case .setTask(let id, let revision, let hash, let offset, let marker, let checked):
                action = .setTask(noteID: id, revision: revision, sourceSHA256: hash, utf16Offset: offset, expectedMarker: marker, checked: checked)
            }
            let core = WatchNoteCommand(id: command.id, epoch: command.epoch, createdAt: command.createdAt, action: action)
            let stored = try await library.withDrainedShareEditors {
                guard !library.isClosed, !library.isClosing, !library.libraryOperationBusy else { throw MobileEditorDrainError.busy }
                return try library.store.applyWatchCommand(core)
            }
            switch stored {
            case .applied(let id, let revision): result = .applied(noteID: id, revision: revision)
            case .appliedArchived(let id, let revision): result = .appliedArchived(noteID: id, revision: revision)
            case .appliedTrashed(let id, let revision): result = .appliedTrashed(noteID: id, revision: revision)
            case .refused(let reason):
                guard let mapped = WatchWireRefusal(rawValue: reason.rawValue) else { throw WatchWireError.invalid }
                result = .refused(mapped)
            }
            do { try library.refreshSessions() }
            catch { library.errorMessage = "The Watch change was saved, but the note view could not be refreshed." }
        }
        return WatchWireAck(commandID: command.id, libraryID: command.libraryID, epoch: command.epoch, result: result)
    }
}
