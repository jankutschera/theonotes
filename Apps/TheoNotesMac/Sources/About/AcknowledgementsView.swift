// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import SwiftUI

/// Accessibility identifiers of the Acknowledgements window.
enum AcknowledgementsControl {
    static let list = "acknowledgements.list"
    static let licenceText = "acknowledgements.licenceText"
    static let noticeText = "acknowledgements.noticeText"
    static let count = "acknowledgements.count"
}

/// The searchable list of bundled third-party software, data and licences, with the full licence
/// text of the selected entry on the right.
struct AcknowledgementsView: View {
    @State private var model: AcknowledgementsModel

    init(model: AcknowledgementsModel = .bundled()) {
        _model = State(initialValue: model)
    }

    var body: some View {
        Group {
            if let message = model.loadError {
                ContentUnavailableView("No licences to show", systemImage: "doc.text.magnifyingglass", description: Text(message))
            } else {
                NavigationSplitView {
                    list
                        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
                } detail: {
                    detail
                }
                .searchable(text: $model.query, placement: .sidebar, prompt: "Search")
            }
        }
        .frame(minWidth: 760, minHeight: 460)
    }

    private var list: some View {
        List(model.visibleEntries, selection: $model.selectionID) { entry in
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                Text(entry.licence)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .tag(entry.id)
        }
        .accessibilityIdentifier(AcknowledgementsControl.list)
        .overlay {
            if model.visibleEntries.isEmpty {
                ContentUnavailableView.search(text: model.query)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Text(model.countText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
                .accessibilityIdentifier(AcknowledgementsControl.count)
        }
    }

    @ViewBuilder private var detail: some View {
        if let entry = model.selectedEntry {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(entry)
                    if let note = entry.note {
                        Text(note)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                    if let notice = model.noticeText {
                        section("Notice from the project", text: notice, id: AcknowledgementsControl.noticeText)
                    }
                    section("Licence text", text: model.licenceText, id: AcknowledgementsControl.licenceText)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("Select a component", systemImage: "doc.text", description: Text("Its licence text appears here."))
        }
    }

    private func header(_ entry: AcknowledgementsCatalog.Entry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.title)
                .font(.title2.bold())
                .textSelection(.enabled)
            LabeledContent("Licence", value: model.licenceLine(for: entry))
            LabeledContent("Copyright", value: entry.copyright)
            if !entry.usedIn.isEmpty {
                LabeledContent("Used for", value: entry.usedIn)
            }
            if let url = model.sourceURL(for: entry) {
                LabeledContent("Project") { Link(entry.source, destination: url) }
            }
            if let url = model.sourceCodeURL(for: entry), let text = entry.sourceCode {
                LabeledContent("Source code") { Link(text, destination: url) }
            }
        }
        .textSelection(.enabled)
    }

    private func section(_ title: String, text: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityIdentifier(id)
        }
    }
}
