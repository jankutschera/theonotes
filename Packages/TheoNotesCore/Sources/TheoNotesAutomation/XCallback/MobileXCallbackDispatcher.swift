// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import CryptoKit
import Foundation
import GRDB

// The iOS app's x-callback path from `ios-iphone-ipad`, kept compiling under `Mobile…` names after
// the integration merge (2026-10-26). The Mac, CLI and MCP use `XCallbackExecutor` (M5); the iOS
// adapter moves onto it in a follow-up port, after which this file goes.
public struct MobileXCallbackRequest: Sendable {
    public let action: String
    public let parameters: [String: String]
    public let success: URL?
    public let failure: URL?
    public init(_ url: URL) throws {
        guard let urlScheme = url.scheme?.lowercased(), (AppIdentity.production.urlSchemes + AppIdentity.dev.urlSchemes).contains(urlScheme),
              url.host == "x-callback-url", url.user == nil, url.password == nil,
              url.port == nil, url.fragment == nil, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              url.absoluteString.utf8.count <= 70 * 1024 * 1024 else { throw MobileXCallbackFailure.invalidRequest }
        action = String(url.path.dropFirst())
        var values: [String: String] = [:]
        for item in parts.queryItems ?? [] {
            guard values[item.name] == nil else { throw MobileXCallbackFailure.invalidRequest }
            values[item.name] = item.value ?? ""
        }
        parameters = values
        func callback(_ key: String) throws -> URL? {
            guard let value = values[key] else { return nil }
            guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
                  !(["file", "data", "javascript", "bear"] + AppIdentity.production.urlSchemes + AppIdentity.dev.urlSchemes).contains(scheme),
                  url.user == nil, url.password == nil else { throw MobileXCallbackFailure.invalidRequest }
            return url
        }
        success = try callback("x-success"); failure = try callback("x-error")
        for key in ["selected", "clipboard", "pin", "edit", "timestamp", "exclude_trashed", "open_note", "new_line", "wait"] {
            if let value = values[key], !["yes", "no"].contains(value) { throw MobileXCallbackFailure.invalidRequest }
        }
    }
    public func yes(_ key: String) -> Bool { parameters[key] == "yes" }
    public func callback(_ url: URL?, values: [String: String]) -> URL? {
        guard let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let keys = Set(values.keys)
        parts.queryItems = (parts.queryItems ?? []).filter { !keys.contains($0.name) } + values.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        return parts.url
    }
}
public enum MobileXCallbackFailure: Error, Equatable { case invalidRequest, unauthorized, locked, missingNote, emptyNote, missingHeader, missingParameter(String) }
public struct MobileXCallbackResult: Sendable {
    public var values: [String: String] = [:]
    public var noteID: String?
    public var scope: SidebarScope?
    public var query: String?
    public var workspace: String?
    public var changesWorkspace = false
    public var header: String?
    public var find: String?
    public var edit = false
    public var tagRewrite: TagRewriteResult?
    public var renamedTagFrom: String?
    public var renamedTagTo: String?
    public var deletedTag: String?
    /// An open `XCallbackReceipts` entry for this answer: settle it once the answer was handed back.
    public var receipt: String?
    public init() {}
}

