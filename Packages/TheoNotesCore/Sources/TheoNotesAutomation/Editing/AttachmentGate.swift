// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation

/// The attachment-removal safety gate of `edit` and `overwrite` (`--force`) and of `edit_note` and
/// `overwrite_note` (`expectedRemovedAttachments`). Tag changes are not gated.
enum AttachmentGate {
    /// Files `before` links that `after` no longer links, in their first-link order, spelled as in
    /// `before`. Links are compared with `AttachmentFiles.fileSystemKey`, the key the attachment
    /// store uses, so a link respelled in another case or normalization form still counts as kept.
    static func removed(before: String, after: String) -> [String] {
        let kept = Set(NoteParser.metadata(for: after).attachments.map { AttachmentFiles.fileSystemKey($0.filename) })
        var seen = Set<String>()
        var result: [String] = []
        for ref in NoteParser.metadata(for: before).attachments {
            let key = AttachmentFiles.fileSystemKey(ref.filename)
            guard !kept.contains(key), seen.insert(key).inserted else { continue }
            result.append(ref.filename)
        }
        return result
    }

    static func checkCLI(removed: [String], force: Bool) throws(AutomationError) {
        guard !removed.isEmpty, !force else { return }
        throw failure(removed, remedy: "Pass --force to confirm.")
    }

    /// Passes only when the declared set equals the removed set (compared by file-system key), so
    /// an omitted declaration rejects any removal and a declaration rejects a write that removes
    /// something else or nothing.
    static func checkMCP(removed: [String], expected: [String]?) throws(AutomationError) {
        let declared = Set((expected ?? []).map(AttachmentFiles.fileSystemKey))
        guard declared != Set(removed.map(AttachmentFiles.fileSystemKey)) else { return }
        guard !removed.isEmpty else {
            throw AutomationError(
                code: .attachmentsRemoved,
                message: "No attachment would be dropped, but expectedRemovedAttachments names: "
                    + (expected ?? []).joined(separator: ", ") + ".",
                details: .object([("removed", .array([]))]))
        }
        throw failure(removed, remedy: "List them in expectedRemovedAttachments to confirm.")
    }

    private static func failure(_ removed: [String], remedy: String) -> AutomationError {
        AutomationError(
            code: .attachmentsRemoved,
            message: "Attachments would be dropped: \(removed.joined(separator: ", ")). \(remedy)",
            details: .object([("removed", .array(removed.map { .string($0) }))]))
    }
}
