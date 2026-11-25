// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import GRDB
import Observation
import SwiftUI

/// The `setting` table as observable state for the Settings window and the sidebar.
@MainActor
@Observable
final class SettingsModel {
    private(set) var snapshot: TheoNotesCore.Settings.Snapshot

    @ObservationIgnored private let settings: TheoNotesCore.Settings
    @ObservationIgnored private var observation: Task<Void, Never>?

    init(database: AppDatabase) {
        let settings = TheoNotesCore.Settings(db: database)
        self.settings = settings
        snapshot = (try? settings.snapshot()) ?? TheoNotesCore.Settings.Snapshot()
        observation = Task { [weak self] in
            do {
                for try await snapshot in settings.observe() {
                    self?.snapshot = snapshot
                }
            } catch {
                appLogger.error("settings observation failed: \(error)")
            }
        }
    }

    isolated deinit {
        observation?.cancel()
    }

    func set<Value>(_ key: SettingKey<Value>, _ value: Value) {
        do {
            try settings.set(key, to: value)
            snapshot = try settings.snapshot()
        } catch {
            appLogger.error("setting \(key.name, privacy: .public) not saved: \(error)")
        }
    }

    func binding<Value>(_ key: SettingKey<Value>, _ path: KeyPath<TheoNotesCore.Settings.Snapshot, Value>) -> Binding<Value> {
        Binding(get: { self.snapshot[keyPath: path] }, set: { self.set(key, $0) })
    }
}

enum NoteSortField: String, CaseIterable, Identifiable {
    case modified, created, title

    var id: Self { self }

    var title: String {
        switch self {
        case .modified: "Modification Date"
        case .created: "Creation Date"
        case .title: "Title"
        }
    }
}

extension NoteSort {
    init(field: NoteSortField, ascending: Bool) {
        switch field {
        case .modified: self = ascending ? .modifiedAscending : .modifiedDescending
        case .created: self = ascending ? .createdAscending : .createdDescending
        case .title: self = ascending ? .titleAscending : .titleDescending
        }
    }

    var field: NoteSortField {
        switch self {
        case .modifiedAscending, .modifiedDescending: .modified
        case .createdAscending, .createdDescending: .created
        case .titleAscending, .titleDescending: .title
        }
    }

    var isAscending: Bool {
        switch self {
        case .modifiedAscending, .createdAscending, .titleAscending: true
        case .modifiedDescending, .createdDescending, .titleDescending: false
        }
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, capture, appearance, typography, automation, sync, icloud, privacy, advanced

    var id: Self { self }

    static let storageKey = "Settings.tab"

    /// Left to right. iCloud sits next to Sync, Privacy (M9, M9M-R65) between them and Advanced; Advanced stays last.
    static var order: [SettingsTab] {
        order(syncSetup: ReleaseFeatures.syncSetupAvailable(), icloud: ReleaseFeatures.cloudSyncAvailable())
    }

    /// The tabs a build shows: the public build has no Sync tab (REL-R5), and no iCloud tab until it is switched on in the build
    /// (`ReleaseFeatures.cloudSyncAvailable`, CK-J2).
    static func order(syncSetup: Bool, icloud: Bool = false) -> [SettingsTab] {
        let all: [SettingsTab] = [.general, .capture, .appearance, .typography, .automation, .sync, .icloud, .privacy, .advanced]
        return all.filter { ($0 != .sync || syncSetup) && ($0 != .icloud || icloud) }
    }

    /// The tab to select for a saved choice: a tab saved by another build is not selectable here.
    func shown(syncSetup: Bool, icloud: Bool = false) -> SettingsTab {
        switch self {
        case .sync: syncSetup ? self : .general
        case .icloud: icloud ? self : .general
        default: self
        }
    }

    var title: String {
        switch self {
        case .general: "General"
        case .capture: "Capture"
        case .appearance: "Appearance"
        case .typography: "Typography"
        case .automation: "Automation"
        case .sync: "Sync"
        case .icloud: CloudSyncStrings.tabTitle
        case .privacy: "Privacy"
        case .advanced: "Advanced"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .capture: "bolt"
        case .appearance: "paintpalette"
        case .typography: "textformat"
        case .automation: "terminal"
        case .sync: "icloud"
        case .icloud: "icloud.circle"
        case .privacy: "lock"
        case .advanced: "gearshape.2"
        }
    }
}

/// Settings (⌘,): General, Appearance, Typography, Automation, Sync, iCloud, Privacy and Advanced (spec §4.8).
struct SettingsView: View {
    let settings: SettingsModel
    let environment: AppEnvironment
    /// Nil where no capture settings exist (unit tests that build the window alone): the Capture pane stays empty.
    var capture: CaptureSettingsModel?

