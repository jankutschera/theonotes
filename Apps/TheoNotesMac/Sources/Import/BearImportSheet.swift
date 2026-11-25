// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import SwiftUI

/// File ▸ Import From ▸ Bear…: the bearcli path, how many notes Bear has, then progress and the report.
struct BearImportSheet: View {
    let model: ImportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import from Bear")
                .font(.headline)
            Text("""
                Theo Notes reads your Bear library with Bear’s command line tool. Nothing in Bear is changed. \
                Running it again brings in only what changed in Bear.
                """)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("bearcli").foregroundStyle(.secondary)
                    Text(model.bearCLIDisplayPath)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help("Change it in Settings → Advanced")
                }
                GridRow {
                    Text("Bear library").foregroundStyle(.secondary)
                    previewText
                }
            }

            ImportPhaseView(phase: model.phase)

            ImportSheetButtons(model: model, startTitle: "Import", canStart: canStart) {
                model.startBearImport()
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var canStart: Bool {
        if case .loaded(let preview) = model.preview { return preview.total > 0 }
        return false
    }

    @ViewBuilder private var previewText: some View {
        switch model.preview {
        case .idle:
            Text("–").foregroundStyle(.secondary)
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Counting notes…").foregroundStyle(.secondary)
            }
        case .loaded(let preview):
            Text(preview.text).monospacedDigit()
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("Check the bearcli path in Settings → Advanced.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Try Again") { model.loadPreview() }
                    .controlSize(.small)
            }
        }
    }
}
