// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Testing
@testable import TheoNotes

@MainActor
@Suite struct NoteTypeSidebarTests {
    @Test func sidebarOrderMatchesSpec() {
        #expect(SidebarView.fixedScopes == [
            .notes, .inbox, .type(.idea), .type(.log), .type(.reference),
            .pinned, .untagged, .todo, .today, .locked, .archive, .trash,
        ])
    }

    @Test func displayNamesAndIcons() {
        let expected: [(SidebarScope, String, String)] = [
            (.inbox, "Inbox", "tray"),
            (.type(.idea), "Ideas", "lightbulb"),
            (.type(.log), "Logs", "clock"),
            (.type(.reference), "References", "bookmark"),
        ]
        for (scope, name, icon) in expected {
            #expect(scope.displayName == name)
            #expect(scope.systemImage == icon)
        }
    }

    @Test func countsFollowTheScope() {
        let counts = SidebarCounts(notes: 9, inbox: 1, ideas: 2, logs: 3, references: 4)
        #expect(SidebarView.count(for: .inbox, in: counts) == 1)
        #expect(SidebarView.count(for: .type(.idea), in: counts) == 2)
        #expect(SidebarView.count(for: .type(.log), in: counts) == 3)
        #expect(SidebarView.count(for: .type(.reference), in: counts) == 4)
        #expect(SidebarView.count(for: .notes, in: counts) == 9)
    }

    @Test func workspaceOnReservedTagIsRefused() throws {
        let env = try LibraryModelTests.Env()
        for path in ["idea", "Log", "ref"] {
            #expect(env.model.enterWorkspace(path) == false)
            #expect(env.model.workspace == nil)
            guard case .tagOperationFailed(let message)? = env.model.banner else {
                Issue.record("no failure banner for \(path): \(String(describing: env.model.banner))")
                continue
            }
            #expect(message.contains("reserved for note types"))
            env.model.dismissBanner()
        }
        #expect(env.model.enterWorkspace("ref/recipes"))
        #expect(env.model.workspace == Workspace(path: "ref/recipes"))
    }

    @Test func rowLabelNamesTheType() {
        #expect(NoteRow.typeLabel(for: .idea) == "Type: Idea")
        #expect(NoteRow.typeLabel(for: .reference) == "Type: Reference")
    }
}
