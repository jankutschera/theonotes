// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Observation

/// What the Acknowledgements window shows (LIC-R*): the searchable list of bundled third-party
/// software and data, and the licence text of the selected entry. The list is read from
/// `Acknowledgements.json` in the app bundle; if that fails the window says so instead of
/// showing an empty list.
@MainActor
@Observable
final class AcknowledgementsModel {
    typealias Entry = AcknowledgementsCatalog.Entry

    private(set) var catalog: AcknowledgementsCatalog?
    /// Why the list could not be loaded; nil when it was.
    private(set) var loadError: String?

    var query = "" {
        didSet { if query != oldValue { keepSelectionVisible() } }
    }
    var selectionID: Entry.ID?

    init(catalog: AcknowledgementsCatalog) {
        self.catalog = catalog
        selectionID = catalog.entries.first?.id
    }

    init(loadError: String) {
        self.loadError = loadError
    }

    /// The list from the app bundle (or a bundle a test names).
    static func bundled(_ bundle: Bundle = .main) -> AcknowledgementsModel {
        do {
            return AcknowledgementsModel(catalog: try AcknowledgementsCatalog(bundle: bundle))
        } catch {
            return AcknowledgementsModel(loadError: "The list of licences could not be loaded. \(error.localizedDescription)")
        }
    }

    /// The entries that match the search, in the order of the file (alphabetical).
    var visibleEntries: [Entry] { catalog?.search(query) ?? [] }

    var totalCount: Int { catalog?.entries.count ?? 0 }

    /// "115 components" or "3 of 115 components" while searching.
    var countText: String {
        let visible = visibleEntries.count
        let noun = totalCount == 1 ? "component" : "components"
        return visible == totalCount ? "\(totalCount) \(noun)" : "\(visible) of \(totalCount) \(noun)"
    }

    var selectedEntry: Entry? {
        guard let selectionID else { return nil }
        return visibleEntries.first { $0.id == selectionID }
    }

    /// The licence text of the selected entry; empty only when there is no selection.
    var licenceText: String {
        guard let entry = selectedEntry, let catalog else { return "" }
        return catalog.licenceText(for: entry) ?? "The licence text for this entry is missing from the app."
    }

    var noticeText: String? {
        guard let entry = selectedEntry else { return nil }
        return catalog?.noticeText(for: entry)
    }

    /// A line under the name: which licence it is used under, and the choice it was made from.
    func licenceLine(for entry: Entry) -> String {
        guard let expression = entry.licenceExpression else { return entry.licence }
        return "\(entry.licence) (chosen from \(expression))"
    }

    /// Where a person can find the project; nil when the file has no usable web address.
    func sourceURL(for entry: Entry) -> URL? {
        guard let url = URL(string: entry.source), let scheme = url.scheme, ["https", "http"].contains(scheme) else { return nil }
        return url
    }

    /// Where the source code of this exact version is; only for components whose licence asks for it.
    func sourceCodeURL(for entry: Entry) -> URL? {
        guard let text = entry.sourceCode, let url = URL(string: text), url.scheme == "https" else { return nil }
        return url
    }

    /// A search that hides the selected entry selects the first one still shown (none: nothing).
    private func keepSelectionVisible() {
        let visible = visibleEntries
        if let selectionID, visible.contains(where: { $0.id == selectionID }) { return }
        selectionID = visible.first?.id
    }
}
