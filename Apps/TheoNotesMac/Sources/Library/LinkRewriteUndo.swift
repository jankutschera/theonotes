// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation

/// The link-rewrite steps main windows and note windows share: linking an Info panel mention,
/// undoing/redoing a rewrite, and its undo step. Whether a banner shows is up to the caller (a
/// main window posts one and takes it down on undo; a note window has none).
@MainActor
enum LinkRewriteUndo {
    /// Links one unlinked mention: every open session is flushed first, a note whose session
    /// still holds unsaved text is refused (`.stale`), and open sessions adopt the rewrite right
    /// away, before an editor can send edits on the old revision.
    static func linkMention(_ mention: Mention, to targetId: String, in environment: AppEnvironment) throws -> LinkRewriteResult {
        environment.flushAll()
        guard !environment.unsavedNoteIds.contains(mention.noteId) else { throw MentionLinkError.stale }
        let result = try environment.store.linkMention(mention, to: targetId)
        environment.databaseDidChange()
        return result
    }

    /// Restores the texts from before (`redo` false) or after a rewrite, only in notes still at the
    /// expected text; open sessions adopt it.
    static func restore(_ result: LinkRewriteResult, redo: Bool, in environment: AppEnvironment) {
        environment.flushAll()
        do {
            let restored = redo ? try environment.store.redoLinkRewrite(result) : try environment.store.undoLinkRewrite(result)
            if restored.count < result.changedNoteIds.count {
                appLogger.notice("\(redo ? "redo" : "undo", privacy: .public) link rewrite: \(result.changedNoteIds.count - restored.count) notes edited since were kept")
            }
        } catch {
            appLogger.error("\(redo ? "redo" : "undo", privacy: .public) link rewrite failed: \(error)")
        }
        environment.databaseDidChange()
    }

    /// One `actionName` step on `undoManager` for `target` (a group is opened when none is, e.g.
    /// after a timer): undoing restores the old texts and registers the redo, which registers the
    /// undo again. `didUndo` runs after the first undo (a banner goes away), `didRestore` after
    /// every undo and redo. The undo manager does not retain `target`: each handler holds it.
    static func register(
        _ result: LinkRewriteResult, actionName: String, target: AnyObject, on undoManager: UndoManager,
        in environment: AppEnvironment, didUndo: (@MainActor () -> Void)? = nil,
        didRestore: @escaping @MainActor () -> Void = {}
    ) {
        let opensGroup = undoManager.groupingLevel == 0
        if opensGroup { undoManager.beginUndoGrouping() }
        defer { if opensGroup { undoManager.endUndoGrouping() } }
        undoManager.registerUndo(withTarget: target) { [weak undoManager, weak environment, target] _ in
            MainActor.assumeIsolated {
                guard let environment else { return }
                didUndo?()
                restore(result, redo: false, in: environment)
                didRestore()
                guard let undoManager else { return }
                undoManager.registerUndo(withTarget: target) { [weak undoManager, weak environment, target] _ in
                    MainActor.assumeIsolated {
                        guard let environment, let undoManager else { return }
                        restore(result, redo: true, in: environment)
                        didRestore()
                        register(result, actionName: actionName, target: target, on: undoManager,
                                 in: environment, didRestore: didRestore)
                    }
                }
                undoManager.setActionName(actionName)
            }
        }
        undoManager.setActionName(actionName)
    }
}
