// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import SwiftUI

/// The import sheets, the Pull from Bear HUD and its alert, attached to the main window.
struct ImportPresentation: ViewModifier {
    @Bindable var importer: ImportModel

    func body(content: Content) -> some View {
        content
            .sheet(item: $importer.sheet, onDismiss: { importer.dismissSheet() }) { sheet in
                Group {
                    switch sheet {
                    case .bear: BearImportSheet(model: importer)
                    case .files(let urls): FileImportSheet(model: importer, urls: urls)
                    case .appleNotes: AppleNotesImportSheet(model: importer)
                    }
                }
                .interactiveDismissDisabled(importer.isRunning)
            }
            .overlay(alignment: .bottom) {
                if importer.showsPullProgress {
                    PullProgressHUD(model: importer)
                        .padding(.bottom, 16)
                        .transition(.opacity)
                }
            }
            .alert(
                importer.pullAlert?.title ?? "",
                isPresented: Binding(
                    get: { importer.pullAlert != nil },
                    set: { if !$0 { importer.pullAlert = nil } }
                ),
                presenting: importer.pullAlert
            ) { summary in
                Button("OK", role: .cancel) { importer.pullAlert = nil }
                if !summary.rows.isEmpty, !summary.errors.isEmpty || !summary.warnings.isEmpty {
                    Button("Show Details…") { importer.showPullDetails() }
                }
            } message: { summary in
                Text(summary.headline)
            }
    }
}

/// Determinate progress while an import runs ("12 of 233 notes").
struct ImportProgressView: View {
    let done: Int
    let total: Int
    let cancelling: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if total > 0 {
                ProgressView(value: Double(done), total: Double(total))
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var label: String {
        if cancelling { return "Cancelling…" }
        if total == 0 { return "Reading notes…" }
        return "\(done) of \(total) notes"
    }
}

/// Counts plus expandable error and warning lines (ids and messages only).
struct ImportReportView: View {
    let summary: ImportSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if summary.wasCancelled {
                Label("Cancelled. Notes imported before cancelling were kept.", systemImage: "stop.circle")
                    .foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                ForEach(summary.rows) { row in
                    GridRow {
                        Text(row.label)
                        Text(row.count, format: .number)
                            .monospacedDigit()
                            .gridColumnAlignment(.trailing)
                            .foregroundStyle(row.count == 0 ? .secondary : .primary)
                    }
                }
            }
            ReportLines(title: "Errors", lines: summary.errors, systemImage: "xmark.octagon")
            ReportLines(title: "Warnings", lines: summary.warnings, systemImage: "exclamationmark.triangle")
        }
    }
}

private struct ReportLines: View {
    let title: String
    let lines: [String]
    let systemImage: String

    var body: some View {
        if !lines.isEmpty {
            DisclosureGroup {
                ScrollView {
                    Text(lines.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            } label: {
                Label("\(title) (\(lines.count))", systemImage: systemImage)
            }
        }
    }
}

/// Small floating progress for Pull from Bear.
struct PullProgressHUD: View {
    let model: ImportModel

    var body: some View {
        HStack(spacing: 12) {
            if case .running(let done, let total, let cancelling) = model.phase {
                if total > 0 {
                    ProgressView(value: Double(done), total: Double(total))
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(cancelling ? "Cancelling…" : total > 0 ? "Pulling from Bear… \(done) of \(total)" : "Pulling from Bear…")
                    .monospacedDigit()
                Button("Cancel") { model.cancel() }
                    .controlSize(.small)
                    .disabled(cancelling)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 4, y: 1)
    }
}

/// Buttons shared by both sheets: start / cancel while running / done when finished.
struct ImportSheetButtons: View {
    let model: ImportModel
    let startTitle: String
    let canStart: Bool
    let start: () -> Void

    var body: some View {
        HStack {
            Spacer()
            switch model.phase {
            case .idle:
                Button("Cancel", role: .cancel) { model.dismissSheet() }
                    .keyboardShortcut(.cancelAction)
                Button(startTitle, action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
            case .running(_, _, let cancelling):
                Button("Cancel") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(cancelling)
            case .finished, .failed:
                Button("Done") { model.dismissSheet() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// The phase below the sheet's settings: progress, report or failure.
struct ImportPhaseView: View {
    let phase: ImportPhase

    var body: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .running(let done, let total, let cancelling):
            ImportProgressView(done: done, total: total, cancelling: cancelling)
        case .finished(let summary):
            ImportReportView(summary: summary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }
}
