// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

extension SidebarScope {
    var displayName: String {
        switch self {
        case .notes: "Notes"
        case .inbox: "Inbox"
        case .type(let type): type.sidebarName
        case .pinned: "Pinned"
        case .untagged: "Untagged"
        case .todo: "To Do"
        case .today: "Today"
        case .locked: "Locked"
        case .archive: "Archive"
        case .trash: "Trash"
        case .tag(let path): path
        }
    }

    var systemImage: String {
        switch self {
        case .notes: "note.text"
        case .inbox: "tray"
        case .type(let type): type.sidebarSymbol
        case .pinned: "pin"
        case .untagged: "tag.slash"
        case .todo: "checklist"
        case .today: "calendar"
        case .locked: "lock"
        case .archive: "archivebox"
        case .trash: "trash"
        case .tag: "number"
        }
    }
}

extension NoteType {
    var sidebarName: String {
        switch self {
        case .idea: "Ideas"
        case .log: "Logs"
        case .reference: "References"
        }
    }

    var sidebarSymbol: String {
        switch self {
        case .idea: "lightbulb"
        case .log: "clock"
        case .reference: "bookmark"
        }
    }
}

extension TagNode {
    /// `OutlineGroup` children: nil for a leaf, so it gets no disclosure triangle.
    var childNodes: [TagNode]? { children.isEmpty ? nil : children }

    /// The tag's own icon when it names an SF Symbol, else its default TagCon (keyword match on
    /// the last path component, else `number`).
    var symbolName: String {
        if let iconName, NSImage(systemSymbolName: iconName, accessibilityDescription: nil) != nil {
            return iconName
        }
        return TagIcons.defaultSymbol(forTagPath: path)
    }
}

extension UTType {
    /// Declared in Info.plist (`UTExportedTypeDeclarations`).
    static let baerchenTagPath = UTType(exportedAs: LegacyNames.tagPathUTI)
}

/// A sidebar tag being dragged (onto another tag, to nest it there).
struct TagDragItem: Codable, Equatable, Transferable {
    var path: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .baerchenTagPath)
    }
}

/// What a sidebar tag accepts: notes (they get the tag) or another tag (it moves below).
enum SidebarDropItem: Transferable {
    case notes([String])
    case tag(String)

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(importing: { (item: NoteDragItem) in SidebarDropItem.notes(item.noteIDs) })
        ProxyRepresentation(importing: { (item: TagDragItem) in SidebarDropItem.tag(item.path) })
    }
}

/// Tag commands that ask first.
enum TagConfirmation: Identifiable, Equatable {
    case delete(path: String, noteCount: Int)
    case nest(child: String, newPath: String, noteCount: Int)

    var id: String {
        switch self {
        case .delete(let path, _): "delete:" + path
        case .nest(let child, let newPath, _): "nest:" + child + ">" + newPath
        }
    }

    var title: String {
        switch self {
        case .delete(let path, _): "Delete Tag “\(path)”?"
        case .nest(let child, let newPath, _): "Move “\(child)” to “\(newPath)”?"
        }
    }

    var message: String {
        switch self {
        case .delete(_, let count):
            "The tag is removed from \(Self.notes(count)). The notes themselves are kept."
        case .nest(let child, let newPath, let count):
            "\(Self.token(child)) becomes \(Self.token(newPath)) in \(Self.notes(count))."
        }
    }

    var confirmTitle: String {
        switch self {
        case .delete: "Delete Tag"
        case .nest: "Move"
        }
    }

    var isDestructive: Bool {
        if case .delete = self { true } else { false }
    }

    private static func token(_ path: String) -> String {
        (try? NoteStore.tagToken(path).token) ?? "#" + path
    }

    private static func notes(_ count: Int) -> String {
        count == 1 ? "1 note" : "\(count) notes"
    }
}

/// The tag the Edit Tag sheet is open for.
struct TagEditRequest: Identifiable, Equatable {
    var path: String
    var iconName: String?
    var id: String { path }
}

/// Fixed sections, then the tags (pinned root tags first) as an outline (spec §4.2). In a
/// workspace the Notes row shows the workspace's name with the switcher menu.
struct SidebarView: View {
    let model: LibraryModel
    let showNoteCounts: Bool
    var pane: FocusState<Pane?>.Binding
    /// A tag's Export Notes…; nil while an import or export runs (the item is disabled).
    var exportTag: ((String) -> Void)?
    /// The Trash row's Empty Trash…: asks first, like File ▸ Empty Trash…
    var emptyTrash: (() -> Void)?

    @State private var dropTargetTag: String?
    @State private var editing: TagEditRequest?
    @State private var confirmation: TagConfirmation?
    @Environment(\.undoManager) private var undoManager
    @Environment(\.shellPalette) private var palette

