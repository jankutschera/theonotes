// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Observation

/// The Quick Open panel's state (⌘O, spec §4.5): the query, its results (`QuickOpen`, loaded
/// off the main thread when the panel opens) and the selected row. ↑↓ move, ↩ opens, ⌘↩ opens
/// in a new window, Esc closes. With `recentTemplates` it is the template picker instead (File ▸
/// New Note from Template…, ⇧⌘N; M4 Task 10): the same panel and keys, listing only templates,
/// the recently used first.
@MainActor
@Observable
final class QuickOpenModel {
    enum Key: Equatable {
        case up, down, open, openInNewWindow, cancel
    }

    var query = "" {
        didSet {
            guard query != oldValue else { return }
            update()
            if index != nil { onResultsChange(results) }
        }
    }
    private(set) var results: [QuickOpenResult] = []
    private(set) var selectedIndex = 0
    /// The snapshot has not arrived yet (`install`).
    private(set) var isLoading: Bool

    /// Called with the chosen result and whether it opens in a new window (⌘↩).
    @ObservationIgnored var onChoose: (QuickOpenResult, _ newWindow: Bool) -> Void = { _, _ in }
    /// Esc.
    @ObservationIgnored var onCancel: () -> Void = {}
    /// The selection moved with the keyboard (VoiceOver announces the new row).
    @ObservationIgnored var onSelectionChange: (QuickOpenResult) -> Void = { _ in }
    /// The typed query changed the results (VoiceOver announces count and top hit, debounced).
    @ObservationIgnored var onResultsChange: ([QuickOpenResult]) -> Void = { _ in }

    @ObservationIgnored private var index: QuickOpen?
    /// The picker's mode: when each template was last used (by note id); nil for Quick Open.
    @ObservationIgnored let recentTemplates: [String: Date]?

    /// `index` nil: results come with `install` (what is typed meanwhile is kept).
    init(index: QuickOpen?, recentTemplates: [String: Date]? = nil) {
        self.index = index
        self.recentTemplates = recentTemplates
        isLoading = index == nil
        update()
    }

    func install(_ index: QuickOpen) {
        self.index = index
        isLoading = false
        update()
    }

    /// The snapshot, read off the main thread. Commits the open editors first, so titles typed a
    /// moment ago are found. `workspace`: see `AppModel.quickOpenWorkspace(for:)`.
    static func loadIndex(
        environment: AppEnvironment, now: Date = .now, workspace: Workspace? = nil
    ) async throws -> QuickOpen {
        environment.flushAll()
        return try await environment.database.pool.read { try QuickOpen.load(db: $0, now: now, workspace: workspace) }
    }

    /// A loaded model, synchronously (tests).
    static func load(
        environment: AppEnvironment, now: Date = .now, workspace: Workspace? = nil, recentTemplates: [String: Date]? = nil
    ) throws -> QuickOpenModel {
        environment.flushAll()
        let index = try environment.database.pool.read { try QuickOpen.load(db: $0, now: now, workspace: workspace) }
        return QuickOpenModel(index: index, recentTemplates: recentTemplates)
    }

    var selected: QuickOpenResult? {
        results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }

    func select(_ index: Int) {
        guard results.indices.contains(index), index != selectedIndex else { return }
        selectedIndex = index
    }

    /// Whether the panel used the key: ↑↓ without results go on to the field.
    @discardableResult
    func handle(_ key: Key) -> Bool {
        switch key {
        case .up, .down:
            guard !results.isEmpty else { return false }
            move(by: key == .up ? -1 : 1)
        case .open: if let selected { onChoose(selected, false) }
        case .openInNewWindow: if let selected { onChoose(selected, true) }
        case .cancel: onCancel()
        }
        return true
    }

    /// A click on a row (⌘-click: in a new window).
    func choose(_ result: QuickOpenResult, newWindow: Bool) {
        onChoose(result, newWindow)
    }

    private func move(by delta: Int) {
        let target = min(max(selectedIndex + delta, 0), max(results.count - 1, 0))
        guard target != selectedIndex, results.indices.contains(target) else { return }
        selectedIndex = target
        onSelectionChange(results[target])
    }

    private func update() {
        if let recentTemplates {
            results = Self.templateResults(in: index, query: query, lastUsed: recentTemplates)
        } else {
            results = index?.results(query: query) ?? []
        }
        selectedIndex = 0
    }

