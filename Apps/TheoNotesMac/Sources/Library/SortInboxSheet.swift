// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import SwiftUI

/// The words of the Sort Inbox sheet.
enum SortInboxStrings {
    static func progress(_ progress: (done: Int, total: Int)) -> String {
        "\(min(progress.done + 1, progress.total)) of \(progress.total)"
    }

    static func archiveRestTitle(_ count: Int) -> String {
        "Archive \(count) \(count == 1 ? "note" : "notes")?"
    }

    static let archiveRestMessage = "They stay searchable and can be restored."

    /// "3 typed, 1 archived, 0 trashed, 2 skipped" without the zeros; nil when nothing was handled.
    static func summaryLines(_ summary: SortInboxSummary) -> [String] {
        [(summary.typed, "typed"), (summary.archived, "archived"), (summary.trashed, "moved to the Trash"),
         (summary.skipped, "skipped")]
            .filter { $0.0 > 0 }
            .map { "\($0.0) \($0.1)" }
    }
}

/// View ▸ Sort Inbox: one untyped note at a time with Idea / Log / Reference / Archive / Trash / Skip.
/// The single-key shortcuts exist only while this sheet is the key window.
struct SortInboxSheet: View {
    static let width: CGFloat = 480
    static let padding: CGFloat = 20

    let model: SortInboxModel
    let open: (String) -> Void
    let close: () -> Void

    @Environment(\.undoManager) private var undoManager
    @State private var confirmsArchiveRest = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let note = model.current {
                sorting(note)
            } else {
                finished
            }
        }
        .padding(Self.padding)
        .frame(width: Self.width)
        .alert(SortInboxStrings.archiveRestTitle(model.remaining), isPresented: $confirmsArchiveRest) {
            Button("Archive") { model.archiveRest(undoManager: undoManager) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(SortInboxStrings.archiveRestMessage)
        }
    }

    private func sorting(_ note: NoteListItem) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Sort Inbox").font(.headline)
                Spacer()
                Text(SortInboxStrings.progress(model.progress))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Note \(SortInboxStrings.progress(model.progress))")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(note.title.isEmpty ? "Untitled" : note.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                if !model.preview.isEmpty {
                    Text(model.preview)
                        .foregroundStyle(.secondary)
                        .lineLimit(8)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
            .accessibilityElement(children: .combine)

            SortInboxActions { model.apply($0, undoManager: undoManager) }

            HStack {
                Button("Open") { open(note.id) }
                    .accessibilityLabel("Open note")
                    .help("Open the note in the main window")
                Button("Archive the Rest…") { confirmsArchiveRest = true }
                    .accessibilityLabel("Archive the rest")
                    .help("Archive every note not sorted yet")
                Spacer()
                Button("Done", action: close)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Close Sort Inbox")
            }
        }
    }

    private var finished: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.summary.total == 0 ? "Nothing to sort" : "Inbox sorted").font(.headline)
            ForEach(SortInboxStrings.summaryLines(model.summary), id: \.self) { Text($0) }
            HStack {
                Spacer()
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Close Sort Inbox")
            }
        }
    }
}

/// The six sort buttons. Labels keep their natural width (never "Refere…"); the buttons share the rest equally.
struct SortInboxActions: View {
    let apply: (SortInboxAction) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(NoteType.allCases, id: \.self) { type in
                action(type.displayName, symbol: type.symbol, key: type.sortKey, .type(type))
            }
            action("Archive", symbol: "archivebox", key: "a", .archive)
            action("Move to Trash", title: "Trash", symbol: "trash", key: "t", .trash)
            action("Skip", symbol: "forward", key: "s", .skip)
        }
    }

    private func action(
        _ label: String, title: String? = nil, symbol: String, key: KeyEquivalent, _ action: SortInboxAction
    ) -> some View {
        Button {
            apply(action)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                Text(title ?? label)
                Text(String(key.character).uppercased()).font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .keyboardShortcut(key, modifiers: [])
        .accessibilityLabel(label)
        .help("\(label) (\(String(key.character).uppercased()))")
    }
}

private extension NoteType {
    var symbol: String {
        switch self {
        case .idea: "lightbulb"
        case .log: "clock"
        case .reference: "bookmark"
        }
    }

    /// I, L, R.
    var sortKey: KeyEquivalent {
        switch self {
        case .idea: "i"
        case .log: "l"
        case .reference: "r"
        }
    }
}