    /// The fixed entries above the tag tree, in order.
    static let fixedScopes: [SidebarScope] = [
        .notes, .inbox, .type(.idea), .type(.log), .type(.reference),
        .pinned, .untagged, .todo, .today, .locked, .archive, .trash,
    ]

    static func count(for scope: SidebarScope, in counts: SidebarCounts) -> Int {
        switch scope {
        case .notes: counts.notes
        case .inbox: counts.inbox
        case .type(.idea): counts.ideas
        case .type(.log): counts.logs
        case .type(.reference): counts.references
        case .pinned: counts.pinned
        case .untagged: counts.untagged
        case .todo: counts.todo
        case .today: counts.today
        case .locked: counts.locked
        case .archive: counts.archive
        case .trash: counts.trash
        case .tag: 0
        }
    }

    /// Pinned, Locked and Archive only appear once they hold a note.
    static func isShown(_ scope: SidebarScope, in counts: SidebarCounts) -> Bool {
        switch scope {
        case .pinned, .locked, .archive: count(for: scope, in: counts) > 0
        default: true
        }
    }

    var body: some View {
        let counts = model.counts
        List(selection: Binding(get: { model.scope }, set: { if let scope = $0 { model.selectScope(scope) } })) {
            Section {
                ForEach(Self.fixedScopes, id: \.self) { scope in
                    if scope == .notes, let workspace = model.workspace {
                        workspaceRow(workspace, count: counts.notes)
                    } else if Self.isShown(scope, in: counts) {
                        row(scope, count: Self.count(for: scope, in: counts))
                    }
                }
            }
            if !model.tagTree.isEmpty {
                Section("Tags") {
                    OutlineGroup(orderedTags, children: \.childNodes) { tag in
                        tagRow(tag)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // System sidebar glass and system selection (no theme tint: the system draws the selection
        // fill and its text); opaque only when the palette says so.
        .modifier(OpaqueSidebarBackground(palette: palette))
        .focused(pane, equals: .sidebar)
        // → on a section row or a leaf tag moves to the note list (← from the list comes back);
        // a parent tag keeps the system's expand (M7 Task 12).
        .onKeyPress(.rightArrow) {
            guard Self.rightArrowMovesToTheList(scope: model.scope, isParentTag: { Self.isParent($0, in: model.tagTree) }) else {
                return .ignored
            }
            pane.wrappedValue = .noteList
            return .handled
        }
        .accessibilityRotor("Tags") {
            ForEach(Self.flattened(orderedTags)) { tag in
                AccessibilityRotorEntry(tag.path, id: tag.id)
            }
        }
        .sheet(item: $editing) { request in
            TagEditSheet(request: request) { newPath, icon in
                save(request, newPath: newPath, icon: icon)
            }
        }
        .alert(
            confirmation?.title ?? "",
            isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
            presenting: confirmation
        ) { action in
            Button(action.confirmTitle, role: action.isDestructive ? .destructive : nil) { perform(action) }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: { action in
            Text(action.message)
        }
    }

    private func save(_ request: TagEditRequest, newPath: String, icon: String?) {
        var target = request.path
        if newPath != request.path, model.renameTag(request.path, to: newPath, undoManager: undoManager) {
            target = newPath
        }
        if icon != request.iconName { model.setTagIcon(target, symbol: icon) }
    }

    private func perform(_ action: TagConfirmation) {
        confirmation = nil
        switch action {
        case .delete(let path, _): model.deleteTag(path, undoManager: undoManager)
        case .nest(let child, let newPath, _): model.renameTag(child, to: newPath, undoManager: undoManager)
        }
    }

    @ViewBuilder
    private func tagMenu(_ tag: TagNode) -> some View {
        Button("Edit Tag…") { editing = TagEditRequest(path: tag.path, iconName: tag.iconName) }
        if LibraryModel.canPin(tag) {
            Button(tag.isPinned ? "Unpin Tag" : "Pin Tag") { model.setTagPinned(tag.path, pinned: !tag.isPinned) }
        }
        Button("Set as Workspace") { model.enterWorkspace(tag.path) }
            .disabled(model.workspace == Workspace(path: tag.path) || NoteType.isReservedWorkspace(path: tag.path))
        Button("Export Notes…") { exportTag?(tag.path) }
            .disabled(exportTag == nil)
        Divider()
        Button("Delete Tag…") {
            confirmation = .delete(path: tag.path, noteCount: model.noteCount(forTag: tag.path))
        }
    }

    /// Whether → leaves the sidebar for the note list: every row but a tag with child tags.
    static func rightArrowMovesToTheList(scope: SidebarScope, isParentTag: (String) -> Bool) -> Bool {
        guard case .tag(let path) = scope else { return true }
        return !isParentTag(path)
    }

    /// Whether the tag at `path` has child tags.
    static func isParent(_ path: String, in nodes: [TagNode]) -> Bool {
        for node in nodes {
            if node.path == path { return !node.children.isEmpty }
            if isParent(path, in: node.children) { return true }
        }
        return false
    }

    /// The tags in sidebar order, children after their parent (the Tags rotor).
    static func flattened(_ nodes: [TagNode]) -> [TagNode] {
        nodes.flatMap { [$0] + flattened($0.children) }
    }

    private var orderedTags: [TagNode] {
        model.tagTree.filter(\.isPinned) + model.tagTree.filter { !$0.isPinned }
    }

    /// The Notes row in a workspace: the tag's name and icon, and the ⇅ menu with
    /// Notes (leave), the pinned root tags and the recent workspaces.
    private func workspaceRow(_ workspace: Workspace, count: Int) -> some View {
        HStack {
            Label {
                Text(model.workspaceTitle ?? workspace.path)
            } icon: {
                Image(systemName: workspaceSymbol(workspace))
            }
            Spacer(minLength: 4)
            Menu {
                WorkspaceMenuItems(model: model)
            } label: {
                Image(systemName: "chevron.up.chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Switch Workspace")
            .accessibilityLabel("Switch Workspace")
        }
        .badge(showNoteCounts ? count : 0)
        .tag(SidebarScope.notes)
    }

    private func workspaceSymbol(_ workspace: Workspace) -> String {
        model.workspaceNode?.symbolName ?? TagIcons.defaultSymbol(forTagPath: workspace.path)
    }

    private func row(_ scope: SidebarScope, count: Int) -> some View {
        Label(scope.displayName, systemImage: scope.systemImage)
            .badge(showNoteCounts ? count : 0)
            .tag(scope)
            .contextMenu {
                if scope == .trash {
                    Button(SidebarView.emptyTrashTitle) { emptyTrash?() }
                        .disabled(emptyTrash == nil || count == 0)
                }
            }
    }

    static let emptyTrashTitle = "Empty Trash…"

    private func tagRow(_ tag: TagNode) -> some View {
        Label {
            Text(tag.name)
        } icon: {
            Image(systemName: tag.symbolName)
        }
        .badge(showNoteCounts ? tag.noteCount : 0)
        .tag(SidebarScope.tag(tag.path))
        .id(tag.id)
        .listRowBackground(
            dropTargetTag == tag.id
                ? RoundedRectangle(cornerRadius: 6).fill(palette.accent.opacity(0.25)).padding(.horizontal, 8)
                : nil
        )
        .draggable(TagDragItem(path: tag.path))
        .contextMenu { tagMenu(tag) }
        .dropDestination(for: SidebarDropItem.self) { items, _ in
            var handled = false
            let ids = items.flatMap { item -> [String] in
                if case .notes(let ids) = item { ids } else { [] }
            }
            if !ids.isEmpty {
                model.addTag(tag.path, toNoteIDs: ids)
                handled = true
            }
            for case .tag(let child) in items {
                guard let newPath = LibraryModel.nestedPath(child, into: tag.path) else { continue }
                confirmation = .nest(child: child, newPath: newPath, noteCount: model.noteCount(forTag: child))
                handled = true
                break
            }
            return handled
        } isTargeted: { targeted in
            if targeted {
                dropTargetTag = tag.id
            } else if dropTargetTag == tag.id {
                dropTargetTag = nil
            }
        }
    }
}

/// The workspace switcher (spec §4.2): Notes leaves the workspace; then the pinned root tags and
/// the recently used workspaces, the current one checked.
struct WorkspaceMenuItems: View {
    let model: LibraryModel

    var body: some View {
        Button("Notes") { model.dismissWorkspace() }
        let choices = model.workspaceChoices
        if !choices.pinned.isEmpty {
            Section("Pinned") {
                ForEach(choices.pinned, id: \.key) { item($0) }
            }
        }
        if !choices.recent.isEmpty {
            Section("Recent") {
                ForEach(choices.recent, id: \.key) { item($0) }
            }
        }
    }

    /// A menu toggle shows the checkmark; choosing the current workspace again keeps it.
    private func item(_ workspace: Workspace) -> some View {
        Toggle(workspace.path, isOn: Binding(
            get: { model.workspace == workspace },
            set: { if $0 { model.enterWorkspace(workspace.path) } }
        ))
    }
}

/// The theme background in place of the sidebar glass, for `ShellPalette.sidebarIsOpaque`.
private struct OpaqueSidebarBackground: ViewModifier {
    let palette: ShellPalette

    func body(content: Content) -> some View {
        if palette.sidebarIsOpaque {
            content.scrollContentBackground(.hidden).background(palette.background)
        } else {
            content
        }
    }
}
