// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import SwiftUI

/// The third-party licences the app ships, pushed from Settings. The list is
/// `Acknowledgements.json` in the app bundle; if it cannot be read the page says so.
struct MobileAcknowledgements: View {
    private let result: Result<AcknowledgementsCatalog, Error> = Result { try AcknowledgementsCatalog(bundle: .main) }

    var body: some View {
        switch result {
        case .success(let catalog):
            List(catalog.entries) { entry in
                NavigationLink {
                    MobileAcknowledgementDetail(catalog: catalog, entry: entry)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title)
                        Text(entry.licence).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("acknowledgement-\(entry.name)")
            }
            .navigationTitle("Acknowledgements")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("acknowledgements-list")
        case .failure(let error):
            ContentUnavailableView("No licences to show", systemImage: "doc.text.magnifyingglass",
                                   description: Text("The list of licences could not be loaded. \(error.localizedDescription)"))
        }
    }
}

private struct MobileAcknowledgementDetail: View {
    let catalog: AcknowledgementsCatalog
    let entry: AcknowledgementsCatalog.Entry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(entry.name).font(.title2.bold())
                Text(entry.licenceExpression.map { "\(entry.licence) (chosen from \($0))" } ?? entry.licence)
                    .foregroundStyle(.secondary)
                if let notice = catalog.noticeText(for: entry) {
                    Text(notice).font(.footnote.monospaced()).textSelection(.enabled)
                }
                Text(catalog.licenceText(for: entry) ?? "The licence text for this entry is missing from the app.")
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .accessibilityIdentifier("acknowledgement-licence-text")
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
