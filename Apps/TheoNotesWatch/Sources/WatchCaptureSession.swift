// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Observation

enum WatchCaptureCancelDisposition: Equatable {
    case pendingRequest, savedDraft, unsavedText
    var message: String {
        switch self {
        case .pendingRequest: "This request may still be sent or applied on iPhone. Confirm local save or keep editing."
        case .savedDraft: "Your saved draft remains. Unsaved edits may be lost if you close."
        case .unsavedText: "Discard this dictated text?"
        }
    }
}

/// Keep uncertain submissions attached to their original UUID; hiding is never permission to lose dictation.
@MainActor @Observable final class WatchCaptureSession {
    let draftID: UUID
    let noteID: UUID?
    let revision: Int?
    let recoveryID: UUID?
    var text = ""
    private(set) var pendingID: UUID?
    private(set) var isProtected = false
    var notice: WatchUserNotice?
    var cancelDisposition: WatchCaptureCancelDisposition {
        if pendingID != nil { return .pendingRequest }
        if recoveryID != nil || isProtected { return .savedDraft }
        return .unsavedText
    }
    init(draftID: UUID, noteID: UUID? = nil, revision: Int? = nil, recoveryID: UUID? = nil) {
        self.draftID = draftID; self.noteID = noteID; self.revision = revision; self.recoveryID = recoveryID
    }
    func submit(actions: any WatchLibraryActions) -> Bool {
        do {
            if let pendingID { _ = try actions.confirmSubmission(id: pendingID) }
            else if recoveryID != nil || isProtected {
                try actions.saveDraft(id: draftID, text: text)
                _ = try actions.recoverDraft(id: draftID, text: text)
            } else if let noteID, let revision { _ = try actions.append(noteID: noteID, revision: revision, text: text) }
            else { _ = try actions.create(text: text) }
            text = ""; notice = nil
            return true
        } catch WatchWireError.pendingDurability(let id) {
            pendingID = id; notice = .storagePending
        } catch { notice = error as? WatchWireError == .capacity ? .queueFull : .queueFailed }
        return false
    }
    func protect(actions: any WatchLibraryActions) -> Bool {
        isProtected = true
        guard !text.isEmpty else { return true }
        do {
            if let pendingID { _ = try actions.confirmSubmission(id: pendingID) }
            else { try actions.saveDraft(id: draftID, text: text) }
            text = ""; notice = nil
            return true
        } catch { notice = pendingID == nil ? .draftSaveFailed : .storagePending }
        return false
    }
}
