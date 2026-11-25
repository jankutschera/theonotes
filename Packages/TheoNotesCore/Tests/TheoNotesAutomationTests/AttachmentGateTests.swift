// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesAutomation

/// The attachment-removal gate and the `changedMetadata` diff of the write commands.
@Suite struct AttachmentGateTests {
    @Test func gateRemovedAndCliMcpRules() throws {
        let before = "![](a.jpg)\n[b.pdf](b.pdf)<!-- {\"embed\":\"true\"} -->\n"
        #expect(AttachmentGate.removed(before: before, after: "![](a.jpg)\n") == ["b.pdf"])
        #expect(throws: AutomationError.self) { try AttachmentGate.checkCLI(removed: ["b.pdf"], force: false) }
        try AttachmentGate.checkCLI(removed: ["b.pdf"], force: true)
        try AttachmentGate.checkMCP(removed: ["b.pdf"], expected: ["b.pdf"])
        #expect(throws: AutomationError.self) { try AttachmentGate.checkMCP(removed: [], expected: ["b.pdf"]) }
    }

    @Test func removedKeepsFirstLinkOrderAndIgnoresRespelledOrMovedLinks() {
        let before = "![](a.jpg)\n![](b.png)\n![](a.jpg)\n![](c.png)\n"
        #expect(AttachmentGate.removed(before: before, after: "") == ["a.jpg", "b.png", "c.png"])
        #expect(AttachmentGate.removed(before: before, after: "![](c.png) ![](B.PNG) ![](a.jpg)") == [])
        #expect(AttachmentGate.removed(before: "# T\nno links", after: "") == [])
        // Added links are not the gate's business.
        #expect(AttachmentGate.removed(before: "", after: "![](new.jpg)") == [])
    }

    @Test func messagesAndDetails() {
        do {
            try AttachmentGate.checkCLI(removed: ["a.jpg", "b.pdf"], force: false)
            Issue.record("expected attachments_removed")
        } catch {
            #expect(error.code == .attachmentsRemoved && error.exitCode == 1)
            #expect(
                error.message == "Attachments would be dropped: a.jpg, b.pdf. Pass --force to confirm.")
            #expect(error.details == .object([("removed", .array(["a.jpg", "b.pdf"]))]))
        }
        do {
            try AttachmentGate.checkMCP(removed: ["a.jpg", "b.pdf"], expected: ["a.jpg"])
            Issue.record("expected attachments_removed")
        } catch {
            #expect(
                error.message
                    == "Attachments would be dropped: a.jpg, b.pdf. List them in expectedRemovedAttachments to confirm.")
            #expect(error.details == .object([("removed", .array(["a.jpg", "b.pdf"]))]))
        }
        #expect(throws: AutomationError.self) { try AttachmentGate.checkMCP(removed: ["a.jpg"], expected: nil) }
        #expect(throws: AutomationError.self) { try AttachmentGate.checkMCP(removed: ["a.jpg"], expected: []) }
    }

    @Test func gatePassesWithoutRemovals() throws {
        try AttachmentGate.checkCLI(removed: [], force: false)
        try AttachmentGate.checkMCP(removed: [], expected: nil)
        try AttachmentGate.checkMCP(removed: [], expected: [])
        try AttachmentGate.checkMCP(removed: ["b.pdf", "a.jpg"], expected: ["a.jpg", "b.pdf", "a.jpg"])
    }

    @Test func changedMetadataIsSparseAndNeverContent() {
        let before = NoteRecord(
            id: "N1", title: "Old", locked: false, tags: ["a"], length: 10, created: Date(timeIntervalSince1970: 0),
            modified: Date(timeIntervalSince1970: 60), pins: [.global], location: .notes, todos: 1, done: 0,
            attachments: ["x.jpg"], content: "# Old\n#a")
        var after = before
        after.title = "New"
        after.tags = ["a", "b"]
        after.content = "# New\n#a #b"
        #expect(
            ChangedMetadata.diff(before, after)
                == .object([("tags", .array(["a", "b"])), ("title", .string("New"))]))
        #expect(ChangedMetadata.diff(before, before) == .object([]))
        after.length = 14
        after.modified = Date(timeIntervalSince1970: 120)
        let diff = ChangedMetadata.diff(before, after)
        #expect(diff.keys == ["length", "modified", "tags", "title"] && diff["content"] == nil)
    }
}
