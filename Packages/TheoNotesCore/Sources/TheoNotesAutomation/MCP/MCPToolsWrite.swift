// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation

/// The tools that change a note. The result of each is what changed, so a caller can catch an
/// unintended change (a dropped tag); never the note text, which the caller already holds.
extension MCPTools {
    // MARK: create_note, create_note_from_template, capture_thought

    func createNote(_ a: MCPArguments) throws(AutomationError) -> JSONValue {
        let title = try a.string("title")
        let content = try a.string("content") ?? ""
        let ifNotExists = try a.bool("ifNotExists") ?? false
        let tags = try a.strings("tags") ?? []
        try AutomationService.validateCreate(title: title, content: content, ifNotExists: ifNotExists, template: nil)
        for tag in tags { _ = try TagArgument.name(tag) }
        let record = try makeService().create(
            title: title, content: content, tags: tags, ifNotExists: ifNotExists, template: nil)
        return Self.flat(record)
    }

    func createNoteFromTemplate(_ a: MCPArguments) throws(AutomationError) -> JSONValue {
        guard let template = try a.string("template") else {
            throw AutomationError(code: .usage, message: "missing required field: template")
        }
        let title = try a.string("title")
        let tags = try a.strings("tags") ?? []
        for tag in tags { _ = try TagArgument.name(tag) }
        let record = try makeService().create(
            title: title, content: "", tags: tags, ifNotExists: false, template: template)
        return Self.flat(record)
    }

    /// `capture_thought` (FOC-R14): the text, stored as given. Same result shape as `create_note`.
    func captureThought(_ a: MCPArguments) throws(AutomationError) -> JSONValue {
        guard let text = try a.string("text") else {
            throw AutomationError(code: .usage, message: "missing required field: text")
        }
        try AutomationService.validateCapture(text: text)
        return Self.flat(try makeService().capture(text: text))
    }

    // MARK: append_to_note, overwrite_note, edit_note

    func appendToNote(_ a: MCPArguments) throws(AutomationError) -> JSONValue {
        let selector = try noteSelector(a)
        let position = try Self.position(try a.string("position"))
        guard let content = try a.string("content") else {
            throw AutomationError(code: .usage, message: "missing required field: content")
        }
        let address = try a.string("address")
        let (result, section) = try makeService().append(
            selector, content: content, position: position, address: address, preservingModifiedDate: false)
        return Self.written(result, section: section)
    }

    private static func position(_ raw: String?) throws(AutomationError) -> AppendPosition {
        guard let raw else { return .end }
        guard let position = AppendPosition(rawValue: raw) else {
            throw AutomationError(code: .usage, message: "Invalid position: \(raw) (use beginning or end)")
        }
        return position
    }

    func overwriteNote(_ a: MCPArguments) throws(AutomationError) -> JSONValue {
        let selector = try noteSelector(a)
        guard let content = try a.string("content") else {
            throw AutomationError(code: .usage, message: "missing required field: content")
        }
        guard let baseHash = try a.string("baseHash") else {
            throw AutomationError(code: .usage, message: "missing required field: baseHash")
        }
        let address = try a.string("address")
        let expected = try a.strings("expectedRemovedAttachments")
        let (result, section) = try makeService().overwrite(
            selector, content: content, base: baseHash, address: address, gate: .mcp(expected: expected),
            preservingModifiedDate: false)
        return Self.written(result, section: section)
    }

    func editNote(_ a: MCPArguments) throws(AutomationError) -> JSONValue {
        let selector = try noteSelector(a)
        let edits = try Self.editSpecs(a)
        let address = try a.string("address")
        let expected = try a.strings("expectedRemovedAttachments")
        let (result, ops) = try makeService().edit(
            selector, edits: edits, address: address, gate: .mcp(expected: expected), preservingModifiedDate: false)
        let landed = ops.map { op -> JSONValue in
            var fields: [(String, JSONValue)] = [("index", .int(op.index))]
            if let section = op.section { fields.append(("section", Self.sectionObject(section))) }
            return .object(fields)
        }
        return .object([
            ("changedMetadata", ChangedMetadata.diff(result.before, result.after)), ("ops", .array(landed)),
        ])
    }