    @AppStorage(SettingsTab.storageKey) private var tab = SettingsTab.general

    var body: some View {
        // Settings show nothing from the library, but they hold the controls that turn App Lock off:
        // they wait behind the lock screen like every window (M9M-R62).
        AppLockGate(lock: environment.appLock) {
            TabView(selection: Binding(
                get: { tab.shown(syncSetup: environment.syncSetupAvailable, icloud: environment.cloudSyncAvailable) }, set: { tab = $0 })
            ) {
                ForEach(SettingsTab.order(syncSetup: environment.syncSetupAvailable, icloud: environment.cloudSyncAvailable)) { item in
                    Tab(item.title, systemImage: item.systemImage, value: item) {
                        SettingsPane(tab: item, settings: settings, environment: environment, capture: capture)
                    }
                }
            }
        }
        .frame(width: 500)
    }
}

/// The content of one Settings tab.
struct SettingsPane: View {
    let tab: SettingsTab
    let settings: SettingsModel
    let environment: AppEnvironment
    var capture: CaptureSettingsModel?
    /// Where Automation installs the command-line link (`~/.local/bin`); tests pass a temporary folder.
    var home: URL = FileManager.default.homeDirectoryForCurrentUser

    var body: some View {
        switch tab {
        case .general: GeneralSettings(settings: settings, environment: environment)
        case .capture: if let capture { CaptureSettingsView(model: capture) }
        case .appearance: AppearanceSettingsPane(settings: settings, appearance: environment.appearance)
        case .typography: TypographySettingsPane(settings: settings)
        case .automation: AutomationSettingsView(environment: environment, home: home)
        case .sync:
            // Not reachable through the tab bar in a public build (REL-R5); nothing is built for it either.
            if environment.syncSetupAvailable { MacSyncSettings(sync: environment.sync) }
        case .icloud:
            // No entry point exists in a build without the flag (REL-R5/R6); nothing is built for it either.
            if environment.cloudSyncAvailable { CloudSyncSettingsView(controller: environment.cloudSync) }
        case .privacy: PrivacySettingsPane(environment: environment)
        case .advanced: AdvancedSettings(settings: settings, environment: environment)
        }
    }
}

private struct GeneralSettings: View {
    let settings: SettingsModel
    let environment: AppEnvironment

    @State private var templates: [TemplateInfo] = []

    var body: some View {
        Form {
            Section("Editor") {
                Toggle("Hide Markdown", isOn: settings.binding(.hideMarkdown, \.hideMarkdown))
                Toggle("Show heading levels in the margin", isOn: settings.binding(.showHeadingLevels, \.showHeadingLevels))
                Toggle("Autocomplete tags, links and emoji", isOn: settings.binding(.autocomplete, \.autocomplete))
                Toggle("Checked to-dos at bottom", isOn: settings.binding(.autoSortTodos, \.autoSortTodos))
                Toggle("Typewriter mode (keep the caret line centered)", isOn: settings.binding(.typewriterMode, \.typewriterMode))
            }
            Section {
                Picker("Start new notes with", selection: startTemplate) {
                    Text("Empty Note").tag("")
                    if !templates.isEmpty { Divider() }
                    ForEach(templates) { Text(TemplateChoice.label(for: $0, among: templates)).tag($0.id) }
                }
            } header: {
                Text("New Notes")
            } footer: {
                Text("⌘N makes a note from this template. Tag a note #template to make one.")
                    .foregroundStyle(.secondary)
            }
            Section("Tags") {
                Picker("Add tags at", selection: settings.binding(.tagPosition, \.tagPosition)) {
                    Text("Top of Note").tag(TagPosition.top)
                    Text("Bottom of Note").tag(TagPosition.bottom)
                }
                Toggle("Show note counts", isOn: settings.binding(.showNoteCounts, \.showNoteCounts))
                Toggle("Keep tags when exporting and copying", isOn: settings.binding(.keepTagsOnExport, \.keepTagsOnExport))
            }
        }
        .formStyle(.grouped)
        // The list follows the library: a template made, retagged, trashed or renamed while Settings is open.
        .task {
            do {
                for try await list in ValueObservation.tracking(Templates.list(db:)).values(in: environment.database.pool) {
                    templates = list
                }
            } catch {
                appLogger.error("template list observation failed: \(error)")
            }
        }
    }

