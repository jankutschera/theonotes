// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import TheoNotesCore

/// One registry per shared MobileLibrary. Scene navigation and WKWebViews remain scene-owned.
/// The host applies privacy transitions only when aggregate activity becomes inactive.
@MainActor final class MobileSceneRegistry {
    enum Activity { case active, inactive, background }
    struct ActivityChange {
        let wasActive: Bool
        let isActive: Bool
        var becameInactive: Bool { wasActive && !isActive }
    }
    private final class Entry {
        weak var editor: MobileEditor?
        var activity: Activity
        init(editor: MobileEditor, activity: Activity) { self.editor = editor; self.activity = activity }
    }
    private struct Snapshot {
        let sceneID: UUID
        let editor: MobileEditor
        let session: NoteSession?
        let load: Int
        let page: ObjectIdentifier
    }
    /// Keep this lease across the complete library operation; always release in defer.
    /// It owns frozen editors strongly until release, while normal registration is weak.
    @MainActor final class FreezeLease {
        private var end: (() -> Void)?
        private let check: () throws -> Void
        private let detach: () throws -> Void
        fileprivate init(check: @escaping () throws -> Void, detach: @escaping () throws -> Void,
                         end: @escaping () -> Void) {
            self.check = check; self.detach = detach; self.end = end
        }
        isolated deinit { end?() }
        func validate() throws {
            guard end != nil else { throw MobileEditorDrainError.busy }
            try check()
        }
        /// For a shared library switch/privacy teardown: first flush EVERY session,
        /// then detach each view. The caller still owns closing/stopping the library once.
        func detachEditors() throws { try validate(); try detach() }
        func release() { let pending = end; end = nil; pending?() }
    }
    private var entries: [UUID: Entry] = [:]
    private var operation: UUID?
    private var generation = 0
    private func prune() { entries = entries.filter { $0.value.editor != nil } }
    var sceneCount: Int { prune(); return entries.count }
    var hasActiveScenes: Bool { prune(); return entries.values.contains { $0.activity == .active } }