    /// `edits`: each has `find` and exactly one of `replace`, `insertAfter`, `insertBefore` or
    /// `delete: true`; `delete: false` is no deletion. An empty list is `usage` (ruling M5-R93).
    private static func editSpecs(_ a: MCPArguments) throws(AutomationError) -> [EditSpec] {
        let items = try a.objects("edits") ?? []
        guard !items.isEmpty else { throw AutomationError(code: .usage, message: "At least one edit is required") }
        var specs: [EditSpec] = []
        for (index, item) in items.enumerated() {
            try item.require(["find"])
            guard let find = try item.string("find") else { continue }
            var actions: [EditAction] = []
            if let text = try item.string("replace") { actions.append(.replace(text)) }
            if let text = try item.string("insertAfter") { actions.append(.insertAfter(text)) }
            if let text = try item.string("insertBefore") { actions.append(.insertBefore(text)) }
            if try item.bool("delete") == true { actions.append(.delete) }
            guard actions.count == 1, let action = actions.first else {
                throw AutomationError(
                    code: .usage,
                    message: "edits[\(index)] needs exactly one of replace, insertAfter, insertBefore or delete")
            }
            specs.append(
                EditSpec(
                    find: find, action: action, all: try item.bool("all") ?? false,
                    ignoreCase: try item.bool("ignoreCase") ?? false, word: try item.bool("word") ?? false))
        }
        return specs
    }

    /// `{"changedMetadata", "section"?}` of `append_to_note` and `overwrite_note`.
    private static func written(_ result: MutationResult, section: OutlineEntry?) -> JSONValue {
        var fields: [(String, JSONValue)] = [("changedMetadata", ChangedMetadata.diff(result.before, result.after))]
        if let section { fields.append(("section", sectionObject(section))) }
        return .object(fields)
    }

    // MARK: pins, location, tags

    func changePins(_ a: MCPArguments, pinned: Bool) throws(AutomationError) -> JSONValue {
        let selector = try noteSelector(a)
        let targets = try a.strings("targets") ?? []
        guard !targets.isEmpty else {
            throw AutomationError(code: .usage, message: "At least one pin target is required")
        }
        let service = try makeService()
        let result = pinned ? try service.addPins(selector, targets: targets) : try service.removePins(selector, targets: targets)
        return ChangedMetadata.diff(result.before, result.after)
    }

    func moveNote(
        _ a: MCPArguments, _ move: (AutomationService, NoteSelector) throws(AutomationError) -> MutationResult
    ) throws(AutomationError) -> JSONValue {
        let selector = try noteSelector(a)
        let result = try move(try makeService(), selector)
        return ChangedMetadata.diff(result.before, result.after)
    }

    func changeTags(_ a: MCPArguments, add: Bool) throws(AutomationError) -> JSONValue {
        let selector = try noteSelector(a)
        let tags = try a.strings("tags") ?? []
        guard !tags.isEmpty else { throw AutomationError(code: .usage, message: "At least one tag is required") }
        for tag in tags { _ = try TagArgument.name(tag) }
        let service = try makeService()
        let result = add ? try service.addTags(selector, tags: tags) : try service.removeTags(selector, tags: tags)
        return ChangedMetadata.diff(result.before, result.after)
    }

    func renameTag(_ a: MCPArguments) throws(AutomationError) -> JSONValue {
        guard let old = try a.string("old") else {
            throw AutomationError(code: .usage, message: "missing required field: old")
        }
        guard let new = try a.string("new") else {
            throw AutomationError(code: .usage, message: "missing required field: new")
        }
        let force = try a.bool("force") ?? false
        _ = try AutomationService.validateRename(old: old, new: new)
        return .object([("notesUpdated", .int(try makeService().renameTag(old: old, new: new, force: force)))])
    }

    func deleteTag(_ a: MCPArguments) throws(AutomationError) -> JSONValue {
        guard let tag = try a.string("tag") else {
            throw AutomationError(code: .usage, message: "missing required field: tag")
        }
        _ = try TagArgument.name(tag)
        return .object([("notesUpdated", .int(try makeService().deleteTag(tag)))])
    }

    // MARK: attachments

    func addAttachmentFromURL(_ a: MCPArguments) async throws(AutomationError) -> JSONValue {
        let selector = try noteSelector(a)
        guard let raw = try a.string("url"), !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AutomationError(code: .usage, message: "missing required field: url")
        }
        let url = try URLFetchPolicy.parse(raw)
        let filename = try a.string("filename").flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        let service = try makeService()
        // Awaited directly: the fetcher is async and bounded (30 s total, 15 s without data).
        let (result, _) = try await service.addAttachment(
            selector, url: url, filename: filename, preservingModifiedDate: false)
        return ChangedMetadata.diff(result.before, result.after)
    }

    func deleteAttachment(_ a: MCPArguments) throws(AutomationError) -> JSONValue {
        let selector = try noteSelector(a)
        guard let filename = try a.string("filename"),
            !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw AutomationError(code: .usage, message: "missing required field: filename")
        }
        let result = try makeService().deleteAttachment(selector, filename: filename, preservingModifiedDate: false)
        return ChangedMetadata.diff(result.before, result.after)
    }
}
