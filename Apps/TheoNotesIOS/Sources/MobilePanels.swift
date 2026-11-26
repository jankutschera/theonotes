// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import SwiftUI
import UIKit

struct MobileQuickOpen: View {
    let library: MobileLibrary
    var navigation: MobileSceneNavigation? = nil
    let chooseTemplate: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var index: QuickOpen?
    @FocusState private var focused: Bool
    var body: some View {
        MobileSheetChrome(title: "Quick Open", leading: { Spacer() }, trailing: { Button("Done") { dismiss() } }) {
            List(index?.results(query: query) ?? []) { result in
                Button {
                    library.perform {
                        switch result.target {
                        case .note(let id):
                            if let navigation { try library.reveal(id, in: navigation) } else { try library.reveal(id) }
                        case .scope(let scope):
                            if let navigation { navigation.scope = scope; navigation.query = ""; navigation.selectedID = nil }
                            else { library.scope = scope; library.query = ""; library.selectedID = nil }
                        case .search(let query):
                            if let navigation { navigation.scope = .notes; navigation.query = query; navigation.selectedID = nil }
                            else { library.scope = .notes; library.query = query; library.selectedID = nil }
                        case .template(let id): chooseTemplate(id)
                        }
                        dismiss()
                    }
                } label: {
                    Label {
                        VStack(alignment: .leading) {
                            Text(result.title.isEmpty ? "Untitled" : result.title).foregroundStyle(.primary)
                            if let detail = result.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                        }
                    } icon: { Image(systemName: result.iconName ?? (result.kind == .tag ? "number" : result.kind == .template ? "doc.badge.plus" : "doc.text")).foregroundStyle(.secondary) }
                }.tint(.primary)
            }
            .safeAreaInset(edge: .top) {
                TextField("Title, #tag, @section, +template", text: $query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().focused($focused)
                    .accessibilityIdentifier("quick-open-query").modifier(MobileSearchFieldLook())
            }
            .task {
                do {
                    let workspace: Workspace?
                    if let navigation { workspace = navigation.workspace } else { workspace = library.workspace }
                    let navigationGeneration = navigation?.queryContextGeneration
                    let generation = library.libraryGeneration
                    let loaded = try await library.database.pool.read { try QuickOpen.load(db: $0, now: .now, workspace: workspace) }
                    try Task.checkCancellation()
                    guard generation == library.libraryGeneration, navigationGeneration == navigation?.queryContextGeneration,
                          !library.appLocked, !library.isClosed,
                          !library.isClosing, !library.libraryOperationBusy else { return }
                    index = loaded; focused = true
                } catch { library.errorMessage = error.localizedDescription }
            }
        }
    }
}

/// Template-only results use the same Unicode folding and fuzzy ranking as Quick Open.
/// Its normal note fallback must never appear in the template picker.
struct MobileTemplateChoices {
    let templates: [TemplateInfo]
    private let index: QuickOpen
    private let byID: [String: TemplateInfo]

    init(templates: [TemplateInfo], index: QuickOpen) {
        self.templates = templates
        self.index = index
        byID = Dictionary(uniqueKeysWithValues: templates.map { ($0.id, $0) })
    }

    func matching(_ query: String) -> [TemplateInfo] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return templates }
        return index.results(query: "+ " + query, limit: templates.count).compactMap { result in
            guard case .template(let id) = result.target else { return nil }
            return byID[id]
        }
    }

    func recent(_ ids: [String], query: String) -> [TemplateInfo] {
        let matches = Set(matching(query).map(\.id))
        var seen = Set<String>()
        return ids.compactMap { id in
            guard matches.contains(id), seen.insert(id).inserted else { return nil }
            return byID[id]
        }
    }

    func selection(current: String?, recentIDs: [String], defaultID: String, query: String) -> String? {
        let matches = matching(query), valid = Set(matches.map(\.id))
        if let current, valid.contains(current) { return current }
        return recentIDs.first(where: valid.contains) ?? (valid.contains(defaultID) ? defaultID : matches.first?.id)
    }
}

