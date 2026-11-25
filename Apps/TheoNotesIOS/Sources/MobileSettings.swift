// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import SwiftUI

struct MobileSettings: View {
    @Bindable var library: MobileLibrary
    /// Shows the notes with a tag in the note list (the library view owns the scene's scope).
    var showTag: (String) -> Void = { _ in }
    @State private var gettingStartedNotice: (title: String, text: String)?
    @Environment(\.dismiss) private var dismiss
    /// Present only in a build that offers iCloud sync; the row below is not built otherwise.
    @Environment(MobileCloudSyncController.self) private var cloud: MobileCloudSyncController?
    @State private var hideMarkdown = true
    @State private var autocomplete = true
    @State private var autoSortTodos = false
    @State private var showCounts = true
    @State private var showHeadingLevels = true
    @State private var typewriterMode = false
    @State private var sort = NoteSort.modifiedDescending
    @State private var tagPosition = TagPosition.bottom
    @State private var template = ""
    @State private var templates: [TemplateInfo] = []
    @State private var loaded = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { generalPage } label: { Label("General", systemImage: "slider.horizontal.3") }
                    NavigationLink { MobileTypographySettings(library: library) } label: { Label("Typography", systemImage: "textformat.size") }
                }
                Section {
                    NavigationLink { privacyPage } label: { Label("Privacy", systemImage: "lock") }
                    NavigationLink { MobileThemeSettings(library: library) } label: { Label("Themes", systemImage: "paintpalette") }
                    // REL-R5/R6: the private-server page is only linked, and its controller only made, in a build that offers it.
                    if let sync = MobilePrivateServerSync.controller(for: library) {
                        NavigationLink { MobileSyncSettings(sync: sync, library: library).onAppear { save() } } label: { Label("Sync", systemImage: "icloud") }
                    }
                    if let cloud {
                        NavigationLink { MobileCloudSyncSettings(controller: cloud, library: library) } label: {
                            Label(MobileCloudSyncStrings.pageTitle, systemImage: "externaldrive.badge.icloud")
                        }
                    }
                }
                Section {
                    NavigationLink { MobileAdvancedSettings(library: library).onAppear { save() } } label: { Label("Advanced", systemImage: "gearshape.2") }
                    NavigationLink { MobileAcknowledgements() } label: { Label("Acknowledgements", systemImage: "doc.text") }
                        .accessibilityIdentifier("settings-acknowledgements")
                    Link(destination: URL(string: "https://theonotes.app/privacy/")!) { Label("Privacy Policy", systemImage: "hand.raised") }
                        .accessibilityIdentifier("settings-privacy-policy")
                    Link(destination: URL(string: "https://theonotes.app/support/")!) { Label("Support", systemImage: "questionmark.circle") }
                        .accessibilityIdentifier("settings-support")
                    Link(destination: ProjectLinks.sourceRepository) { Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right") }
                        .accessibilityIdentifier("settings-source-code")
                    Button { restoreGettingStarted() } label: { Label(MobileGettingStarted.title, systemImage: "lifepreserver") }
                        .disabled(!library.canRestoreGettingStarted)
                        .accessibilityIdentifier("settings-restore-getting-started")
                } footer: {
                    Text(ProjectLinks.sourceOffer)
                        .accessibilityIdentifier("settings-source-offer")
                }
                if let sharingError = library.sharingError {
                    Section("Sharing") { Text(sharingError).foregroundStyle(.secondary) }
                }
                Section {
                    Text("A quiet place for your notes.").font(.headline)
                    Text("True Brew Birdie Ltd.").foregroundStyle(.secondary)
                    LabeledContent("Version", value: Self.version)
                }
            }
            .navigationTitle("Settings")
            .alert(gettingStartedNotice?.title ?? "", isPresented: Binding(get: { gettingStartedNotice != nil }, set: { if !$0 { gettingStartedNotice = nil } })) {
                Button("OK") {}
            } message: { Text(gettingStartedNotice?.text ?? "") }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { save(); dismiss() } } }
            .onAppear {
                guard !loaded else { return }
                library.perform {
                    let settings = try library.settings.snapshot()
                    hideMarkdown = settings.hideMarkdown; autocomplete = settings.autocomplete
                    showHeadingLevels = settings.showHeadingLevels; typewriterMode = settings.typewriterMode
                    autoSortTodos = settings.autoSortTodos; showCounts = settings.showNoteCounts
                    sort = settings.noteSort; tagPosition = settings.tagPosition; template = settings.startNoteTemplate
                    templates = try library.database.pool.read { try Templates.list(db: $0) }
                    loaded = true
                }
            }
            .onChange(of: library.preferences) { _, _ in if loaded { library.perform { try library.savePreferences() } } }
            .onChange(of: library.libraryGeneration) { _, _ in
                library.perform {
                    let settings = try library.settings.snapshot()
                    hideMarkdown = settings.hideMarkdown; autocomplete = settings.autocomplete
                    showHeadingLevels = settings.showHeadingLevels; typewriterMode = settings.typewriterMode
                    autoSortTodos = settings.autoSortTodos; showCounts = settings.showNoteCounts
                    sort = settings.noteSort; tagPosition = settings.tagPosition; template = settings.startNoteTemplate
                    templates = try library.database.pool.read { try Templates.list(db: $0) }
                }
            }
            .onDisappear { if loaded { save() } }
        }
    }
    private func restoreGettingStarted() {
        switch library.restoreGettingStarted() {
        case nil: break
        case .success(let result)?:
            if result.changedAnything { showTag(GettingStartedNotes.tag); dismiss() }
            else { gettingStartedNotice = (MobileGettingStarted.nothingTitle, MobileGettingStarted.nothingText) }
        case .failure?: gettingStartedNotice = (MobileGettingStarted.failedTitle, MobileGettingStarted.failedText)
        }
    }
    private static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "—"
        let build = info["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    private var generalPage: some View {
        MobileGeneralSettings(library: library, hideMarkdown: persisted($hideMarkdown, .hideMarkdown), autocomplete: persisted($autocomplete, .autocomplete),
            autoSortTodos: persisted($autoSortTodos, .autoSortTodos), showCounts: persisted($showCounts, .showNoteCounts), showHeadingLevels: persisted($showHeadingLevels, .showHeadingLevels),
            typewriterMode: persisted($typewriterMode, .typewriterMode), sort: persisted($sort, .noteSort), tagPosition: persisted($tagPosition, .tagPosition),
            template: persisted($template, .startNoteTemplate), templates: templates)
            .onDisappear { save() }
    }

    // Persist each user edit before a sync/library-generation refresh can reload this page.
    // Loading state into @State does not go through these bindings, so restores stay read-only.
    private func persisted<Value: Codable & Sendable>(_ binding: Binding<Value>, _ key: SettingKey<Value>) -> Binding<Value> {
        Binding(get: { binding.wrappedValue }, set: { value in
            guard loaded, !library.libraryOperationBusy else { return }
            library.perform {
                try library.settings.set(key, to: value)
                binding.wrappedValue = value
            }
        })
    }

    private var privacyPage: some View {
        MobilePrivacySettings(library: library)
    }

    private func save() {
        guard loaded, !library.libraryOperationBusy else { return }
        library.perform {
            try library.settings.set(.hideMarkdown, to: hideMarkdown)
            try library.settings.set(.autocomplete, to: autocomplete)
            try library.settings.set(.showHeadingLevels, to: showHeadingLevels)
            try library.settings.set(.typewriterMode, to: typewriterMode)
            try library.settings.set(.autoSortTodos, to: autoSortTodos)
            try library.settings.set(.showNoteCounts, to: showCounts)
            try library.settings.set(.noteSort, to: sort)
            try library.settings.set(.tagPosition, to: tagPosition)
            try library.settings.set(.startNoteTemplate, to: template)
            try library.savePreferences()
        }
    }
}

