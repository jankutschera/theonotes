// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation

/// What `app open` / `app_open_note` ask the app to do, checked before anything else happens.
struct AppOpenRequest: Equatable {
    var selector: NoteSelector
    var header: String?
    var edit: Bool
    var newWindow: Bool
    var float: Bool
    var selectionText: String?
    var selectionOffset: Int?
    var selectionLength: Int?

    /// The selection options exclude each other; offsets and lengths are never negative. A length
    /// without an offset is ignored (the help says so).
    init(
        selector: NoteSelector, header: String?, edit: Bool, newWindow: Bool, float: Bool, selectionText: String?,
        selectionOffset: Int?, selectionLength: Int?
    ) throws(AutomationError) {
        if selectionText != nil, selectionOffset != nil {
            throw AutomationError(code: .usage, message: "Provide selection text or selection offset, not both")
        }
        if selectionText?.isEmpty == true {
            throw AutomationError(code: .usage, message: "Selection text must not be empty")
        }
        if let selectionOffset, selectionOffset < 0 {
            throw AutomationError(code: .usage, message: "Selection offset must be non-negative")
        }
        if let selectionLength, selectionLength < 0 {
            throw AutomationError(code: .usage, message: "Selection length must be non-negative")
        }
        self.selector = selector
        self.header = header
        self.edit = edit
        self.newWindow = newWindow
        self.float = float
        self.selectionText = selectionText
        self.selectionOffset = selectionOffset
        self.selectionLength = selectionOffset == nil ? nil : selectionLength
    }

    func params(noteId: String) -> OpenParams {
        OpenParams(
            noteId: noteId, header: header, edit: edit, newWindow: newWindow, float: float,
            selectionText: selectionText, selectionOffset: selectionOffset, selectionLength: selectionLength)
    }

    /// `theonotes://x-callback-url/open-note?…`, what starts the app when it is not running (ruling
    /// M5-R17). The note is named by its resolved id, never by the caller's raw id or title, so the
    /// caller's scope has already been applied (ruling M5-R190); the selection options ride along as
    /// `selection_text`, `selection_offset` and `selection_length` (Theo Notes' extension to Bear's
    /// `open-note`, ruling M5-R155). Every value is percent-encoded down to the unreserved characters.
    func launchURL(noteId: String) -> URL? {
        var items: [(String, String)] = [("id", noteId)]
        if let header { items.append(("header", header)) }
        if edit { items.append(("edit", "yes")) }
        if newWindow { items.append(("new_window", "yes")) }
        if float { items.append(("float", "yes")) }
        if let selectionText { items.append(("selection_text", selectionText)) }
        if let selectionOffset { items.append(("selection_offset", String(selectionOffset))) }
        if let selectionLength { items.append(("selection_length", String(selectionLength))) }
        let query = items.map { Self.encode($0.0) + "=" + Self.encode($0.1) }.joined(separator: "&")
        return URL(string: XCallbackRequest.scheme + "://x-callback-url/open-note?" + query)
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
}

/// The part of `app open` / `app get-selection` that CLI and MCP share.
enum AppBridge {
    /// Opens the note in the app. `resolveNote` applies the caller's scope and finds the note; it runs
    /// before anything is launched or sent, so a launch can only name a note the caller may see
    /// (ruling M5-R190). With no app running, the default library starts it with an `open-note` URL
    /// carrying the resolved id; a custom library is `app_unavailable` (ruling M5-R17) and is reported
    /// before the library is touched (M5-R45).
    static func open(
        _ request: AppOpenRequest, paths: AppPaths, context: AutomationContext,
        resolveNote: () throws(AutomationError) -> Note
    ) throws(AutomationError) {
        var running = true
        do throws(AutomationError) {
            let pong = try AppSocketClient.send(AppSocketRequest(id: 1, method: "ping"), paths: paths, home: context.home)
            _ = try pong.requireResult()
        } catch {
            guard AppSocketClient.isNotRunning(error), AppPaths.isRealLibrary(paths.root, production: context.production) else {
                throw error
            }
            running = false
        }
        let note = try resolveNote()
        guard running else { return try launch(request, noteId: note.id, context: context) }
        let reply = try AppSocketClient.send(
            AppSocketRequest(id: 2, method: "open", params: request.params(noteId: note.id)), paths: paths,
            home: context.home)
        _ = try reply.requireResult()
    }