struct MobileTemplatePicker: View {
    let library: MobileLibrary
    var initialID: String?
    var navigation: MobileSceneNavigation? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var choices: MobileTemplateChoices?
    @State private var query = ""
    @State private var defaultTemplateID = ""
    @State private var selection: String?
    @State private var title = ""
    @State private var clipboard = ""
    @State private var needsTitle = false
    @State private var needsClipboard = false
    var body: some View {
        MobileSheetChrome(title: "New from Template", leading: { Button("Cancel") { dismiss() } }, trailing: {
            Button("Create") {
                guard let selection, matchingTemplates.contains(where: { $0.id == selection }) else { return }
                library.perform {
                    if let navigation { try library.createFromTemplate(selection, title: title, clipboard: clipboard, in: navigation) }
                    else { try library.createFromTemplate(selection, title: title, clipboard: clipboard) }
                    dismiss()
                }
            }.buttonStyle(.glassProminent).disabled(selection == nil)
        }) {
            Form {
                if choices?.templates.isEmpty != false {
                    ContentUnavailableView("No templates yet", systemImage: "doc.badge.plus",
                        description: Text("Tag a note #template to reuse it. Placeholders include {{date}}, {{title}}, {{clipboard}} and {{cursor}}."))
                } else if matchingTemplates.isEmpty {
                    ContentUnavailableView("No matching templates", systemImage: "magnifyingglass",
                        description: Text("Try another title or clear the search."))
                }
                if !recentTemplates.isEmpty {
                    Section("Recent Templates") {
                        ForEach(recentTemplates) { template in templateRow(template) }
                    }
                }
                Section(query.isEmpty ? "All Templates" : "Matching Templates") {
                    ForEach(matchingTemplates) { template in
                        templateRow(template)
                    }
                }
                if needsTitle { Section("New Note Title") { TextField("Title", text: $title) } }
                if needsClipboard {
                    Section {
                        TextEditor(text: $clipboard).frame(minHeight: 80)
                        PasteButton(payloadType: String.self) { clipboard = $0.joined(separator: "\n") }
                    } header: { Text("Clipboard placeholder") } footer: { Text("Paste the text you want to insert. Your clipboard is read only when you tap Paste.") }
                }
            }
            .safeAreaInset(edge: .top) {
                TextField("Search template titles", text: $query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("template-search").modifier(MobileSearchFieldLook())
            }
            .onChange(of: query) { _, _ in reconcileSelection() }
            .task {
                library.perform {
                    choices = try library.database.pool.read { db in
                        MobileTemplateChoices(templates: try Templates.list(db: db), index: try QuickOpen.load(db: db, now: .now))
                    }
                    defaultTemplateID = try library.settings.value(.startNoteTemplate)
                    selection = initialID
                    reconcileSelection()
                }
            }
        }
    }
    private var matchingTemplates: [TemplateInfo] { choices?.matching(query) ?? [] }
    private var recentTemplates: [TemplateInfo] {
        choices?.recent(library.preferences.recentTemplateIDs, query: query) ?? []
    }
    private func reconcileSelection() {
        selection = choices?.selection(current: selection, recentIDs: library.preferences.recentTemplateIDs,
            defaultID: defaultTemplateID, query: query)
        inspect()
    }
    private func templateRow(_ template: TemplateInfo) -> some View {
        Button { selection = template.id; inspect() } label: {
            HStack { Text(template.title.isEmpty ? "Untitled" : template.title); Spacer(); if selection == template.id { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) } }
        }.tint(.primary)
    }
    private func inspect() {
        needsTitle = false
        needsClipboard = false
        library.perform {
            guard let selection, let note = try library.store.note(id: selection) else { return }
            needsTitle = Templates.instantiate(templateText: note.text, context: TemplateContext()).needsTitle
            needsClipboard = note.text.contains("{{clipboard}}")
        }
    }
}