extension NoteSort {
    var mobileTitle: String {
        switch self {
        case .modifiedDescending: "Newest Modified"; case .modifiedAscending: "Oldest Modified"
        case .createdDescending: "Newest Created"; case .createdAscending: "Oldest Created"
        case .titleAscending: "Title A–Z"; case .titleDescending: "Title Z–A"
        }
    }
}

private struct MobileGeneralSettings: View {
    @Bindable var library: MobileLibrary
    @Binding var hideMarkdown: Bool
    @Binding var autocomplete: Bool
    @Binding var autoSortTodos: Bool
    @Binding var showCounts: Bool
    @Binding var showHeadingLevels: Bool
    @Binding var typewriterMode: Bool
    @Binding var sort: NoteSort
    @Binding var tagPosition: TagPosition
    @Binding var template: String
    let templates: [TemplateInfo]
    var body: some View {
        Form {
                // IOS-DESIGN-R8: one-line switch labels; the detail goes to the footer.
                Section {
                    Toggle("Hide Markdown", isOn: $hideMarkdown)
                    Toggle("Autocomplete", isOn: $autocomplete)
                    Toggle("Show Heading Levels", isOn: $showHeadingLevels)
                    Toggle("Typewriter Mode", isOn: $typewriterMode)
                    Toggle("Checked To-Dos at Bottom", isOn: $autoSortTodos)
                    Picker("Start New Notes With", selection: $library.preferences.startContent) {
                        Text("Empty").tag("empty"); Text("Heading 1").tag("heading"); Text("Date").tag("date"); Text("Date and Time").tag("datetime")
                    }
                    Picker("New Note Template", selection: $template) {
                        Text("None").tag("")
                        ForEach(templates) { Text($0.title.isEmpty ? "Untitled" : $0.title).tag($0.id) }
                    }
                    Picker("Add Tags", selection: $tagPosition) { Text("At Bottom").tag(TagPosition.bottom); Text("At Top").tag(TagPosition.top) }
                } header: { Text("Editor") } footer: {
                    Text(verbatim: "Autocomplete suggests tags, wiki links and emoji as you type. Checked To-Dos at Bottom moves a to-do down when you check it.")
                }
                Section("Library") {
                    Toggle("Show Note Counts", isOn: $showCounts)
                    Toggle("Show Thumbnails", isOn: $library.preferences.showThumbnails)
                    Picker("Preview", selection: $library.preferences.previewLines) {
                        Text("None").tag(0); Text("Small").tag(1); Text("Medium").tag(2); Text("Large").tag(3)
                    }
                    Picker("Sort Notes", selection: $sort) {
                        ForEach(NoteSort.allCases, id: \.self) { Text($0.mobileTitle).tag($0) }
                    }
                }
                // IOS-CLUTTER-R11: the tag switch lives here only; relative wiki links stay in the export menu.
                Section {
                    Toggle("Keep Tags in Exports", isOn: $library.preferences.keepTagsOnExport)
                } header: { Text("Export") } footer: { Text("Applies to HTML, PDF, Rich Text and Plain Text, and to Copy As. Markdown and TextBundle exports keep tags as written.") }
        }
        .navigationTitle("General")
    }
}

