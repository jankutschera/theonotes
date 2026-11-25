// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import SwiftUI
import TheoNotesCore

/// Files chosen for Import Notes, waiting for the options step (A14).
struct MobilePendingImport: Identifiable {
    let id = UUID()
    let urls: [URL]
}

/// The step between the file picker and the import: the same two text options as the Mac import sheet.
struct MobileImportOptionsSheet: View {
    let urls: [URL]
    let onImport: (FileImportOptions) -> Void
    let onCancel: () -> Void
    @State private var options = FileImportOptions()

    var body: some View {
        NavigationStack {
            Form {
                // IOS-DESIGN-R10: the files as a plain row; Title Case switches on one line, the examples in the footer.
                Section {
                    LabeledContent(urls.count == 1 ? "File" : "Files") {
                        Text(itemsText).lineLimit(3).truncationMode(.middle)
                    }
                }
                Section {
                    Toggle("Use First Line as Title", isOn: $options.titleFromFirstLine)
                    Toggle("Keep Number Tags as Text", isOn: $options.keepHashNumbersAsText)
                } footer: { Text(verbatim: "Words like #3rd or #2026-11 stay plain text, not tags.") }
            }
            .navigationTitle("Import Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) { Button("Import") { onImport(options) }.buttonStyle(.glassProminent) }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("import-options-sheet")
    }

    private var itemsText: String {
        let names = urls.prefix(3).map(\.lastPathComponent)
        return names.joined(separator: ", ") + (urls.count > 3 ? " and \(urls.count - 3) more" : "")
    }
}
