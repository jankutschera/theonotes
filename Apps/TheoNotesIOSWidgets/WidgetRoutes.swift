// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

enum WidgetCaptureAction: String, CaseIterable, Codable, Sendable {
    case thought, voice, newNote, newTodo, scan, search
    var title: String {
        switch self {
        case .thought: "Thought"
        case .voice: "Voice"
        case .newNote: "New Note"
        case .newTodo: "New To-Do"
        case .scan: "Scan Document"
        case .search: "Search"
        }
    }
    var symbol: String {
        switch self {
        case .thought: "lightbulb"
        case .voice: "mic"
        case .newNote: "square.and.pencil"
        case .newTodo: "checklist"
        case .scan: "doc.viewfinder"
        case .search: "magnifyingglass"
        }
    }
    func url() -> URL {
        WidgetRoutes.url([URLQueryItem(name: "action", value: rawValue)])
    }
}

enum WidgetRoutes {
    static var scheme: String {
        let configured = Bundle.main.object(forInfoDictionaryKey: "THEONOTES_URLScheme") as? String
        let registered = (Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])?
            .compactMap { $0["CFBundleURLSchemes"] as? [String] }.flatMap { $0 }.first
        let value = configured ?? registered ?? "theonotes-unconfigured"
        return value.isEmpty || value.contains("$(") ? "theonotes-unconfigured" : value
    }
    static func url(_ items: [URLQueryItem]) -> URL {
        var value = URLComponents(); value.scheme = scheme; value.host = "widget"; value.queryItems = items
        return value.url! // Constant scheme/host and URLQueryItem escape every supplied value.
    }
    /// Pure app opening: no capture action and no persisted delivery identity.
    static func openApp() -> URL {
        var value = URLComponents(); value.scheme = scheme; value.host = "widget"
        return value.url!
    }
    static func nextUp(snapshot: WidgetSnapshot?, at date: Date) -> URL {
        guard let snapshot, !snapshot.redacted,
              let entry = snapshot.nextUpEntry(at: date), entry.state == .candidate,
              let noteID = entry.noteId else { return openApp() }
        return note(noteID, libraryID: snapshot.libraryID)
    }
    static func nextUpTitle(snapshot: WidgetSnapshot?, at date: Date) -> String {
        guard let snapshot, let entry = snapshot.nextUpEntry(at: date) else { return "Open Theo Notes" }
        if snapshot.redacted || entry.state == .locked { return "Open Theo Notes" }
        return entry.state == .candidate ? (entry.title ?? "Next Up") : "Nothing next"
    }
    static func nextUpSymbol(snapshot: WidgetSnapshot?, at date: Date) -> String {
        guard let snapshot, let entry = snapshot.nextUpEntry(at: date) else { return "note.text" }
        if snapshot.redacted || entry.state == .locked { return "lock" }
        guard entry.state == .candidate else { return "note.text" }
        return entry.kind == "reminder" ? "bell" : entry.kind == "todo" ? "checklist" : "lightbulb"
    }
    static func lastOpened(snapshot: WidgetSnapshot?) -> URL {
        guard let snapshot, !snapshot.redacted, let card = snapshot.lastOpened else { return openApp() }
        return note(card.id, libraryID: snapshot.libraryID)
    }
    static func lastOpenedSymbol(snapshot: WidgetSnapshot?) -> String { snapshot?.redacted == true ? "lock" : "note.text" }
    static func note(_ id: String, libraryID: String) -> URL {
        url([.init(name: "note", value: id), .init(name: "library", value: libraryID)])
    }
}