    func register(sceneID: UUID, editor: MobileEditor, activity: Activity) throws {
        guard operation == nil else { throw MobileEditorDrainError.busy }
        prune()
        guard !entries.contains(where: { $0.key != sceneID && $0.value.editor === editor }) else { throw MobileEditorDrainError.busy }
        if let old = entries[sceneID] {
            // Replacing an attached editor without first detaching would lose its listener.
            guard old.editor === editor else { throw MobileEditorDrainError.busy }
            old.activity = activity
        } else { entries[sceneID] = Entry(editor: editor, activity: activity); generation &+= 1 }
    }
    /// Synchronous adoption is allowed only after the old page explicitly completed
    /// privacy teardown, never merely because its loading page is not ready yet.
    func replaceClosedEditor(sceneID: UUID, editor: MobileEditor) throws {
        guard operation == nil, let entry = entries[sceneID] else { throw MobileEditorDrainError.busy }
        if entry.editor === editor { return }
        guard let old = entry.editor, old.isClosedForPrivacy, old.session == nil, !old.ready,
              !entries.contains(where: { $0.key != sceneID && $0.value.editor === editor }) else { throw MobileEditorDrainError.busy }
        entry.editor = editor; generation &+= 1
    }
    @discardableResult func updateActivity(sceneID: UUID, activity: Activity) -> ActivityChange {
        let was = hasActiveScenes
        entries[sceneID]?.activity = activity
        return ActivityChange(wasActive: was, isActive: hasActiveScenes)
    }
    private func snapshot() -> [Snapshot] {
        prune()
        return entries.sorted { $0.key.uuidString < $1.key.uuidString }.compactMap { id, entry in
            guard let editor = entry.editor else { return nil }
            return Snapshot(sceneID: id, editor: editor, session: editor.session,
                load: editor.documentLoadGeneration, page: ObjectIdentifier(editor.webView))
        }
    }
    private func validate(_ snapshots: [Snapshot], generation expected: Int, operation token: UUID, only sceneID: UUID? = nil) throws {
        guard operation == token, generation == expected else { throw MobileEditorDrainError.busy }
        prune()
        if let sceneID {
            guard snapshots.count == 1, snapshots[0].sceneID == sceneID, entries[sceneID] != nil else { throw MobileEditorDrainError.busy }
        } else {
            guard entries.count == snapshots.count else { throw MobileEditorDrainError.busy }
        }
        for value in snapshots {
            guard entries[value.sceneID]?.editor === value.editor,
                  value.editor.session === value.session,
                  value.editor.documentLoadGeneration == value.load,
                  ObjectIdentifier(value.editor.webView) == value.page else { throw MobileEditorDrainError.busy }
        }
    }
    func freezeAll(deadline: Date? = nil, confirmedResetInvalidatedIDs: Set<String> = []) async throws -> FreezeLease {
        try await freeze(only: nil, deadline: deadline, confirmedResetInvalidatedIDs: confirmedResetInvalidatedIDs)
    }
    private func freeze(only sceneID: UUID?, deadline: Date? = nil, confirmedResetInvalidatedIDs: Set<String> = []) async throws -> FreezeLease {
        try Task.checkCancellation()
        if let deadline, deadline <= Date() { throw MobileEditorDrainError.timeout }
        guard operation == nil else { throw MobileEditorDrainError.busy }
        let token = UUID(); operation = token
        let snapshots = snapshot().filter { sceneID == nil || $0.sceneID == sceneID }, expected = generation
        var frozen: [(MobileEditor, FrozenForClose)] = []
        do {
            for value in snapshots where sceneID == nil || value.sceneID == sceneID {
                try Task.checkCancellation()
                if let deadline, deadline <= Date() { throw MobileEditorDrainError.timeout }
                guard let session = value.session else { continue }
                if session.isInvalidated && confirmedResetInvalidatedIDs.contains(session.noteId) { continue }
                if !value.editor.ready {
                    try value.editor.drainUnreadyNativeSession()
                    continue
                }
                let reply = try await value.editor.prepareCaptureClose(session.noteId, waitForBusyUntil: deadline)
                frozen.append((value.editor, reply))
                try Task.checkCancellation()
                try validate(snapshots, generation: expected, operation: token, only: sceneID)
            }
            if let deadline, deadline <= Date() { throw MobileEditorDrainError.timeout }
            try validate(snapshots, generation: expected, operation: token, only: sceneID)
            let held = frozen
            return FreezeLease(check: { [self] in
                try validate(snapshots, generation: expected, operation: token, only: sceneID)
            }, detach: {
                for value in snapshots {
                    if let session = value.session, session.isInvalidated, confirmedResetInvalidatedIDs.contains(session.noteId) { continue }
                    try value.session?.flush()
                }
                for value in snapshots {
                    let allowedID = value.session.flatMap { $0.isInvalidated && confirmedResetInvalidatedIDs.contains($0.noteId) ? $0.noteId : nil }
                    try value.editor.closeForPrivacy(confirmedResetInvalidatedID: allowedID)
                }
            }, end: { [self] in
                for (editor, reply) in held.reversed() { editor.endCaptureClose(reply) }
                if operation == token { operation = nil }
            })
        } catch {
            for (editor, reply) in frozen.reversed() { editor.endCaptureClose(reply) }
            if operation == token { operation = nil }
            throw error
        }
    }
    /// Only this scene's editor is detached. Its shared cached session and sync remain alive.
    @discardableResult func detach(sceneID: UUID) async throws -> ActivityChange {
        let was = hasActiveScenes
        guard let editor = entries[sceneID]?.editor else {
            return ActivityChange(wasActive: was, isActive: hasActiveScenes)
        }
        let lease = try await freeze(only: sceneID)
        defer { lease.release() }
        try lease.validate()
        // closeForPrivacy flushes and removes only this editor's listener/retention lease.
        // It neither revokes library.privateAccess nor removes the shared session cache.
        try editor.closeForPrivacy()
        entries.removeValue(forKey: sceneID); generation &+= 1
        return ActivityChange(wasActive: was, isActive: hasActiveScenes)
    }
}