    /// The chosen template; "" (Empty Note) while the stored one is no longer among the templates.
    /// ⌘N clears a stale setting itself (`AppModel.startTemplateId`).
    private var startTemplate: Binding<String> {
        Binding(
            get: {
                let id = settings.snapshot.startNoteTemplate
                return templates.contains { $0.id == id } ? id : ""
            },
            set: { settings.set(.startNoteTemplate, $0) }
        )
    }
}

private struct AdvancedSettings: View {
    let settings: SettingsModel
    let environment: AppEnvironment

    @State private var journals: [URL] = []
    @State private var abortedNoteIDs: [String] = []
    @State private var pendingVariantNoteIDs: [String] = []
    @State private var recoveryUnlockSheet: PasswordSheetModel?
    @State private var variantIDs: [String] = []
    @State private var singleJournals: [AppEnvironment.RecoveredSingleJournal] = []
    @State private var selectedSingle: AppEnvironment.RecoveredSingleJournal?
    @State private var quarantineIDs: [String] = []
    @State private var markerNames: [String] = []
    @State private var keyState: JournalRecoveryCoordinator.KeyState?
    @State private var variantRetryIDs: [String] = []
    @State private var selectedVariantGroup: AppEnvironment.RecoveredVariantGroup?
    @State private var selectedVariantQuarantine: AppEnvironment.VariantQuarantinePlan?
    @State private var recoveryNotice: String?
    @State private var lastBackup: Date?

