// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Observation

struct WatchTaskTarget: Equatable, Sendable {
    let noteID: UUID
    let revision: Int
    let utf16Offset: Int
    let sourceSHA256: String
    let expectedMarker: String
}
struct WatchPresentedTask: Identifiable, Equatable, Sendable {
    var id: Int { target.utf16Offset }
    let title: String
    let isChecked: Bool
    let target: WatchTaskTarget
}
struct WatchPresentedNote: Identifiable, Equatable, Sendable {
    let id: UUID
    let revision: Int
    let title: String
    let text: String
    let tasks: [WatchPresentedTask]
}
enum WatchRefusalReason: Equatable, Sendable {
    case privacy, staleTarget, missingTarget, wrongLibrary, epochMismatch, readOnly, invalidCommand, unavailable, identifierReused, expired
    var message: String {
        switch self {
        case .privacy: "Watch access was paused to protect your notes. Check privacy settings on iPhone."
        case .staleTarget: "The note changed. Refresh before trying again."
        case .missingTarget: "This note is no longer available."
        case .wrongLibrary: "The library changed. Refresh before starting a new request."
        case .epochMismatch: "This request may already have been applied before the restore. Check iPhone before recovering the text."
        case .readOnly: "This note is read-only."
        case .invalidCommand: "This request could not be accepted."
        case .unavailable: "Open Theo Notes on iPhone, then try again."
        case .identifierReused: "This request has already been used. Start a new request."
        case .expired: "This request is over seven days old. Check iPhone: it may already have applied before recovering the text as a new note."
        }
    }
    func message(for kind: WatchPresentedOperation.Kind) -> String {
        guard self == .epochMismatch else { return message }
        if kind == .task { return "This request may already have been applied before the restore. Check the task on iPhone." }
        return "This request may already have been applied before the restore. Check iPhone before recovering this text as a new note."
    }
}
enum WatchOperationState: Equatable, Sendable {
    case queued, waitingForLibrary, waitingForStorage, expired, applied, appliedArchived, appliedTrashed, refused(WatchRefusalReason)
    var title: String {
        switch self {
        case .queued: "Queued"
        case .waitingForLibrary: "Waiting for matching library"
        case .waitingForStorage: "Waiting for local save"
        case .expired: "Expired: action needed"
        case .applied: "Applied on iPhone"
        case .appliedArchived: "Saved on iPhone (archived)"
        case .appliedTrashed: "Saved on iPhone (in Trash)"
        case .refused: "Refused"
        }
    }
}
struct WatchPresentedOperation: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case create = "New note", append = "Append", task = "Task update" }
    let id: UUID
    let kind: Kind
    let state: WatchOperationState
    var expiresAt: Date? = nil
    var deliveryDeadline: ContinuousClock.Instant? = nil
    var canRetryOriginal = false
    var canKeepDictation = false
    var absoluteExpiresAt: Date? = nil
    func effectiveState(now: Date) -> WatchOperationState {
        guard state == .queued || state == .waitingForLibrary else { return state }
        if expiresAt.map({ now >= $0 }) == true || deliveryDeadline.map({ ContinuousClock.now >= $0 }) == true { return .expired }
        return state
    }
}
struct WatchPresentedDraft: Identifiable, Equatable, Sendable { let id: UUID }
enum WatchUserNotice: Equatable {
    case queueFailed, privacy, unavailable, queueFull, clock, storagePending, draftSaveFailed
    var message: String {
        switch self {
        case .queueFailed: "Could not queue this request. Your text is still here."
        case .privacy: "Watch access was paused to protect your notes. Check privacy settings on iPhone."
        case .unavailable: "Open Theo Notes on iPhone to refresh notes."
        case .queueFull: "The request queue is full. Existing requests and text are kept."
        case .clock: "The Watch clock changed. Check date and time before retrying."
        case .storagePending: "Keep this text until local saving is confirmed. The request may still complete on iPhone."
        case .draftSaveFailed: "Could not save this draft. Keep the app open and reconnect before retrying."
        }
    }
}
enum WatchCaptureText {
    static func isValid(_ text: String) -> Bool {
        text.utf8.count <= 16_384 && !text.contains("\0") && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Adapter-owned notes must be an authorized, fresh in-memory projection; clear them on expiry,
/// disconnect, background and privacy invalidation. Never populate this model from a disk cache.
@MainActor @Observable final class WatchLibraryPresentation {
    var notes: [WatchPresentedNote] = []
    var operations: [WatchPresentedOperation] = []
    var drafts: [WatchPresentedDraft] = []
    var isReachable = false
    var isAuthorized = false
    var authorizationDeadline: ContinuousClock.Instant?
    var notice: WatchUserNotice?
    var canReadContent: Bool { isAuthorized && isReachable && authorizationDeadline.map({ ContinuousClock.now < $0 }) == true }
    var visibleNotes: [WatchPresentedNote] { canReadContent ? notes : [] }
    /// The home screen shows one notice line, the most specific one.
    var homeNotice: String? {
        if let notice { return notice.message }
        if !isReachable { return "iPhone unavailable. New notes can be queued." }
        if !isAuthorized { return "Open Theo Notes on iPhone to refresh. Watch access requires App Lock to be disabled." }
        return nil
    }
}
@MainActor protocol WatchLibraryActions: AnyObject {
    func start()
    func setForeground(_ active: Bool)
    func refresh()
    func create(text: String) throws -> UUID
    func append(noteID: UUID, revision: Int, text: String) throws -> UUID
    func setTask(_ target: WatchTaskTarget, checked: Bool) throws -> UUID
    func draftText(id: UUID) throws -> String
    func updateDraft(id: UUID, text: String) throws
    func recoverDraft(id: UUID, text: String) throws -> UUID
    func retryRequest(id: UUID) throws
    func keepDictation(id: UUID) throws
    func confirmSubmission(id: UUID) throws -> UUID
    func saveDraft(id: UUID, text: String) throws
}
