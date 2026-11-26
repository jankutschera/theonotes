// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation

/// `app_open_note` and `app_get_selection`: the tools that need the running app. Arguments are
/// checked first, the library is opened afterwards, as everywhere in `MCPTools`.
extension MCPTools {
    func appOpenNote(_ a: MCPArguments) throws(AutomationError) -> JSONValue {
        let selector = try noteSelector(a)
        let header = try a.string("header")
        let edit = try a.bool("edit") ?? false
        let newWindow = try a.bool("newWindow") ?? false
        let float = try a.bool("float") ?? false
        let selectionText = try a.string("selectionText")
        let selectionOffset = try a.nonNegative("selectionOffset", "Selection offset")
        let selectionLength = try a.nonNegative("selectionLength", "Selection length")
        let request = try AppOpenRequest(
            selector: selector, header: header, edit: edit, newWindow: newWindow, float: float,
            selectionText: selectionText, selectionOffset: selectionOffset, selectionLength: selectionLength)
        let library = try openLibrary()
        let scope = scope
        try AppBridge.open(request, paths: library.paths, context: context) { () throws(AutomationError) -> Note in
            try ReadFailure.read(library) { db in try NoteResolver.resolve(selector, scope: scope, db: db) }
        }
        return .object([])
    }

    func appGetSelection(_ a: MCPArguments) throws(AutomationError) -> JSONValue {
        let includeContent = try a.bool("includeContent") ?? false
        let library = try openLibrary()
        guard let selection = try AppBridge.selection(paths: library.paths, context: context),
              let noteId = selection.noteId
        else { return .object([]) }
        let scope = scope
        let record: NoteRecord
        do throws(AutomationError) {
            record = try ReadFailure.read(library) { db -> NoteRecord in
                let note = try NoteResolver.resolve(.id(noteId), scope: scope, db: db)
                return try NoteRecord.load(note, db: db, attachments: attachments(library))
            }
        } catch {
            // A note outside this server's scope is not there as far as the caller can tell.
            if error.code == .outOfScope { return .object([]) }
            throw error
        }
        var fields: [(String, JSONValue)] = [("metadata", record.mcpMetadata())]
        // A caret has no selection to report; neither has a locked note.
        if !record.locked, let offset = selection.selectionOffset, let length = selection.selectionLength, length > 0,
           let text = selection.selectionText {
            fields.append(
                ("selection", .object([("length", .int(length)), ("offset", .int(offset)), ("text", .string(text))])))
        }
        if includeContent, let content = record.content { fields.append(("content", .string(content))) }
        return .object(fields)
    }
}