private struct MobileTypographySettings: View {
    @Bindable var library: MobileLibrary
    var body: some View {
        Form {
                Section("Text and Code") {
                    Picker("Text Font", selection: $library.preferences.textFont) {
                        Text("System").tag("system"); Text("Georgia").tag("georgia"); Text("Palatino").tag("palatino"); Text("Menlo").tag("menlo")
                        ForEach(UIFont.familyNames.sorted().filter { !["Georgia", "Palatino", "Menlo"].contains($0) }, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Heading Font", selection: $library.preferences.headingFont) {
                        Text("Match Text Font").tag("text"); Text("System").tag("system")
                        Text("Georgia").tag("georgia"); Text("Palatino").tag("palatino"); Text("Menlo").tag("menlo")
                        ForEach(UIFont.familyNames.sorted().filter { !["Georgia", "Palatino", "Menlo"].contains($0) }, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Code Font", selection: $library.preferences.codeFont) {
                        Text("System").tag("system"); Text("Menlo").tag("menlo"); Text("Courier").tag("courier")
                        ForEach(UIFont.familyNames.sorted().filter { !["Menlo", "Courier"].contains($0) }, id: \.self) { Text($0).tag($0) }
                    }
                    Toggle("Follow Text Size", isOn: $library.preferences.useDynamicType)
                    LabeledContent("Font Size", value: "\(Int(library.preferences.fontSize)) pt")
                    Slider(value: $library.preferences.fontSize, in: 13...30, step: 1)
                    LabeledContent("Line Height", value: library.preferences.lineHeight.formatted(.number.precision(.fractionLength(1))))
                    Slider(value: $library.preferences.lineHeight, in: 1.2...2.2, step: 0.1)
                    LabeledContent("Line Width", value: "\(Int(library.preferences.lineWidth)) pt")
                    Slider(value: $library.preferences.lineWidth, in: 400...1000, step: 20)
                    LabeledContent("Paragraph Spacing", value: library.preferences.paragraphSpacing.formatted(.number.precision(.fractionLength(1))))
                    Slider(value: $library.preferences.paragraphSpacing, in: 0...2, step: 0.1)
                    LabeledContent("Paragraph Indent", value: library.preferences.paragraphIndent.formatted(.number.precision(.fractionLength(1))))
                    Slider(value: $library.preferences.paragraphIndent, in: 0...4, step: 0.1)
                }
        }
        .navigationTitle("Typography")
        .onDisappear { library.perform { try library.savePreferences() } }
    }
}

private struct MobileThemeSettings: View {
    @Bindable var library: MobileLibrary
    var body: some View {
        Form {
                Section("Appearance") {
                    Picker("Appearance", selection: $library.preferences.appearance) {
                        Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
                    }
                    Picker("Light Theme", selection: $library.preferences.lightThemeID) {
                        ForEach(ThemeCatalog.themes(.light), id: \.id) { Text($0.name).tag($0.id) }
                    }
                    Picker("Dark Theme", selection: $library.preferences.darkThemeID) {
                        ForEach(ThemeCatalog.themes(.dark), id: \.id) { Text($0.name).tag($0.id) }
                    }
                }
        }
        .navigationTitle("Themes")
        .onDisappear { library.perform { try library.savePreferences() } }
    }
}

private struct MobilePrivacySettings: View {
    @Bindable var library: MobileLibrary
    @Environment(\.scenePhase) private var scenePhase
    @State private var passwordAction: MobilePasswordAction?
    @State private var enableBiometryAfterPassword = false
    var body: some View {
        Form {
                Section("Privacy") {
                    Toggle("Require Authentication to Open Theo Notes", isOn: Binding(get: { library.appLockEnabled }, set: { enabled in
                        Task {
                            do { try await library.setAppLock(enabled) }
                            catch { library.errorMessage = "Access protection was not changed. Authenticate to try again." }
                        }
                    })).disabled(library.authenticatingDevice)
                    Button(library.hasNotePassword ? "Change Note Password" : "Set Note Password") {
                        passwordAction = library.hasNotePassword ? .change : .setup
                    }
                    if let label = MobileBiometricKeychain.label() {
                        Toggle("Unlock Notes with " + label, isOn: Binding(get: { library.biometryEnabled }, set: { enabled in
                            if !enabled { library.perform { try library.disableBiometrics() } }
                            else if library.privateAccess != nil { library.perform { try library.enableBiometrics() } }
                            else { enableBiometryAfterPassword = true; passwordAction = library.hasNotePassword ? .unlock : .setup }
                        }))
                    }
                    Text("Locked notes close when Theo Notes becomes inactive. Titles remain visible in the library.")
                        .foregroundStyle(.secondary)
                }
        }
        .navigationTitle("Privacy")
            .sheet(item: $passwordAction, onDismiss: { enableBiometryAfterPassword = false }) { action in
                MobilePasswordPrompt(library: library, action: action) {
                    if enableBiometryAfterPassword { library.perform { try library.enableBiometrics() } }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { passwordAction = nil; enableBiometryAfterPassword = false }
            }

    }
}

private struct MobileAdvancedSettings: View {
    @Bindable var library: MobileLibrary
    var body: some View {
        Form {
                Section("Application Data") {
                    NavigationLink { MobileBackups(library: library) } label: {
                        Label("Backup and Restore", systemImage: "externaldrive")
                    }
                }
                Section("Privacy") {
                    NavigationLink("Delete Notes Password") { MobilePasswordReset(library: library) }
                }
                Section("Automation") {
                    NavigationLink("API Token and URL Scheme") { MobileAutomationSettings(library: library) }
                }
        }
        .navigationTitle("Advanced")
    }
}
