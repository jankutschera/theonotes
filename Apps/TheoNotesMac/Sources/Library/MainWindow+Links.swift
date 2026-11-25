// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation

extension MainWindowState {
    /// Installs this window's side of the link router: a linked note is revealed in the list
    /// (switching to the section holding it) and shown in the editor; tags select the sidebar tag.
    func installLinkNavigation() {
        links.shownNoteId = { [weak self] in self?.model.focusedNoteID }
        links.showNote = { [weak self] noteId, caret in
            guard let self else { return false }
            self.model.refresh()
            self.model.reveal(noteId: noteId)
            guard self.model.focusedNoteID == noteId else { return false }
            do {
                // Right away, so a heading scroll is delivered after this note's loadNote.
                try self.editor.open(noteId: noteId, caret: caret)
                return true
            } catch {
                appLogger.error("could not open note \(noteId, privacy: .public): \(error)")
                return false
            }
        }
        links.selectTag = { [weak self] in self?.model.selectTag(named: $0) ?? false }
        links.workspace = { [weak self] in self?.model.workspace }
    }
}

extension LibraryModel {
    /// The sidebar tag `name` (any spelling) as the tag tree spells it, nil when there is none.
    func tagPath(named name: String) -> String? {
        refresh()
        let key = CanonicalKey.make(name)
        func find(_ nodes: [TagNode]) -> String? {
            for node in nodes {
                if CanonicalKey.make(node.path) == key { return node.path }
                if let path = find(node.children) { return path }
            }
            return nil
        }
        return find(tagTree)
    }

    /// Selects the sidebar tag `name` (any spelling) as the scope; false when there is none.
    @discardableResult
    func selectTag(named name: String) -> Bool {
        guard let path = tagPath(named: name) else { return false }
        selectScope(.tag(path))
        return true
    }

    /// Makes the sidebar tag `name` (any spelling) the window's workspace; false when there is none or it marks a note type.
    @discardableResult
    func enterWorkspace(named name: String) -> Bool {
        guard let path = tagPath(named: name) else { return false }
        return enterWorkspace(path)
    }
}