struct MobileTagEditor: View {
    let library: MobileLibrary
    let tag: TagNode
    var navigation: MobileSceneNavigation? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var icon = "number"
    @State private var deleting = false
    var body: some View {
        NavigationStack {
            Form {
                TextField("Tag path", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("Icon", selection: $icon) {
                    ForEach(["number", "star", "heart", "house", "briefcase", "book", "person", "lightbulb", "leaf", "airplane", "flag", "folder"], id: \.self) { value in Label(value, systemImage: value).tag(value) }
                }
                Button("Use as Workspace", systemImage: "rectangle.3.group") { library.perform { if let navigation { try library.enterWorkspace(tag.path, in: navigation) } else { try library.enterWorkspace(tag.path) }; dismiss() } }
                Button(tag.isPinned ? "Unpin Tag" : "Pin Tag", systemImage: "pin") {
                    library.perform { try library.store.setTagPinned(tag.path, pinned: !tag.isPinned); dismiss() }
                }
                Section {
                    Button("Delete Tag", role: .destructive) { deleting = true }
                } footer: { Text("Renaming or deleting a tag updates its occurrences in editable notes, including subtags. Locked and read-only notes are preserved. Your notes are kept.") }
            }
            .navigationTitle("Edit Tag")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        library.perform {
                            if name != tag.path {
                                if let navigation { try library.renameTag(tag.path, to: name, in: navigation) }
                                else { try library.renameTag(tag.path, to: name) }
                            }
                            try library.store.setTagIcon(name, symbol: icon == "number" ? nil : icon)
                            dismiss()
                        }
                    }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { name = tag.path; icon = tag.iconName ?? "number" }
            .confirmationDialog("Remove #\(tag.path) from editable notes?", isPresented: $deleting) {
                Button("Delete Tag", role: .destructive) { library.perform { if let navigation { try library.deleteTag(tag.path, in: navigation) } else { try library.deleteTag(tag.path) }; dismiss() } }
            }
        }
    }
}

