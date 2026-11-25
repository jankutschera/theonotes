// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import SwiftUI

/// File ▸ Import Notes… after the open panel: the chosen items, options, progress and the report.
struct FileImportSheet: View {
    @Bindable var model: ImportModel
    let urls: [URL]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.fileImportMode == .appleNotesExport ? "Import Apple Notes Export" : "Import Notes")
                .font(.headline)
            Text(itemsText)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .truncationMode(.middle)
            if model.fileImportMode == .appleNotesExport {
                Text("Each folder becomes a tag starting with apple-notes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Keep creation and modification dates", isOn: $model.fileOptions.keepDates)
                // The Apple Notes export importer has its own text pipeline: it only knows the file name.
                let general = model.fileImportMode == .files
                if general { Toggle("Use the first line as the title", isOn: $model.fileOptions.titleFromFirstLine) }
                Toggle("Use the file name as the title", isOn: $model.fileOptions.titleFromFilename)
                    .disabled(general && model.fileOptions.titleFromFirstLine)
                    .help(general && model.fileOptions.titleFromFirstLine ? "The first line already sets the title." : "")
                if general { Toggle("Keep #3rd and #2026-11 as text, not tags", isOn: $model.fileOptions.keepHashNumbersAsText) }
            }
            .disabled(model.phase != .idle)

            ImportPhaseView(phase: model.phase)

            ImportSheetButtons(model: model, startTitle: "Import", canStart: !urls.isEmpty) {
                model.startFileImport()
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var itemsText: String {
        let names = urls.prefix(3).map(\.lastPathComponent)
        let more = urls.count > 3 ? " and \(urls.count - 3) more" : ""
        return "From: " + names.joined(separator: ", ") + more
    }
}
