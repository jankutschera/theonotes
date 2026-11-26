// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import SwiftUI
import UIKit
import TheoNotesCore

struct MobileSortInboxSheet: View {
    let model: MobileSortInboxModel
    let library: MobileLibrary
    var navigation: MobileSceneNavigation? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager
    @Environment(\.scenePhase) private var phase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var busy = false
    @State private var confirmingArchive = false
    @State private var archiveCount = 0
    @State private var errorMessage: String?
    @State private var availableWidth: CGFloat = 0
    private var useWideActions: Bool {
        availableWidth >= 450 && (horizontalSizeClass == .regular || UIDevice.current.userInterfaceIdiom == .pad) && dynamicTypeSize <= .large
    }

    var body: some View {
        let _ = library.snapshot
        // Undo leading, Done trailing, as in iOS.
        return MobileSheetChrome(title: "Sort Inbox", leading: {
            if busy || model.undoing {
                ProgressView().accessibilityLabel("Saving sort action")
            } else {
                Button("Undo", systemImage: "arrow.uturn.backward") { undo() }
                    .labelStyle(.iconOnly)
                    .disabled(!model.canUndo)
                    .keyboardShortcut("z")
            }
        }, trailing: {
            Button("Done") { dismiss() }.disabled(busy || model.undoing)
        }) {
            List {
                if let item = model.current {
                    Section {
                        if let note = try? library.store.note(id: item.id), !note.isLocked {
                            Text(note.title.isEmpty ? "Untitled" : note.title).font(.headline)
                            let lines = note.text.prefix(4096).split(separator: "\n", omittingEmptySubsequences: true).dropFirst().prefix(6)
                            if !lines.isEmpty { Text(String(lines.joined(separator: "\n").prefix(600))).foregroundStyle(.secondary).lineLimit(8) }
                            Button("Open Note", systemImage: "arrow.up.right.square") {
                                library.perform { if let navigation { try library.reveal(item.id, in: navigation) } else { try library.reveal(item.id) }; dismiss() }
                            }
                        } else {
                            Text("This note is no longer available to sort.").foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("\(min(model.completed + 1, model.total)) of \(model.total)")
                    }
                    Section("Choose a Type") {
                        if useWideActions {
                            HStack {
                                ForEach(NoteType.allCases, id: \.self) { type in typeButton(type, expanded: true) }
                            }.buttonStyle(.borderless)
                        } else {
                            ForEach(NoteType.allCases, id: \.self) { type in typeButton(type) }
                        }
                    }
                    Section {
                        if useWideActions {
                            HStack {
                                actionButton("Archive", symbol: "archivebox", key: "a", action: .archive, expanded: true)
                                actionButton("Move to Trash", symbol: "trash", role: .destructive, key: "t", action: .trash, expanded: true)
                                actionButton("Skip", symbol: "forward", key: "s", action: .skip, expanded: true)
                            }.buttonStyle(.borderless)
                        } else {
                            actionButton("Archive", symbol: "archivebox", key: "a", action: .archive)
                            actionButton("Move to Trash", symbol: "trash", role: .destructive, key: "t", action: .trash)
                            actionButton("Skip", symbol: "forward", key: "s", action: .skip)
                        }
                    }
                    Section {
                        Button("Archive the Rest…", systemImage: "archivebox") {
                            do { archiveCount = try model.eligibleRemaining(); confirmingArchive = true }
                            catch { errorMessage = error.localizedDescription }
                        }.disabled(model.remaining == 0)
                    }
                } else {
                    Section {
                        Text(model.completed == 0 ? "Nothing to sort" : "Inbox sorted").font(.headline)
                        if model.summary.typed > 0 { Text("\(model.summary.typed) typed") }
                        if model.summary.archived > 0 { Text("\(model.summary.archived) archived") }
                        if model.summary.trashed > 0 { Text("\(model.summary.trashed) moved to Trash") }
                        if model.summary.skipped > 0 { Text("\(model.summary.skipped) skipped") }
                    }
                }
            }
            .privacySensitive()
            .disabled(busy || model.undoing)
            .confirmationDialog("Archive \(archiveCount) \(archiveCount == 1 ? "note" : "notes")?", isPresented: $confirmingArchive, titleVisibility: .visible) {
                Button("Archive") { archiveRest() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("They stay searchable and can be restored.") }
            .alert("Unable to Sort", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .onChange(of: phase) { _, state in
                if state != .active { model.invalidate(); dismiss() }
            }
            .onChange(of: library.appLocked) { _, locked in
                if locked { model.invalidate(); dismiss() }
            }
            .onChange(of: model.notice) { _, notice in
                if let notice { errorMessage = notice; model.notice = nil }
            }
        }
        .interactiveDismissDisabled(busy || model.undoing)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { availableWidth = $0 }
    }

    private func symbol(_ type: NoteType) -> String {
        switch type { case .idea: "lightbulb"; case .log: "clock"; case .reference: "bookmark" }
    }
    private func sortKey(_ type: NoteType) -> KeyEquivalent {
        switch type { case .idea: "i"; case .log: "l"; case .reference: "r" }
    }
    private func typeButton(_ type: NoteType, expanded: Bool = false) -> some View {
        actionButton(type.displayName, symbol: symbol(type), key: sortKey(type), action: .type(type), expanded: expanded)
    }
    private func actionButton(_ title: String, symbol: String, role: ButtonRole? = nil, key: KeyEquivalent,
                              action: MobileSortInboxModel.Action, expanded: Bool = false) -> some View {
        Button(role: role) { run(action) } label: {
            Label(title, systemImage: symbol)
                .frame(maxWidth: expanded ? .infinity : nil, minHeight: expanded ? 44 : nil, alignment: .leading)
                .contentShape(Rectangle())
        }.keyboardShortcut(key, modifiers: [])
    }
    private func run(_ action: MobileSortInboxModel.Action) {
        busy = true
        Task {
            let previous = model.historyCount
            do {
                try await model.apply(action)
            } catch { errorMessage = error.localizedDescription }
            if model.historyCount > previous { model.registerUndo(undoManager) }
            busy = false
        }
    }
    private func archiveRest() {
        busy = true
        Task {
            let previous = model.historyCount
            do { _ = try await model.archiveRest(expectedCount: archiveCount) }
            catch { errorMessage = error.localizedDescription }
            if model.historyCount > previous { model.registerUndo(undoManager) }
            busy = false
        }
    }
    private func undo() {
        if let undoManager, undoManager.canUndo { undoManager.undo(); return }
        busy = true
        Task { do { try await model.undo() } catch { errorMessage = error.localizedDescription }; busy = false }
    }
}