    var body: some View {
        Form {
            Section {
                LabeledContent("bearcli") {
                    HStack {
                        TextField("bearcli", text: settings.binding(.bearCLIPath, \.bearCLIPath))
                            .labelsHidden()
                            .font(.system(.body, design: .monospaced))
                        Button("Choose…", action: chooseBearCLI)
                    }
                }
                Toggle("Pull from Bear at launch", isOn: settings.binding(.pullFromBearAtLaunch, \.pullFromBearAtLaunch))
            } header: {
                Text("Bear")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if !FileManager.default.isExecutableFile(atPath: settings.snapshot.bearCLIPath) {
                        Label("No bearcli at this path.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    Text("Theo Notes only reads from Bear, using Bear’s own command line tool.")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                if journals.isEmpty && abortedNoteIDs.isEmpty && pendingVariantNoteIDs.isEmpty && keyState == nil && variantRetryIDs.isEmpty && singleJournals.isEmpty && variantIDs.isEmpty && quarantineIDs.isEmpty && markerNames.isEmpty {
                    Text("No edit journals are waiting for recovery.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(journals, id: \.self) { url in
                        LabeledContent(url.lastPathComponent) {
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                        }
                    }
                }
                if keyState == .waitingForSyncKey {
                    LabeledContent("Recovery waiting for the notes key from another device") {
                        Button("Sync Now") { Task { await environment.sync.synchronize(); refreshVariantRows() } }
                            .accessibilityLabel("Sync to fetch the notes key, then enter your notes password in Sync settings")
                    }
                } else if !pendingVariantNoteIDs.isEmpty || keyState == .unlockRequired {
                    LabeledContent("Recovery waiting for unlock") {
                        Button("Unlock Notes…") { presentRecoveryUnlock() }
                            .accessibilityLabel("Unlock notes to continue recovery")
                    }
                }
                if !variantRetryIDs.isEmpty {
                    LabeledContent("Recovery needs another attempt") {
                        Button("Retry") { environment.retryJournalRecovery(); refreshVariantRows() }
                            .accessibilityLabel("Retry edit journal recovery")
                    }
                }
                ForEach(singleJournals, id: \.note.id) { notice in
                    LabeledContent("Recovered note \(notice.sourceID)") {
                        HStack {
                            Button("Open") {
                                do { try environment.openRecoveredSingle(notice) }
                                catch { recoveryNotice = "The recovered note is no longer available. Retry recovery." }
                            }.accessibilityLabel("Open recovered note for \(notice.sourceID)")
                            Button("Remove leftover…") { selectedSingle = notice }
                                .accessibilityLabel("Remove saved journal for recovered note \(notice.sourceID)")
                        }
                    }
                }
                ForEach(variantIDs, id: \.self) { id in
                    LabeledContent("Recovered variants \(id)") {
                        Button("Remove leftover…") { selectedVariantGroup = environment.recoveredVariantGroups.first(where: { $0.noteId == id }) }
                            .accessibilityLabel("Remove saved variant source files for note \(id)")
                    }
                }
                ForEach(quarantineIDs, id: \.self) { id in
                    LabeledContent("Recovery files \(id)") {
                        Button("Move aside…") {
                            do { selectedVariantQuarantine = try environment.prepareVariantQuarantine(noteId: id) }
                            catch { recoveryNotice = "The files changed or the note is open. Close the note and try again." }
                        }.accessibilityLabel("Move recovery files aside for note \(id)")
                    }
                }
                ForEach(markerNames, id: \.self) { name in
                    LabeledContent("Recovery marker that cannot be finished") {
                        Button("Move aside…") {
                            do { selectedVariantQuarantine = try environment.prepareMarkerQuarantine(markerName: name) }
                            catch { recoveryNotice = "The marker changed or its note is open. Close the note and try again." }
                        }.accessibilityLabel("Move the recovery marker and its files aside")
                    }
                }
                if let recoveryNotice { Text(recoveryNotice).foregroundStyle(.secondary).textSelection(.enabled) }
            } header: {
                Text("Recovered Edit Journals")
            } footer: {
                Text("Edits that could not be applied at launch are kept here for manual recovery.")
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Last daily copy") {
                    Text(lastBackup.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "None yet")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Backups folder") {
                    Button("Show Backups in Finder") { NSWorkspace.shared.open(environment.paths.backups) }
                }
                if let failure = environment.dailyBackupFailure {
                    Label("The last daily copy failed: \(failure)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Backups")
            } footer: {
                Text("Daily copies of the database (attachments are not included). Use File ▸ Backup Notes… for a full backup.")
                    .foregroundStyle(.secondary)
            }
            Section("Data") {
                LabeledContent("Library") {
                    Button("Open Data Folder") { NSWorkspace.shared.open(environment.paths.root) }
                }
            }
            Section {
                Text("\(DiagnosticsMenu.showReports) and \(DiagnosticsMenu.copySummary) are in the Help menu.")
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("If the app crashes or stops responding, macOS can hand it a technical report with the stack and the app version, never your notes. Theo Notes keeps the latest ones in a folder on this Mac and sends nothing. You decide whether to share them.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            journals = environment.movedAsideJournals()
            abortedNoteIDs = (try? environment.abortedJournalNoteIDs()) ?? []
            pendingVariantNoteIDs = (try? environment.pendingVariantNoteIDs()) ?? []
            refreshVariantRows()
            lastBackup = environment.lastDailyBackupDate()
        }
        .sheet(item: $recoveryUnlockSheet) { PasswordSheetView(model: $0) }
        .alert("Remove saved journal files?", isPresented: Binding(
            get: { selectedSingle != nil }, set: { if !$0 { selectedSingle = nil } }
        ), presenting: selectedSingle) { notice in
            Button("Cancel", role: .cancel) { selectedSingle = nil }
            Button("Remove Files", role: .destructive) {
                do { try environment.removeRecoveredSingleAfterConfirmation(notice); refreshVariantRows(); recoveryNotice = "The recovered note remains in Notes." }
                catch { refreshVariantRows(); recoveryNotice = "The saved note or files changed. Review the latest recovery; nothing further was removed." }
                selectedSingle = nil
            }
        } message: { _ in Text("The recovered note remains in Notes. The original journal files will be removed.") }
        .alert("Remove saved recovery source files?", isPresented: Binding(
            get: { selectedVariantGroup != nil }, set: { if !$0 { selectedVariantGroup = nil } }
        ), presenting: selectedVariantGroup) { group in
            Button("Cancel", role: .cancel) { selectedVariantGroup = nil }
            Button("Remove Files") {
                do { try environment.removeVariantGroupAfterConfirmation(group); refreshVariantRows(); recoveryNotice = "Recovered variants remain in Notes." }
                catch { recoveryNotice = "The source files changed or recovery is unavailable. Nothing further was removed." }
                selectedVariantGroup = nil
            }
        } message: { _ in Text("The saved recovery variants stay in Notes. The original journal files will be removed.") }
        .alert("Move recovery files aside?", isPresented: Binding(
            get: { selectedVariantQuarantine != nil }, set: { if !$0 { selectedVariantQuarantine = nil } }
        ), presenting: selectedVariantQuarantine) { plan in
            Button("Cancel", role: .cancel) { selectedVariantQuarantine = nil }
            Button("Move Files") {
                do {
                    let directory = try environment.moveVariantFilesAfterConfirmation(plan)
                    recoveryNotice = "Files were kept in \(directory.path). Back them up separately; portable backups do not include them."
                    refreshVariantRows(); NSWorkspace.shared.activateFileViewerSelecting([directory])
                } catch { recoveryNotice = "The files could not be moved. They have been kept." }
                selectedVariantQuarantine = nil
            }
        } message: { plan in Text(JournalQuarantine.confirmationMessage(base: "The files will be moved unchanged. Portable backups do not include them.", includesUnavailableKeyFiles: plan.includesUnavailableKeyFiles)) }
    }

    private func presentRecoveryUnlock() {
        let sheet = PasswordSheetModel(kind: .unlock(.recoverJournals), vault: environment.vault)
        sheet.beginAuthenticationScope()
        sheet.onSuccess = { [weak sheet] in
            sheet?.clearFields(); sheet?.endAuthenticationScope(); recoveryUnlockSheet = nil
            abortedNoteIDs = (try? environment.abortedJournalNoteIDs()) ?? []
            pendingVariantNoteIDs = (try? environment.pendingVariantNoteIDs()) ?? []
            refreshVariantRows()
        }
        sheet.onCancel = { [weak sheet] in
            sheet?.clearFields(); sheet?.endAuthenticationScope(); recoveryUnlockSheet = nil
        }
        recoveryUnlockSheet = sheet
    }

    private func refreshVariantRows() {
        variantIDs = environment.recoveredVariantGroups.map(\.noteId)
        singleJournals = environment.recoveredSingleJournals
        quarantineIDs = environment.variantQuarantineFiles.keys.sorted()
        markerNames = environment.markerMoveNames
        keyState = environment.journalKeyState
        variantRetryIDs = environment.variantRetryNoteIDs
        abortedNoteIDs = (try? environment.abortedJournalNoteIDs()) ?? []
        pendingVariantNoteIDs = (try? environment.pendingVariantNoteIDs()) ?? []
    }

    private func chooseBearCLI() {
        let panel = NSOpenPanel()
        panel.message = "Choose bearcli (inside Bear.app: Contents/MacOS/bearcli)."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = URL(fileURLWithPath: settings.snapshot.bearCLIPath).deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.set(.bearCLIPath, url.path)
    }
}