/// The same source-preserving editing engines as CLI/MCP, with mobile token/privacy gates.
@MainActor public final class MobileXCallbackDispatcher {
    private let database: AppDatabase
    private let store: NoteStore
    private let attachments: AttachmentStore
    private let fetcher: any URLFetcher
    private let canAccess: () -> Bool
    public init(database: AppDatabase, paths: AppPaths, store: NoteStore, fetcher: any URLFetcher = HTTPSFetcher(), canAccess: @escaping () -> Bool = { true }) {
        self.database = database; self.store = store; self.fetcher = fetcher; self.canAccess = canAccess
        attachments = AttachmentStore(paths: paths, database: database)
    }
    public static func authorize(_ request: MobileXCallbackRequest, token: String?) throws -> Bool {
        if let supplied = request.parameters["token"] {
            guard let token, !token.isEmpty,
                  SHA256.hash(data: Data(supplied.utf8)) == SHA256.hash(data: Data(token.utf8)) else { throw MobileXCallbackFailure.unauthorized }
            return true
        }
        if request.yes("selected") || request.action == "tags" { throw MobileXCallbackFailure.unauthorized }
        return false
    }
    private func read<T>(_ body: (Database) throws -> T) throws -> T { try database.pool.read(body) }
    public static func captureURL(_ request: MobileXCallbackRequest) throws -> URL {
        guard let raw = request.parameters["url"], !raw.isEmpty else { throw MobileXCallbackFailure.missingParameter("url") }
        return try URLFetchPolicy.parse(raw)
    }
    private func requireAccess() throws { try Task.checkCancellation(); guard canAccess() else { throw MobileXCallbackFailure.locked } }
    public func execute(_ request: MobileXCallbackRequest, token: String?, selectedID: String? = nil, clipboard: String? = nil) async throws -> MobileXCallbackResult {
        let authorized = try Self.authorize(request, token: token)
        try requireAccess()
        let p = request.parameters
        func required(_ key: String) throws -> String {
            guard let value = p[key], !value.isEmpty else { throw MobileXCallbackFailure.missingParameter(key) }; return value
        }
        func resolved() throws -> Note {
            let selector: NoteSelector
            if request.yes("selected") { guard let selectedID else { throw MobileXCallbackFailure.missingNote }; selector = .id(selectedID) }
            else if let id = p["id"], !id.isEmpty { selector = .id(id) }
            else {
                let key = TitleKey.make(try required("title"))
                guard let note = try read({ try Note.fetchOne($0, sql: "SELECT * FROM note WHERE titleKey=? AND deletedAt IS NULL" + (request.yes("exclude_trashed") ? " AND location!='trash'" : "") + " ORDER BY modifiedAt DESC,id DESC LIMIT 1", arguments: [key]) }) else { throw MobileXCallbackFailure.missingNote }
                guard !note.isLocked else { throw MobileXCallbackFailure.locked }
                return note
            }
            let note = try read { try NoteResolver.resolve(selector, scope: .unrestricted, db: $0) }
            guard !note.isLocked else { throw MobileXCallbackFailure.locked }
            guard !request.yes("exclude_trashed") || note.location != .trash else { throw MobileXCallbackFailure.missingNote }
            return note
        }
        func data(_ note: Note) throws -> [String: String] {
            guard authorized else { return [:] }
            let formatter = ISO8601DateFormatter()
            let tags = NoteParser.metadata(for: note.text).tags
            return ["note": note.text, "identifier": note.id, "title": note.title, "tags": try json(tags),
                "is_trashed": note.location == .trash ? "yes" : "no", "modificationDate": formatter.string(from: note.modifiedAt), "creationDate": formatter.string(from: note.createdAt)]
        }
        func text() -> String {
            var value = request.yes("clipboard") ? clipboard ?? "" : p["text"] ?? ""
            if request.yes("timestamp") { value = ISO8601DateFormatter().string(from: .now) + "\n" + value }
            return value
        }
        func tags() throws -> [String] {
            try (p["tags"] ?? "").split(separator: ",").map { try NoteStore.tagToken(String($0)).name }
        }
        func file() throws -> (Data, String)? {
            guard p["file"] != nil || p["filename"] != nil else { return nil }
            let filename = try required("filename"), encoded = try required("file")
            guard !filename.contains("/"), !filename.contains("\\"), filename != ".", filename != "..",
                  let bytes = Data(base64Encoded: encoded), bytes.count <= 50 * 1024 * 1024 else { throw MobileXCallbackFailure.invalidRequest }
            return (bytes, filename)
        }
        var result = MobileXCallbackResult()
        switch request.action {
        case "open-note":
            let note = try resolved()
            if request.yes("pin") { try store.setPinned([note.id], pinned: true) }
            result.values = try data(note)
            if p["open_note"] != "no" { result.noteID = note.id }
            result.header = p["header"]; result.find = p["search"]; result.edit = request.yes("edit")
        case "create", "grab-url":
            // A request whose answer may not have arrived gets its first note back.
            // `wait=no` already answered before the work, so it gets no receipt.
            let answers = request.action != "grab-url" || p["wait"] != "no"
            let receipts = XCallbackReceipts(database: database)
            let fingerprint = XCallbackReceipts.fingerprint(action: request.action, parameters: p, clipboard: request.yes("clipboard") ? clipboard ?? "" : nil)
            if answers, let id = receipts.noteID(for: fingerprint, now: .now), let note = try store.note(id: id) {
                result.values = ["identifier": note.id, "title": note.title]
                if p["open_note"] != "no" { result.noteID = note.id }; result.edit = request.yes("edit")
                result.receipt = fingerprint
                return result
            }
            var source = text(), importedImages: [ImportedAttachment] = []
            if request.action == "grab-url" {
                let url = try Self.captureURL(request)
                let fetched = try await fetcher.fetch(url)
                try requireAccess()
                guard let html = String(data: fetched.data, encoding: .utf8) else { throw MobileXCallbackFailure.invalidRequest }
                let converted = HTMLToMarkdown.convert(try resolveHTML(html, base: url)); source = converted.markdown; importedImages = converted.images
            } else if p["type"] == "html" {
                let converted = HTMLToMarkdown.convert(try resolveHTML(source, base: p["url"].flatMap(URL.init(string:)))); source = converted.markdown; importedImages = converted.images
            } else if let type = p["type"], type != "markdown" { throw MobileXCallbackFailure.invalidRequest }
            let upload = try file(), additions = try tags()
            if let title = p["title"], !title.isEmpty { source = "# " + title + (source.isEmpty ? "" : "\n" + source) }
            guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || upload != nil else { throw MobileXCallbackFailure.emptyNote }
            let note = try store.create(text: source)
            do {
                for image in importedImages { _ = try attachments.add(data: image.data, filename: image.filename, to: note.id) }
                if let (bytes, filename) = upload {
                    let name = try attachments.add(data: bytes, filename: filename, to: note.id)
                    source += (source.isEmpty ? "" : "\n") + AttachmentMarkdown.link(for: name)
                    _ = try store.updateText(id: note.id, text: source, expectedRevision: note.revision)
                }
                for tag in additions { try store.addTag(tag, to: [note.id], position: Settings(db: database).tagPosition) }
                if request.yes("pin") { try store.setPinned([note.id], pinned: true) }
            } catch { try? store.deletePermanently([note.id]); throw error }
            let created = try store.note(id: note.id) ?? note
            if answers {
                result.values = ["identifier": created.id, "title": created.title]
                receipts.record(fingerprint, noteID: created.id, now: .now)
                result.receipt = fingerprint
            }
            if p["open_note"] != "no" { result.noteID = note.id }; result.edit = request.yes("edit")
        case "add-text", "add-file":
            let note = try resolved()
            guard !note.isReadOnly else { throw MobileXCallbackFailure.locked }
            let mode = p["mode"] ?? "append"
            guard ["append", "prepend", "replace", "replace_all"].contains(mode) else { throw MobileXCallbackFailure.invalidRequest }
            let sections = NoteSections(text: note.text)
            var target: SectionTarget?
            if let header = p["header"] { target = try headerTarget(header, sections: sections) }
            let additions = try tags()
            var addition = text()
            if request.action == "add-file" {
                guard let (bytes, filename) = try file() else { throw MobileXCallbackFailure.missingParameter("file") }
                addition = AttachmentMarkdown.link(for: try attachments.add(data: bytes, filename: filename, to: note.id))
            }
            let source: String
            if mode == "replace_all" { source = addition }
            else if mode == "replace" {
                if let target, case .section(let index) = target {
                    let section = sections.sections[index], bytes = Array(note.text.utf8)
                    var replacement = Array(addition.utf8)
                    if !replacement.isEmpty, replacement.last != 10 { replacement.append(10) }
                    source = String(decoding: bytes[..<section.headingEnd] + replacement + bytes[section.range.upperBound...], as: UTF8.self)
                }
                else {
                    let lines = note.text.components(separatedBy: "\n")
                    let titleEnd = min(lines.count, NoteParser.bodyStartLine(in: note.text) + 1)
                    let preserved = lines.prefix(titleEnd).joined(separator: "\n")
                    source = preserved + (addition.isEmpty ? "" : "\n" + addition)
                }
            } else if mode == "append", target == nil, !request.yes("new_line"), request.action == "add-text" {
                source = note.text + addition
            } else { source = AppendEngine.apply(addition, position: mode == "prepend" ? .beginning : .end, target: target, to: note.text, tagPosition: Settings(db: database).tagPosition).text }
            _ = try store.updateText(id: note.id, text: source, expectedRevision: note.revision)
            for tag in additions { try store.addTag(tag, to: [note.id], position: Settings(db: database).tagPosition) }
            result.values = try data(try store.note(id: note.id) ?? note)
            if p["open_note"] != "no" { result.noteID = note.id }; result.edit = request.yes("edit")
        case "rename-tag", "delete-tag":
            let name = try required("name"), key = CanonicalKey.make(name)
            let locked = try read { try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM note_tag nt JOIN tag t ON t.id=nt.tagId JOIN note n ON n.id=nt.noteId WHERE n.deletedAt IS NULL AND n.isLocked AND (t.pathKey=? OR substr(t.pathKey,1,?)=?))", arguments: [key, key.count + 1, key + "/"]) ?? false }
            guard !locked else { throw MobileXCallbackFailure.locked }
            if request.action == "rename-tag" {
                let replacement = try NoteStore.tagToken(required("new_name")).name
                result.tagRewrite = try store.renameTag(name, to: replacement)
                result.renamedTagFrom = name; result.renamedTagTo = replacement
            } else { result.tagRewrite = try store.deleteTag(name); result.deletedTag = name }
        case "trash", "archive":
            let ids: [String]
            if let id = p["id"], !id.isEmpty { ids = [try resolved().id] }
            else {
                let query = try required("search")
                ids = try list(scope: .notes, query: query).filter { !$0.isLocked }.map(\.id)
            }
            if request.action == "trash" { try store.trash(ids); result.scope = .trash }
            else { try store.archive(ids); result.scope = .archive }
        case "tags":
            func flatten(_ nodes: [TagNode]) -> [String] { nodes.flatMap { [$0.path] + flatten($0.children) } }
            let names = try read { try flatten(LibraryQueries.tagTree(db: $0)) }
            result.values = ["tags": try json(names.map { ["name": $0] })]
        case "open-workspace": result.workspace = try required("name"); result.changesWorkspace = true
        case "close-workspace": result.changesWorkspace = true
        case "open-tag", "search", "untagged", "todo", "today", "locked":
            let scope: SidebarScope
            var query = p["search"] ?? ""
            switch request.action {
            case "open-tag":
                let names = try required("name").split(separator: ",").map { try NoteStore.tagToken(String($0)).name }
                guard !names.isEmpty else { throw MobileXCallbackFailure.invalidRequest }
                if names.count == 1 { scope = .tag(names[0]) }
                else { scope = .notes; query = names.map { "#" + $0 + "#" }.joined(separator: " or ") }
            case "search": scope = p["tag"].map(SidebarScope.tag) ?? .notes; query = p["term"] ?? ""
            case "untagged": scope = .untagged
            case "todo": scope = .todo
            case "today": scope = .today
            default: scope = .locked
            }
            result.scope = scope; result.query = query
            if authorized, request.action != "locked" {
                let notes = try list(scope: scope, query: query).filter { !$0.isLocked }
                let formatter = ISO8601DateFormatter()
                let values: [[String: Any]] = try notes.map { item in
                    let tags = try store.note(id: item.id).map { NoteParser.metadata(for: $0.text).tags } ?? []
                    return ["identifier": item.id, "title": item.title, "tags": tags, "pin": item.isPinned,
                        "modificationDate": formatter.string(from: item.modifiedAt), "creationDate": formatter.string(from: item.createdAt)]
                }
                result.values = ["notes": try json(values)]
            }
        default: throw MobileXCallbackFailure.invalidRequest
        }
        return result
    }
    private func list(scope: SidebarScope, query: String) throws -> [NoteListItem] {
        try read { db in
            if query.isEmpty { return try LibraryQueries.notes(in: scope, sort: .modifiedDescending, now: .now, calendar: .current, db: db) }
            return try LibraryQueries.search(query, in: scope, sort: .modifiedDescending, now: .now, calendar: .current, db: db).items
        }
    }
    private func headerTarget(_ header: String, sections: NoteSections) throws -> SectionTarget {
        let normalized = TitleKey.make(header)
        guard let index = sections.sections.firstIndex(where: { TitleKey.make(NoteParser.metadata(for: $0.headingLine).headings.first?.text ?? $0.headingLine) == normalized }) else { throw MobileXCallbackFailure.missingHeader }
        return .section(index)
    }
    private func resolveHTML(_ source: String, base: URL?) throws -> String {
        guard let base else { return source }
        guard ["https", "http"].contains(base.scheme?.lowercased() ?? ""), base.host != nil else { throw MobileXCallbackFailure.invalidRequest }
        let pattern = #"(?i)(\b(?:src|href)\s*=\s*)(["'])([^"']*)\2"#
        let regex = try NSRegularExpression(pattern: pattern)
        let original = source as NSString
        var value = source
        for match in regex.matches(in: source, range: NSRange(location: 0, length: original.length)).reversed() {
            let range = match.range(at: 3), raw = original.substring(with: range)
            guard !raw.hasPrefix("#"), URL(string: raw)?.scheme == nil,
                  let url = URL(string: raw, relativeTo: base)?.absoluteURL, let native = Range(range, in: value) else { continue }
            value.replaceSubrange(native, with: url.absoluteString)
        }
        return value
    }
    private func json(_ value: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self) }
}
