// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import SwiftUI

/// File ▸ Import From ▸ Apple Notes…: what Notes holds per folder, then progress and the report.
struct AppleNotesImportSheet: View {
    let model: ImportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import from Apple Notes")
                .font(.headline)
            Text("""
                Theo Notes reads your notes from Apple Notes. Nothing in Notes is changed. Folders become \
                tags, locked notes are skipped. Running it again brings in only what changed in Notes.
                """)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            previewView

            ImportPhaseView(phase: model.phase)

            ImportSheetButtons(model: model, startTitle: "Import", canStart: canStart) {
                model.startAppleNotesImport()
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var canStart: Bool {
        if case .loaded(let preview) = model.appleNotesPreview { return preview.total > preview.passwordProtected }
        return false
    }

    @ViewBuilder private var previewView: some View {
        switch model.appleNotesPreview {
        case .idle:
            EmptyView()
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Reading Apple Notes…").foregroundStyle(.secondary)
            }
        case .loaded(let preview):
            VStack(alignment: .leading, spacing: 6) {
                Text(preview.text).monospacedDigit()
                if preview.folders.count > 1, model.phase == .idle {
                    ScrollView {
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 2) {
                            ForEach(preview.folders) { folder in
                                GridRow {
                                    Text(folder.path).lineLimit(1).truncationMode(.middle)
                                    Text(folder.count, format: .number)
                                        .monospacedDigit()
                                        .gridColumnAlignment(.trailing)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { model.loadAppleNotesPreview() }
                    .controlSize(.small)
            }
        }
    }
}
