// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Settings ▸ iCloud. One switch, one status line, and the few actions a state calls for. The words are in `MobileCloudSyncStrings`.
/// It looks like the other Settings pages: a grouped form with system type and system colours. The page is only linked from Settings in
/// a build that offers iCloud sync (`ReleaseFeatures.cloudSyncAvailable`); in any other build nothing here is ever built (CK-J2).
struct MobileCloudSyncSettings: View {
    @Bindable var controller: MobileCloudSyncController
    let library: MobileLibrary
    @Environment(\.scenePhase) private var scenePhase

    @State private var recoveryWords = ""
    @State private var notePassword = ""
    @State private var confirmingDelete = false
    @State private var confirmingRemoveKey = false
    @State private var confirmingMove = false
    @State private var confirmingMoveWithoutFiles = false
    @State private var showsAdvanced = false

    var body: some View {
        Form {
            if controller.isLocalOnly {
                Section { Label(MobileCloudSyncStrings.libraryNeverSyncs, systemImage: "icloud.slash") }
            } else if controller.boundToPrivateServer {
                Section {
                    Label(MobileCloudSyncStrings.privateServerLibrary, systemImage: "server.rack")
                        .accessibilityIdentifier("cloud-sync-private-server")
                    if controller.canMoveToICloud {
                        Text(MobileCloudSyncStrings.moveDetail).foregroundStyle(.secondary)
                        Button(MobileCloudSyncStrings.moveButton) { confirmingMove = true }
                            .disabled(controller.isWorking)
                            .accessibilityIdentifier("cloud-sync-move")
                            // On iPad the dialog is a popover: attached to the button, its arrow points at it.
                            .confirmationDialog(MobileCloudSyncStrings.moveTitle, isPresented: $confirmingMove, titleVisibility: .visible) {
                                Button(MobileCloudSyncStrings.moveConfirm) { Task { await controller.moveToICloud() } }
                            } message: {
                                Text(MobileCloudSyncStrings.moveMessage)
                            }
                        if controller.isWorking {
                            HStack(spacing: 8) {
                                ProgressView().accessibilityLabel(MobileCloudSyncStrings.workingLabel)
                                Text(controller.progress ?? MobileCloudSyncStrings.workingLabel).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text(MobileCloudSyncStrings.privateServerDetail).foregroundStyle(.secondary)
                    }
                }
                if let missing = controller.missingFilesToLeave {
                    Section {
                        moveMessage(MobileCloudSyncStrings.missingFilesTitle, symbol: "exclamationmark.triangle", tint: .orange) {
                            Text(MobileCloudSyncStrings.missingFilesCount(missing.notes.count + missing.moreNotes))
                            ForEach(Array(missing.notes.enumerated()), id: \.offset) { _, title in
                                Text(title).lineLimit(1).truncationMode(.tail).padding(.leading, 12)
                            }
                            if missing.moreNotes > 0 { Text(MobileCloudSyncStrings.missingFilesMore(missing.moreNotes)).padding(.leading, 12) }
                            Text(MobileCloudSyncStrings.missingFilesWithout)
                            Text(MobileCloudSyncStrings.nothingMovedYet)
                        }
                        .accessibilityIdentifier("cloud-sync-missing-files")
                        Button(MobileCloudSyncStrings.moveWithoutFilesButton) { confirmingMoveWithoutFiles = true }
                            .disabled(controller.isWorking)
                            .accessibilityIdentifier("cloud-sync-move-without-files")
                            // The same confirmation as the move, plus one sentence; on iPad its arrow points at this button (MOVE-R13).
                            .confirmationDialog(MobileCloudSyncStrings.moveTitle, isPresented: $confirmingMoveWithoutFiles, titleVisibility: .visible) {
                                Button(MobileCloudSyncStrings.moveConfirm) { Task { await controller.moveWithoutMissingFiles() } }
                            } message: {
                                Text(MobileCloudSyncStrings.moveWithoutFilesMessage)
                            }
                    }
                } else if let problem = controller.problem {
                    Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled) }
                }
            } else if !controller.isAvailable {
                Section { Label(MobileCloudSyncStrings.notInThisBuild, systemImage: "icloud.slash") }
            } else {
                if controller.showsMoveNotice {
                    Section {
                        moveMessage(MobileCloudSyncStrings.moveNoticeTitle, symbol: "arrow.right.circle", tint: .accentColor) {
                            Text(MobileCloudSyncStrings.moveOtherDevicesNotice)
                        }
                        .accessibilityIdentifier("cloud-sync-move-notice")
                        if let line = controller.moveSyncNotStarted {
                            // moveSyncNotStarted is the "off" text exactly when the switch is off.
                            moveMessage(controller.isOn ? MobileCloudSyncStrings.moveSyncBlockedTitle : MobileCloudSyncStrings.moveSyncOffTitle,
                                        symbol: "exclamationmark.triangle", tint: .orange) { Text(line) }
                                .accessibilityIdentifier("cloud-sync-move-not-started")
                        }
                        Button(MobileCloudSyncStrings.moveNoticeDismiss) { controller.dismissMoveNotice() }
                            .accessibilityIdentifier("cloud-sync-move-notice-dismiss")
                    }
                }
                switchSection
                if controller.lostSetupRace { lostRaceSection }
                if let notice = controller.notice { Section { Label(notice, systemImage: "checkmark.circle").foregroundStyle(.secondary) } }
                if let problem = controller.problem {
                    Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled) }
                }
                needsYouSections
                if controller.isOn { recoverySection; syncSection }
                if controller.isBoundToICloud { deleteSection }
            }
        }
        .navigationTitle(MobileCloudSyncStrings.pageTitle)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: Binding(
            get: { controller.recoveryOffer != nil },
            set: { if !$0 { Task { await controller.cancelRecoverySheet() } } }
        )) {
            MobileCloudRecoverySheet(controller: controller)
        }
        .sheet(isPresented: Binding(get: { controller.showsAccountChangedSheet }, set: { controller.showsAccountChangedSheet = $0 })) {
            MobileCloudAccountChangedSheet(controller: controller)
        }
        .confirmationDialog(MobileCloudSyncStrings.deleteCopyTitle, isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(MobileCloudSyncStrings.deleteCopyButton, role: .destructive) { Task { await controller.deleteICloudCopy() } }
        } message: {
            Text(MobileCloudSyncStrings.deleteCopyMessage)
        }
        .confirmationDialog(MobileCloudSyncStrings.removeKeyTitle, isPresented: $confirmingRemoveKey, titleVisibility: .visible) {
            Button(MobileCloudSyncStrings.removeKeyButton, role: .destructive) { Task { await controller.removeICloudKey() } }
        } message: {
            Text(MobileCloudSyncStrings.removeKeyMessage(recoverySaved: controller.recoverySaved))
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { recoveryWords = ""; notePassword = "" }
        }
        .onDisappear { recoveryWords = ""; notePassword = "" }
    }

    /// The move's three messages share one shape (design r4): the symbol tinted, a bold title in primary text, the rest secondary.
    /// An HStack, not a Label: at the accessibility text sizes a list row's Label flows its icon into the text and indents the first
    /// line of every Text.
    private func moveMessage<Lines: View>(_ title: String, symbol: String, tint: Color, @ViewBuilder lines: () -> Lines) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).bold()
                Group { lines() }.foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: the switch and the status

    private var switchSection: some View {
        Section {
            Toggle(MobileCloudSyncStrings.switchLabel, isOn: Binding(
                get: { controller.isOn },
                set: { value in Task { await controller.setSwitch(value) } }
            ))
            .disabled(controller.isWorking && !controller.isOn)    // switching OFF always works, even during a hung sync (CK-R171)
            .accessibilityIdentifier("cloud-sync-switch")
            statusRow
            if let lastSync = controller.lastSync, controller.isOn {
                LabeledContent(MobileCloudSyncStrings.lastSyncLabel, value: lastSync.formatted(date: .abbreviated, time: .shortened))
            }
        } footer: {
            Text(controller.isOn ? MobileCloudSyncStrings.switchHelpOn : MobileCloudSyncStrings.switchHelpOff).foregroundStyle(.secondary)
        }
    }

    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Label(controller.progress ?? controller.headline, systemImage: MobileCloudSyncController.symbol(for: controller.state, working: controller.isWorking))
                    .foregroundStyle(MobileCloudSyncController.tint(for: controller.state))
                    .accessibilityIdentifier("cloud-sync-headline")
                if controller.isWorking { ProgressView().accessibilityLabel(MobileCloudSyncStrings.workingLabel) }
            }
            if controller.isOn || controller.accountChanged {
                Text(controller.statusText).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("cloud-sync-status")
            }
        }
    }

    // MARK: what needs the person

    private var lostRaceSection: some View {
        Section {
            Label(MobileCloudSyncStrings.lostSetupRaceTitle, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(MobileCloudSyncStrings.lostSetupRace).fixedSize(horizontal: false, vertical: true)
            Button(MobileCloudSyncStrings.lostSetupRaceDismiss) { Task { await controller.dismissLostSetupRace() } }
        }
        .accessibilityIdentifier("cloud-sync-lost-race")
    }

    @ViewBuilder private var needsYouSections: some View {
        if controller.waitsForKeychain {
            // Gate G0 A6: one Keychain item never reached the second device. The wait has a way out: the recovery words below.
            Section {
                Label(MobileCloudSyncStrings.keychainWaitTitle, systemImage: "key.icloud").foregroundStyle(.orange)
                    .accessibilityIdentifier("cloud-sync-keychain-wait")
                Text(MobileCloudSyncStrings.keychainWaitDetail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        if controller.canUseRecoveryWords {
            Section {
                Text(MobileCloudSyncStrings.useRecoveryWordsDetail).foregroundStyle(.secondary)
                TextEditor(text: $recoveryWords)
                    .privacySensitive()
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .frame(minHeight: 120)
                    .accessibilityLabel(MobileCloudSyncStrings.useRecoveryWordsField)
                    .accessibilityIdentifier("cloud-sync-words-field")
                Button(MobileCloudSyncStrings.useRecoveryWordsButton) {
                    let words = recoveryWords; recoveryWords = ""
                    Task { await controller.useRecoveryWords(words) }
                }
                .disabled(recoveryWords.split(whereSeparator: \.isWhitespace).count != 24 || controller.isWorking)
            } header: { Text(MobileCloudSyncStrings.useRecoveryWords) }
        }
        if controller.needsNotePasswordInput {
            Section {
                Text(MobileCloudSyncStrings.notePasswordPrompt).foregroundStyle(.secondary)
                SecureField(MobileCloudSyncStrings.notePasswordField, text: $notePassword)
                    .textContentType(.password)
                Button(MobileCloudSyncStrings.notePasswordButton) {
                    let password = notePassword; notePassword = ""
                    Task { await controller.submitNotePassword(password) }
                }
                .disabled(notePassword.isEmpty || controller.isWorking)
            } header: { Text(MobileCloudSyncStrings.headline(for: .needsNotePassword)) }
        }
        if controller.canUploadAgain {
            Section {
                Button(MobileCloudSyncStrings.uploadAgain) { Task { await controller.uploadAgain() } }.disabled(controller.isWorking)
                Text(MobileCloudSyncStrings.uploadAgainDetail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        if controller.missingCount != nil {
            Section {
                Button(MobileCloudSyncStrings.uploadThemAgain) { Task { await controller.uploadThemAgain() } }.disabled(controller.isWorking)
                Text(MobileCloudSyncStrings.uploadThemAgainDetail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        if controller.accountChanged {
            Section {
                Button(MobileCloudSyncStrings.accountChangedTitle + "…") { controller.showsAccountChangedSheet = true }
            }
        }
        if controller.showsOpenSettings {
            Section {
                Button(MobileCloudSyncStrings.openSettings) { Self.openSettings() }
            }
        }
    }

    /// The Settings app at this app's page; iCloud itself is the first row of the Settings app. (No private URL is used.)
    static func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    // MARK: recovery words, sync, delete

    private var recoverySection: some View {
        Section {
            if controller.recoverySaved {
                Label(MobileCloudSyncStrings.recoverySavedLine, systemImage: "checkmark.seal").foregroundStyle(.secondary)
                Button(MobileCloudSyncStrings.replaceRecoveryWords) { controller.beginCreateOrReplaceRecoveryWords() }
                    .disabled(controller.isWorking || controller.needsRecoveryWords)
                Text(MobileCloudSyncStrings.replaceRecoveryDetail).font(.footnote).foregroundStyle(.secondary)
            } else {
                Label(MobileCloudSyncStrings.recoveryNotSavedLine, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(controller.showsRecoveryReminder ? Color.orange : Color.secondary)
                    .accessibilityIdentifier("cloud-sync-recovery-reminder")
                Button(MobileCloudSyncStrings.createRecoveryWords) { controller.beginCreateOrReplaceRecoveryWords() }
                    .disabled(controller.isWorking || controller.needsRecoveryWords)
            }
        } header: { Text(MobileCloudSyncStrings.recoverySection) }
    }

    private var syncSection: some View {
        Section {
            Button(MobileCloudSyncStrings.syncNow) { Task { await controller.syncNow() } }.disabled(controller.isWorking)
            Button(MobileCloudSyncStrings.stopSyncing) { Task { await controller.stopSyncing() } }
                .accessibilityIdentifier("cloud-sync-stop")
        } footer: {
            Text(MobileCloudSyncStrings.stopSyncingDetail)
        }
    }

    private var deleteSection: some View {
        Section {
            Button(MobileCloudSyncStrings.deleteCopy, role: .destructive) { confirmingDelete = true }.disabled(controller.isWorking)
            DisclosureGroup(MobileCloudSyncStrings.advanced, isExpanded: $showsAdvanced) {
                Button(MobileCloudSyncStrings.removeKey, role: .destructive) { confirmingRemoveKey = true }.disabled(controller.isWorking)
            }
        }
    }
}

/// The recovery words: the 24 words, a copy button, the three-word check, and (during first setup only) the way to skip with the risk
/// sentence ticked (CK-R7, CK-J1). The words are hidden while the app is not active, and the copy leaves the clipboard after a minute.
struct MobileCloudRecoverySheet: View {
    @Bindable var controller: MobileCloudSyncController

    @Environment(\.scenePhase) private var scenePhase
    @State private var typed: [Int: String] = [:]
    @State private var acknowledged = false
    @State private var copied = false
    @State private var showsWords = true
    @FocusState private var focus: Int?

    var body: some View {
        NavigationStack {
            if let offer = controller.recoveryOffer, let purpose = controller.recoveryPurpose {
                sheet(offer: offer, purpose: purpose)
            }
        }
        .interactiveDismissDisabled(controller.isWorking)
    }

    private func sheet(offer: RecoveryKeyOffer, purpose: MobileCloudRecoveryPurpose) -> some View {
        let words = offer.words.split(separator: " ").map(String.init)
        return Form {
            Section {
                Text(purpose == .firstSetup ? MobileCloudSyncStrings.sheetSetupIntro : MobileCloudSyncStrings.sheetLaterIntro)
                    .fixedSize(horizontal: false, vertical: true)
                wordGrid(words)
                Button(MobileCloudSyncStrings.sheetCopy) { copy(offer.words) }
                Button(showsWords ? MobileCloudSyncStrings.sheetHideWords : MobileCloudSyncStrings.sheetShowWords) { showsWords.toggle() }
                if copied { Text(MobileCloudSyncStrings.sheetCopied).font(.footnote).foregroundStyle(.secondary) }
            }
            Section {
                Text(MobileCloudSyncStrings.sheetCheckIntro).font(.footnote).foregroundStyle(.secondary)
                ForEach(offer.checkPositions, id: \.self) { position in
                    LabeledContent(MobileCloudSyncStrings.sheetCheckPrompt(position: position + 1)) {
                        TextField("", text: Binding(get: { typed[position] ?? "" }, set: { typed[position] = $0 }))
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .focused($focus, equals: position)
                            .accessibilityLabel(MobileCloudSyncStrings.sheetCheckPrompt(position: position + 1))
                    }
                }
            } header: { Text(MobileCloudSyncStrings.sheetCheckTitle) }
            if let error = controller.recoverySheetError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        .accessibilityIdentifier("cloud-recovery-error")
                }
            }
            if purpose == .firstSetup { skipSection }
        }
        .navigationTitle(MobileCloudSyncStrings.sheetTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(purpose == .firstSetup ? MobileCloudSyncStrings.sheetCancelSetup : MobileCloudSyncStrings.sheetCancel) {
                    Task { await controller.cancelRecoverySheet() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(MobileCloudSyncStrings.sheetSave) { Task { await controller.confirmRecoveryWords(typed: typed) } }
                    .disabled(!offer.checkPositions.allSatisfy { !(typed[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty } || controller.isWorking)
                    .accessibilityIdentifier("cloud-recovery-save")
            }
        }
        .onDisappear { typed = [:]; acknowledged = false }
        .onChange(of: scenePhase) { _, phase in if phase != .active { typed = [:] } }
        .privacySensitive()
    }

    private func wordGrid(_ words: [String]) -> some View {
        Group {
            if showsWords && scenePhase == .active {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 2), spacing: 8) {
                    ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                        Text("\(index + 1). \(word)")
                            .font(.system(.body, design: .monospaced))
                            .accessibilityLabel(MobileCloudSyncStrings.sheetWordAccessibility(position: index + 1, word: word))
                    }
                }
                .privacySensitive()
            } else {
                Text(scenePhase == .active ? "" : MobileCloudSyncStrings.sheetWordsHidden).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("cloud-recovery-words")
    }

    private var skipSection: some View {
        Section {
            Toggle(MobileCloudSyncStrings.sheetRiskSentence, isOn: $acknowledged)
                .accessibilityIdentifier("cloud-recovery-risk")
            Button(MobileCloudSyncStrings.sheetSkip) { Task { await controller.skipRecoveryWords(acknowledged: acknowledged) } }
                .disabled(!acknowledged || controller.isWorking)
                .accessibilityIdentifier("cloud-recovery-skip")
        } header: { Text(MobileCloudSyncStrings.sheetSkipHeader) }
    }

    /// The words go to the clipboard for a minute and only on this device (no Universal Clipboard), then the system clears them.
    private func copy(_ words: String) {
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: words]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(60)])
        copied = true
    }
}

/// CK-R10: this device is signed in to a different iCloud account than the one the library syncs with. Nothing is sent to the new
/// account unless the person says so; the first button keeps the library offline.
struct MobileCloudAccountChangedSheet: View {
    @Bindable var controller: MobileCloudSyncController

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(MobileCloudSyncStrings.accountChangedTitle, systemImage: "person.crop.circle.badge.exclamationmark").font(.headline)
                    Text(MobileCloudSyncStrings.accountChangedMessage).fixedSize(horizontal: false, vertical: true)
                }
                Section {
                    Button(MobileCloudSyncStrings.keepOffline) { Task { await controller.keepOffline() } }
                        .accessibilityIdentifier("cloud-account-keep-offline")
                } footer: { Text(MobileCloudSyncStrings.keepOfflineDetail) }
                Section {
                    Button(MobileCloudSyncStrings.syncWithNewAccount) { Task { await controller.syncWithNewAccount() } }
                        .accessibilityIdentifier("cloud-account-sync-new")
                } footer: { Text(MobileCloudSyncStrings.syncWithNewAccountDetail) }
            }
            .navigationTitle(MobileCloudSyncStrings.pageTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(MobileCloudSyncStrings.accountChangedContinue) { controller.showsAccountChangedSheet = false }
                }
            }
        }
        .disabled(controller.isWorking)
    }
}