    private static func launch(
        _ request: AppOpenRequest, noteId: String, context: AutomationContext
    ) throws(AutomationError) {
        guard let url = request.launchURL(noteId: noteId) else {
            throw AutomationError(code: .usage, message: "The note could not be put into a link")
        }
        do {
            try context.launcher(url)
        } catch let error as AutomationError {
            throw error
        } catch {
            throw AutomationError(code: .appUnavailable, message: "Theo Notes could not be launched")
        }
    }

    /// The note open in the app and its selection; nil when no app runs or no note is open.
    static func selection(paths: AppPaths, context: AutomationContext) throws(AutomationError) -> SelectionResult? {
        let reply: AppSocketResponse
        do throws(AutomationError) {
            reply = try AppSocketClient.send(AppSocketRequest(id: 1, method: "getSelection"), paths: paths, home: context.home)
        } catch {
            if AppSocketClient.isNotRunning(error) { return nil }
            throw error
        }
        let result = try reply.requireResult()
        return result.noteId == nil ? nil : result
    }
}

/// `app open` and `app get-selection`.
enum AppCommands {
    static let handlers: [[String]: CommandHandler] = [
        ["app", "open"]: open,
        ["app", "get-selection"]: getSelection,
    ]

    // MARK: app open

    private static func open(_ parsed: ParsedCommand, _ env: CommandEnvironment) throws(AutomationError) {
        let selector = try NoteSelector.parse(id: parsed.positionals.first, title: parsed.value("--title"))
        let request = try AppOpenRequest(
            selector: selector, header: parsed.value("--header"), edit: parsed.flag("--edit"),
            newWindow: parsed.flag("--new-window"), float: parsed.flag("--float"),
            selectionText: parsed.value("--selection-text"),
            selectionOffset: parsed.value("--selection-offset").flatMap { Int($0) },
            selectionLength: parsed.value("--selection-length").flatMap { Int($0) })
        let paths = try AutomationLibrary.resolvePaths(
            dataDir: parsed.dataDir, environment: env.context.environment, production: env.context.production)
        try AppBridge.open(request, paths: paths, context: env.context) { () throws(AutomationError) -> Note in
            let library = try env.library()
            return try ReadFailure.read(library) { db in try NoteResolver.resolve(selector, scope: .unrestricted, db: db) }
        }
    }

    // MARK: app get-selection

    private static func getSelection(_ parsed: ParsedCommand, _ env: CommandEnvironment) throws(AutomationError) {
        let fields = try NoteFields.parse(parsed.fieldsArgument, spec: parsed.spec)
        let paths = try AutomationLibrary.resolvePaths(
            dataDir: parsed.dataDir, environment: env.context.environment, production: env.context.production)
        guard let selection = try AppBridge.selection(paths: paths, context: env.context),
              let noteId = selection.noteId
        else {
            // No app, or no open note: nothing to show, and that is not a failure.
            if parsed.format == .json { env.io.write(Data("{}\n".utf8)) }
            return
        }
        let library = try env.library()
        let record = try ReadFailure.read(library) { db -> NoteRecord in
            let note = try NoteResolver.resolve(.id(noteId), scope: .unrestricted, db: db)
            let attachments = AttachmentStore(paths: library.paths, database: library.database)
            return try NoteRecord.load(note, db: db, attachments: attachments)
        }
        // A locked note shows its metadata and nothing it contains.
        let shown = record.locked ? SelectionResult(noteId: noteId) : selection
        let row = fields.map { field -> FieldValue in
            switch field {
            case "selectionOffset": shown.selectionOffset.map(FieldValue.int) ?? .null
            case "selectionLength": shown.selectionLength.map(FieldValue.int) ?? .null
            case "selectionText": shown.selectionText.map(FieldValue.string) ?? .null
            default: record.cliValue(field)
            }
        }
        switch parsed.format {
        case .json:
            let object = RecordWriter.jsonObject(Array(zip(fields, row)))
            env.io.write(Data((object.serialized(sortedKeys: false) + "\n").utf8))
        case .csv: env.io.write(Data(RecordWriter.csv(header: fields, [row]).utf8))
        case .tsv: env.io.write(Data(RecordWriter.tsv([row]).utf8))
        }
    }
}
