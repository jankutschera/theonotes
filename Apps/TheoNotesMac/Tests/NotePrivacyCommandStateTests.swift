// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Testing
@testable import TheoNotes

/// M9 Mac task 5: which privacy commands a selection enables (Note menu, note-list context menu).
@MainActor
@Suite struct NotePrivacyCommandStateTests {
    private func item(_ id: String, locked: Bool = false, readOnly: Bool = false) -> NoteListItem {
        NoteListItem(
            id: id, title: id, subtitle: locked ? "" : "preview", modifiedAt: .now, createdAt: .now, isPinned: false,
            isLocked: locked, isReadOnly: readOnly, hasAttachments: false, firstImageFilename: nil)
    }

    private func state(
        _ items: [NoteListItem], selected: Set<String>, scope: SidebarScope = .notes,
        hasPassword: Bool = true, unlocked: Bool = true
    ) -> NoteCommandState {
        NoteCommandState(
            scope: scope, items: items, selectedNoteIDs: selected, counts: SidebarCounts(),
            privacy: .init(hasPassword: hasPassword, isUnlocked: unlocked))
    }

    @Test func noSelectionOffersNeitherLockNorRemoveLock() {
        let s = state([item("a")], selected: [])
        #expect(!s.canLockNote && !s.canRemoveLock)
    }

    @Test func anUnlockedNoteCanBeLockedButNotUnlocked() {
        let s = state([item("a")], selected: ["a"])
        #expect(s.canLockNote)
        #expect(!s.canRemoveLock)
    }

    @Test func aLockedNoteCanLoseItsLockButNotBeLockedAgain() {
        let s = state([item("a", locked: true)], selected: ["a"])
        #expect(s.canRemoveLock)
        #expect(!s.canLockNote)
    }

    @Test func aMixedSelectionLocksTheUnlockedOnesButRemovesNothing() {
        let s = state([item("a"), item("b", locked: true)], selected: ["a", "b"])
        #expect(s.canLockNote)
        #expect(!s.canRemoveLock)
    }

    @Test func removeLockIsForExactlyOneNote() {
        let items = [item("a", locked: true), item("b", locked: true)]
        #expect(state(items, selected: ["a"]).canRemoveLock)
        #expect(!state(items, selected: ["a", "b"]).canRemoveLock)
        #expect(!state(items, selected: ["a", "b"]).canLockNote)
    }

    @Test func manyUnlockedNotesCanBeLockedTogether() {
        let s = state([item("a"), item("b"), item("c")], selected: ["a", "b", "c"])
        #expect(s.canLockNote)
    }

    @Test func theTrashOffersNeitherLockNorRemoveLock() {
        let items = [item("a"), item("b", locked: true)]
        #expect(!state(items, selected: ["a"], scope: .trash).canLockNote)
        #expect(!state(items, selected: ["b"], scope: .trash).canRemoveLock)
    }

    @Test func theArchiveOffersBoth() {
        let items = [item("a"), item("b", locked: true)]
        #expect(state(items, selected: ["a"], scope: .archive).canLockNote)
        #expect(state(items, selected: ["b"], scope: .archive).canRemoveLock)
    }

    @Test func aReadOnlyNoteCanBeLockedAndUnlocked() {
        let items = [item("a", readOnly: true), item("b", locked: true, readOnly: true)]
        #expect(state(items, selected: ["a"]).canLockNote)
        #expect(state(items, selected: ["b"]).canRemoveLock)
    }

    @Test func lockingIsOfferedBeforeAnyPasswordExists() {
        let s = state([item("a")], selected: ["a"], hasPassword: false, unlocked: false)
        #expect(s.canLockNote)
    }

    @Test func removeLockIsOfferedWhileTheVaultIsLockedThePasswordPromptComesFirst() {
        let s = state([item("a", locked: true)], selected: ["a"], unlocked: false)
        #expect(s.canRemoveLock)
    }

    @Test func changePasswordNeedsAPasswordNotASelection() {
        #expect(state([], selected: [], hasPassword: true).canChangePassword)
        #expect(!state([], selected: [], hasPassword: false, unlocked: false).canChangePassword)
    }

    @Test func lockNowNeedsAnUnlockedVault() {
        #expect(state([], selected: [], unlocked: true).canLockNow)
        #expect(!state([], selected: [], unlocked: false).canLockNow)
    }

    @Test func onlyListedNotesCount() {
        let s = state([item("a", locked: true)], selected: ["a", "gone"])
        #expect(s.canRemoveLock)
    }

    @Test func duplicateIsHiddenWhenAnyChosenNoteIsLocked() {
        let items = [item("a"), item("b", locked: true)]
        #expect(state(items, selected: ["a"]).canDuplicate)
        #expect(!state(items, selected: ["b"]).canDuplicate)
        #expect(!state(items, selected: ["a", "b"]).canDuplicate)
    }

    @Test func remindMeNeedsOneNoteOutsideTheTrashAndAcceptsALockedOne() {
        let items = [item("a"), item("b", locked: true)]
        #expect(state(items, selected: ["a"]).canRemind)
        #expect(state(items, selected: ["b"]).canRemind, "a locked note takes a whole-note reminder")
        #expect(!state(items, selected: ["a", "b"]).canRemind)
        #expect(!state(items, selected: []).canRemind)
        #expect(!state(items, selected: ["a"], scope: .trash).canRemind)
    }

    @Test func remindMeIsOffWithoutAnApp() {
        let on = state([item("a")], selected: ["a"])
        #expect(RemindMeMenu.isDisabled(app: nil, hasMainWindow: true, hasNoteWindow: false, state: on))
    }

    @Test func pinArchiveAndTrashStayAvailableForLockedNotes() {
        let s = state([item("a", locked: true)], selected: ["a"])
        #expect(s.canPin && s.canArchive && s.canTrash)
        let trashed = state([item("a", locked: true)], selected: ["a"], scope: .trash)
        #expect(trashed.canRestore && trashed.canDeletePermanently)
    }

    @Test func menuTitlesAreStable() {
        #expect(NotePrivacyMenu.submenu == "Privacy")
        #expect(NotePrivacyMenu.lockNote == "Lock Note")
        #expect(NotePrivacyMenu.removeLock == "Remove Lock from Note")
        #expect(NotePrivacyMenu.changePassword == "Change Password…")
        #expect(NotePrivacyMenu.lockNow == "Lock Now")
    }
}