    /// The picker's rows: Quick Open's `+` mode (the same fuzzy matching and scores), templates
    /// only. Without a query the recently used come first (then the most recently modified, the
    /// order `QuickOpen` lists them in); with one the best match does, recent use deciding ties.
    static func templateResults(in index: QuickOpen?, query: String, lastUsed: [String: Date]) -> [QuickOpenResult] {
        guard let index else { return [] }
        let filter = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let found = index.results(query: "+" + filter, limit: 1000).filter { $0.kind == .template }
        func used(_ result: QuickOpenResult) -> Date {
            if case .template(let id) = result.target { return lastUsed[id] ?? .distantPast }
            return .distantPast
        }
        return found.enumerated().sorted { a, b in
            if !filter.isEmpty, a.element.score != b.element.score { return a.element.score > b.element.score }
            let (usedA, usedB) = (used(a.element), used(b.element))
            if usedA != usedB { return usedA > usedB }
            return a.offset < b.offset
        }.map(\.element)
    }

    // MARK: - Mode texts

    var isTemplatePicker: Bool { recentTemplates != nil }

    var panelTitle: String { isTemplatePicker ? "New Note from Template" : "Quick Open" }

    var placeholder: String {
        isTemplatePicker ? "Choose a template" : "Open note, #tag, @section or +template"
    }

    var fieldHint: String {
        isTemplatePicker
            ? "Type to filter the templates. Up and down arrows choose, Return creates the note, Command-Return creates it in a new window."
            : "Type a note title, # for tags, @ for sidebar sections, + for templates. Up and down arrows choose, Return opens, Command-Return opens in a new window."
    }

    /// What the empty list says.
    var emptyMessage: String {
        if isLoading { return "Loading…" }
        if isTemplatePicker, query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No templates yet. Tag a note #template to make one."
        }
        return "No Results"
    }

    // MARK: - Keys

    /// The panel's keys: ↑ ↓, ↩ / Enter (⌘: new window), Esc. Other modifiers pass the key on; a
    /// held ↩ (key repeat) is not a key here (the panel swallows it, see `isRepeatedReturn`).
    static func key(for event: NSEvent) -> Key? {
        guard event.type == .keyDown, !isRepeatedReturn(event) else { return nil }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch event.keyCode {
        case 126 where modifiers.isEmpty: return .up
        case 125 where modifiers.isEmpty: return .down
        case 36, 76:
            if modifiers.isEmpty { return .open }
            return modifiers == .command ? .openInNewWindow : nil
        case 53 where modifiers.isEmpty: return .cancel
        default: return nil
        }
    }

    static func isRepeatedReturn(_ event: NSEvent) -> Bool {
        event.type == .keyDown && event.isARepeat && (event.keyCode == 36 || event.keyCode == 76)
    }

    /// What VoiceOver says after typing settles: the count and the top hit.
    static func resultsAnnouncement(_ results: [QuickOpenResult]) -> String {
        guard let first = results.first else { return "No results" }
        let count = results.count == 1 ? "1 result" : "\(results.count) results"
        return "\(count), \(accessibilityLabel(for: first))"
    }

    // MARK: - Presentation

    static func displayTitle(for result: QuickOpenResult) -> String {
        result.kind == .note && result.title.isEmpty ? "Untitled" : result.title
    }

    static func symbolName(for result: QuickOpenResult) -> String {
        switch result.target {
        case .note: return "doc.text"
        case .template: return "doc.badge.plus"
        case .search: return "magnifyingglass"
        case .scope(let scope):
            if case .tag(let path) = scope {
                if let icon = result.iconName, NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil {
                    return icon
                }
                return TagIcons.defaultSymbol(forTagPath: path)
            }
            return scope.systemImage
        }
    }

    /// What VoiceOver reads for a row: title, then what it is.
    static func accessibilityLabel(for result: QuickOpenResult) -> String {
        let title = displayTitle(for: result)
        switch result.kind {
        case .note: return result.detail.map { "\(title), note in \($0)" } ?? "\(title), note"
        case .tag: return "\(title), tag"
        case .section: return "\(title), sidebar section"
        case .search: return "\(title), \(result.detail ?? "search")"
        case .template: return "\(title), template"
        }
    }
}
