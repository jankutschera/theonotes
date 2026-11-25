// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import SwiftUI

/// The export progress and report sheet, attached to the main window.
struct ExportPresentation: ViewModifier {
    @Bindable var exporter: ExportModel

    func body(content: Content) -> some View {
        content
            .sheet(
                isPresented: Binding(get: { exporter.showsSheet }, set: { if !$0 { exporter.dismiss() } })
            ) {
                ExportSheet(model: exporter)
                    .interactiveDismissDisabled(exporter.isRunning)
            }
    }
}

/// Progress with Cancel while a run is going, then the report (or the reason it did not start).
struct ExportSheet: View {
    let model: ExportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)
            switch model.phase {
            case .idle:
                EmptyView()
            case .running(let done, let total):
                ImportProgressView(done: done, total: total, cancelling: model.isCancelling)
            case .finished(let report):
                ExportReportView(summary: ExportReportSummary(report, wasCancelled: model.wasCancelled))
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            HStack {
                if case .finished(let report) = model.phase, report.exported > 0 {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([report.destination]) }
                }
                Spacer()
                if model.isRunning {
                    Button("Cancel") { model.cancel() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(model.isCancelling)
                } else {
                    Button("Done") { model.dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var title: String {
        switch model.phase {
        case .running: "Exporting Notes"
        case .finished: model.wasCancelled ? "Export Cancelled" : "Export Finished"
        case .failed: "Export Failed"
        case .idle: ""
        }
    }
}

/// The report: how many notes were written, the locked line, and expandable lists of the
/// attachments that could not be copied and of the notes that failed (ids and messages only).
struct ExportReportView: View {
    let summary: ExportReportSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(summary.headline, systemImage: summary.wasCancelled ? "stop.circle" : "checkmark.circle")
                .foregroundStyle(summary.wasCancelled ? .secondary : .primary)
            if let locked = summary.lockedLine {
                Label(locked, systemImage: "lock")
                    .foregroundStyle(.secondary)
            }
            ExportReportLines(
                title: "Attachments not copied", lines: summary.missingAttachments, systemImage: "paperclip")
            ExportReportLines(title: "Errors", lines: summary.errors, systemImage: "xmark.octagon")
        }
    }
}

private struct ExportReportLines: View {
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