struct MobileInfoPanel: View {
    let library: MobileLibrary
    let editor: MobileEditor
    var navigation: MobileSceneNavigation? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var backlinks = Backlinks()
    @State private var statistics = NoteStatistics.zero
    @State private var headings: [HeadingRef] = []
    @State private var modified: Date?
    @State private var noteType: NoteType?
    @State private var canChangeType = false
    @State private var typeUnavailableReason = "Wait until the note is ready to change its type."
    @State private var changingType = false
    @State private var typeError: String?
    var body: some View {
        MobileSheetChrome(title: "Note Info", leading: { Spacer() }, trailing: { Button("Done") { dismiss() }.disabled(changingType) }) {
            List {
                Section("Type") {
                    // A standard picker row (label primary, value secondary); "No Type" removes the type.
                    Picker("Note Type", selection: Binding(get: { noteType }, set: { changeType($0) })) {
                        Text("No Type").tag(NoteType?.none)
                        ForEach(NoteType.allCases, id: \.self) { type in Text(type.displayName).tag(NoteType?.some(type)) }
                    }
                    .disabled(!canChangeType || changingType)
                    .accessibilityIdentifier("note-type-menu")
                    if changingType { ProgressView("Changing type…") }
                    if !canChangeType { Text(typeUnavailableReason).font(.footnote).foregroundStyle(.secondary) }
                }
                Section("Statistics") {
                    LabeledContent("Words", value: statistics.words.formatted())
                    LabeledContent("Characters", value: statistics.characters.formatted())
                    LabeledContent("Paragraphs", value: statistics.paragraphs.formatted())
                    LabeledContent("Reading Time", value: "\(max(1, Int(ceil(Double(statistics.readingSeconds) / 60)))) min")
                    if let modified { LabeledContent("Modified") { Text(modified, format: .dateTime) } }
                }
                if let selected = editor.selectedText, !selected.isEmpty {
                    let stats = NoteStatistics.of(selected)
                    Section("Selection") {
                        LabeledContent("Words", value: stats.words.formatted())
                        LabeledContent("Characters", value: stats.characters.formatted())
                        LabeledContent("Paragraphs", value: stats.paragraphs.formatted())
                    }
                }
                Section("Contents") {
                    if headings.isEmpty { Text("No headings").foregroundStyle(.secondary) }
                    ForEach(Array(headings.enumerated()), id: \.offset) { index, heading in
                        Button { editor.scrollToHeading(index); dismiss() } label: {
                            Text(heading.text).padding(.leading, CGFloat(max(0, heading.level - 1) * 12))
                        }
                    }
                }
                Section("Backlinks") {
                    if backlinks.linked.isEmpty { Text("No linked mentions").foregroundStyle(.secondary) }
                    ForEach(backlinks.linked) { note in mentionRow(note, linkable: false) }
                    if backlinks.linkedTruncated { Text("Showing the first \(Backlinks.linkedNoteLimit) linking notes").font(.caption) }
                }
                Section("Unlinked Mentions") {
                    if backlinks.unlinked.isEmpty { Text("No unlinked mentions").foregroundStyle(.secondary) }
                    ForEach(backlinks.unlinked) { note in mentionRow(note, linkable: backlinks.canLink && note.canLink) }
                    if backlinks.unlinkedTruncated { Text("More mentions may exist beyond the search limit.").font(.caption) }
                }
            }
            .alert("Unable to Change Type", isPresented: Binding(get: { typeError != nil }, set: { if !$0 { typeError = nil } })) {
                Button("OK", role: .cancel) { typeError = nil }
            } message: { Text(typeError ?? "") }
            .task { await refresh() }
        }
        .interactiveDismissDisabled(changingType)
    }
    private func mentionRow(_ note: MentioningNote, linkable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(note.title.isEmpty ? "Untitled" : note.title) { library.perform { if let navigation { try library.reveal(note.id, in: navigation) } else { try library.reveal(note.id) }; dismiss() } }
            ForEach(note.mentions) { mention in
                HStack {
                    Text(mention.snippet).font(.caption).foregroundStyle(.secondary)
                    if linkable {
                        Button("Link") {
                            library.perform {
                                try library.flush()
                                if let id = editor.session?.noteId { try library.store.linkMention(mention, to: id) }
                                try library.refreshSessions()
                            }
                            Task { await refresh() }
                        }.buttonStyle(.bordered)
                    }
                }
            }
        }
    }
    private func refresh() async {
        guard let session = editor.session else { return }
        do {
            try library.flush()
            let note = try library.store.note(id: session.noteId)
            let text = note.map(library.canRead) == true ? session.text : ""
            noteType = NoteType.of(directTags: NoteParser.metadata(for: text).tags)
            canChangeType = note?.isLocked == false && note?.isReadOnly == false && editor.editable
            typeUnavailableReason = note?.isLocked == true ? "Unlock the note to change its type."
                : note?.location == .archive ? "Restore the note from Archive to change its type."
                : note?.location == .trash ? "Restore the note from Trash to change its type."
                : note?.isReadOnly == true ? "Allow editing to change this note’s type."
                : "Wait until the note is ready to change its type."
            statistics = NoteStatistics.of(text)
            headings = NoteParser.metadata(for: text).headings
            modified = note?.modifiedAt
            backlinks = try await library.store.backlinksInBackground(to: session.noteId)
        } catch { library.errorMessage = error.localizedDescription }
    }
    private func changeType(_ type: NoteType?) {
        changingType = true
        Task {
            do { try await editor.setNoteType(type); dismiss() }
            catch { typeError = error.localizedDescription }
            changingType = false
        }
    }
}
