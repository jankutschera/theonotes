// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import SwiftUI

/// Edit Tag (inventory §2.3): the tag's full path (renaming `b` to `a/b` nests it) and its
/// TagCon, picked from a searchable SF Symbol grid. "Default" goes back to the keyword icon.
struct TagEditSheet: View {
    let request: TagEditRequest
    let onSave: (_ newPath: String, _ icon: String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var icon: String?
    @State private var query = ""
    @FocusState private var nameFocused: Bool

    init(request: TagEditRequest, onSave: @escaping (_ newPath: String, _ icon: String?) -> Void) {
        self.request = request
        self.onSave = onSave
        _name = State(initialValue: request.path)
        _icon = State(initialValue: request.iconName)
    }

    /// The name as it would be written, `nil` when it is not a valid tag.
    private var normalizedName: String? {
        try? NoteStore.tagToken(name).name
    }

    /// A valid tag name that does not move the tag into its own subtree (`work` → `work/sub`).
    static func canSave(name: String, originalPath: String) -> Bool {
        guard let normalized = try? NoteStore.tagToken(name).name else { return false }
        return !NoteStore.isRenameIntoOwnSubtree(originalPath, to: normalized)
    }

    private var shownSymbol: String {
        TagIcons.symbol(forTagPath: normalizedName ?? request.path, iconName: icon)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Tag").font(.headline)
            HStack(spacing: 10) {
                Image(systemName: shownSymbol)
                    .font(.title2)
                    .frame(width: 32, height: 32)
                    .foregroundStyle(.tint)
                TextField("Tag name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit(save)
            }
            TextField("Search icons", text: $query)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 34), spacing: 6)], spacing: 6) {
                    symbolButton(nil)
                    ForEach(TagIcons.searchSymbols(query), id: \.self) { symbolButton($0) }
                }
                .padding(4)
            }
            .frame(height: 220)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!Self.canSave(name: name, originalPath: request.path))
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { nameFocused = true }
    }

    /// `nil` is the Default swatch (the keyword icon for the current name).
    private func symbolButton(_ symbol: String?) -> some View {
        let selected = icon == symbol
        let shown = symbol ?? TagIcons.defaultSymbol(forTagPath: normalizedName ?? request.path)
        return Button {
            icon = symbol
        } label: {
            Image(systemName: shown)
                .font(.title3)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected ? Color.accentColor.opacity(0.3) : Color.clear)
                )
                .overlay(alignment: .bottomTrailing) {
                    if symbol == nil {
                        Image(systemName: "wand.and.stars").font(.caption2).imageScale(.small).padding(2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(symbol ?? "Default")
        .accessibilityLabel(symbol ?? "Default icon")
    }

    private func save() {
        guard Self.canSave(name: name, originalPath: request.path), let newName = normalizedName else { return }
        onSave(newName, icon)
        dismiss()
    }
}
