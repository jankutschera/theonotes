// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import SwiftUI

/// Settings ▸ iCloud. One switch, one status line, and the few actions a state calls for. The words are in `CloudSyncStrings`.
/// It looks like the other Settings tabs: a grouped form with system type and system colours.
struct CloudSyncSettingsView: View {
    let controller: CloudSyncController

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
                Section { Label(CloudSyncStrings.libraryCopyNeverSyncs, systemImage: "icloud.slash") }
            } else if controller.boundToPrivateServer {
                Section {
                    Label(CloudSyncStrings.privateServerLibrary, systemImage: "server.rack")
                        .accessibilityIdentifier("cloud-sync-private-server")
                    if controller.canMoveToICloud {
                        Text(CloudSyncStrings.moveDetail).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Button(CloudSyncStrings.moveButton) { confirmingMove = true }
                                .disabled(controller.isWorking)
                                .accessibilityIdentifier("cloud-sync-move")
                            if controller.isWorking { ProgressView().controlSize(.small).accessibilityLabel(CloudSyncStrings.workingLabel) }
                        }
                        if let progress = controller.progress { Text(progress).foregroundStyle(.secondary) }
                    } else {
                        Text(CloudSyncStrings.privateServerDetail).foregroundStyle(.secondary)
                    }
                }
                if let missing = controller.missingFilesToLeave {
                    Section {
                        moveMessage(CloudSyncStrings.missingFilesTitle, symbol: "exclamationmark.triangle", tint: .orange) {
                            Text(CloudSyncStrings.missingFilesCount(missing.notes.count + missing.moreNotes))
                            ForEach(Array(missing.notes.enumerated()), id: \.offset) { _, title in
                                Text(title).lineLimit(1).truncationMode(.tail).padding(.leading, 12)
                            }
                            if missing.moreNotes > 0 { Text(CloudSyncStrings.missingFilesMore(missing.moreNotes)).padding(.leading, 12) }
                            Text(CloudSyncStrings.missingFilesWithout)
                            Text(CloudSyncStrings.nothingMovedYet)
                        }
                        .accessibilityIdentifier("cloud-sync-missing-files")
                        Button(CloudSyncStrings.moveWithoutFilesButton) { confirmingMoveWithoutFiles = true }
                            .disabled(controller.isWorking)
                            .accessibilityIdentifier("cloud-sync-move-without-files")
                    }
                } else if let problem = controller.problem {
                    Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled) }
                }
            } else if !controller.isAvailable {
                Section { Label(CloudSyncStrings.notInThisBuild, systemImage: "icloud.slash") }
            } else {
                if controller.showsMoveNotice {
                    Section {
                        moveMessage(CloudSyncStrings.moveNoticeTitle, symbol: "arrow.right.circle", tint: .accentColor) {
                            Text(CloudSyncStrings.moveOtherDevicesNotice)
                        }
                        .accessibilityIdentifier("cloud-sync-move-notice")
                        if let line = controller.moveSyncNotStarted {
                            // moveSyncNotStarted is the "off" text exactly when the switch is off.
                            moveMessage(controller.isOn ? CloudSyncStrings.moveSyncBlockedTitle : CloudSyncStrings.moveSyncOffTitle,
                                        symbol: "exclamationmark.triangle", tint: .orange) { Text(line) }
                                .accessibilityIdentifier("cloud-sync-move-not-started")
                        }
                        Button(CloudSyncStrings.moveNoticeDismiss) { controller.dismissMoveNotice() }
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
        .formStyle(.grouped)
        .sheet(isPresented: Binding(
            get: { controller.recoveryOffer != nil },
            set: { if !$0 { Task { await controller.cancelRecoverySheet() } } }
        )) {
            CloudRecoveryKeySheet(controller: controller)
        }
        .sheet(isPresented: Binding(get: { controller.showsAccountChangedSheet }, set: { controller.showsAccountChangedSheet = $0 })) {
            CloudAccountChangedSheet(controller: controller)
        }
        .confirmationDialog(CloudSyncStrings.deleteCopyTitle, isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(CloudSyncStrings.deleteCopyButton, role: .destructive) { Task { await controller.deleteICloudCopy() } }
        } message: {
            Text(CloudSyncStrings.deleteCopyMessage)
        }
        .confirmationDialog(CloudSyncStrings.moveTitle, isPresented: $confirmingMove, titleVisibility: .visible) {
            Button(CloudSyncStrings.moveConfirm) { Task { await controller.moveToICloud() } }
        } message: {
            Text(CloudSyncStrings.moveMessage)
        }
        .confirmationDialog(CloudSyncStrings.moveTitle, isPresented: $confirmingMoveWithoutFiles, titleVisibility: .visible) {
            Button(CloudSyncStrings.moveConfirm) { Task { await controller.moveWithoutMissingFiles() } }
        } message: {
            Text(CloudSyncStrings.moveWithoutFilesMessage)
        }
        .confirmationDialog(CloudSyncStrings.removeKeyTitle, isPresented: $confirmingRemoveKey, titleVisibility: .visible) {
            Button(CloudSyncStrings.removeKeyButton, role: .destructive) { Task { await controller.removeICloudKey() } }
        } message: {
            Text(CloudSyncStrings.removeKeyMessage(recoverySaved: controller.recoverySaved))
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            recoveryWords = ""; notePassword = ""
        }
        .onDisappear { recoveryWords = ""; notePassword = "" }
    }

    /// The move's three messages share one shape (design r4): the symbol tinted, a bold title in primary text, the rest secondary.
    private func moveMessage<Lines: View>(_ title: String, symbol: String, tint: Color, @ViewBuilder lines: () -> Lines) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).bold()
                Group { lines() }.foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        } icon: { Image(systemName: symbol).foregroundStyle(tint) }
        .accessibilityElement(children: .combine)
    }

    // MARK: the switch and the status

    private var switchSection: some View {
        Section {
            Toggle(CloudSyncStrings.switchLabel, isOn: Binding(
                get: { controller.isOn },
                set: { value in Task { await controller.setSwitch(value) } }
            ))
            .disabled(controller.isWorking && !controller.isOn)    // switching OFF always works, even during a hung sync
            .accessibilityIdentifier("cloud-sync-switch")
            statusRow
            if let lastSync = controller.lastSync, controller.isOn {
                LabeledContent(CloudSyncStrings.lastSyncLabel, value: lastSync.formatted(date: .abbreviated, time: .shortened))
            }
        } footer: {
            Text(controller.isOn ? CloudSyncStrings.switchHelpOn : CloudSyncStrings.switchHelpOff).foregroundStyle(.secondary)
        }
    }

    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Label(controller.progress ?? controller.headline, systemImage: CloudSyncController.symbol(for: controller.state, working: controller.isWorking))
                    .foregroundStyle(CloudSyncController.tint(for: controller.state))
                    .accessibilityIdentifier("cloud-sync-headline")
                if controller.isWorking { ProgressView().controlSize(.small).accessibilityLabel(CloudSyncStrings.workingLabel) }
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
            Label(CloudSyncStrings.lostSetupRaceTitle, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(CloudSyncStrings.lostSetupRace).fixedSize(horizontal: false, vertical: true)
            Button(CloudSyncStrings.lostSetupRaceDismiss) { Task { await controller.dismissLostSetupRace() } }
        }
        .accessibilityIdentifier("cloud-sync-lost-race")
    }

    @ViewBuilder private var needsYouSections: some View {
        if controller.canUseRecoveryWords {
            Section {
                Text(CloudSyncStrings.useRecoveryWordsDetail).foregroundStyle(.secondary)
                TextEditor(text: $recoveryWords)
                    .privacySensitive()
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 90)
                    .accessibilityLabel(CloudSyncStrings.useRecoveryWordsField)
                Button(CloudSyncStrings.useRecoveryWordsButton) {
                    let words = recoveryWords; recoveryWords = ""
                    Task { await controller.useRecoveryWords(words) }
                }
                .disabled(recoveryWords.split(whereSeparator: \.isWhitespace).count != 24 || controller.isWorking)
            } header: { Text(CloudSyncStrings.useRecoveryWords) }
        }
        if controller.needsNotePasswordInput {
            Section {
                Text(CloudSyncStrings.notePasswordPrompt).foregroundStyle(.secondary)
                SecureField(CloudSyncStrings.notePasswordField, text: $notePassword)
                Button(CloudSyncStrings.notePasswordButton) {
                    let password = notePassword; notePassword = ""
                    Task { await controller.submitNotePassword(password) }
                }
                .disabled(notePassword.isEmpty || controller.isWorking)
            } header: { Text(CloudSyncStrings.headline(for: .needsNotePassword)) }
        }
        if controller.canUploadAgain {
            Section {
                Button(CloudSyncStrings.uploadAgain) { Task { await controller.uploadAgain() } }.disabled(controller.isWorking)
                Text(CloudSyncStrings.uploadAgainDetail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        if controller.missingCount != nil {
            Section {
                Button(CloudSyncStrings.uploadThemAgain) { Task { await controller.uploadThemAgain() } }.disabled(controller.isWorking)
                Text(CloudSyncStrings.uploadThemAgainDetail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        if controller.accountChanged {
            Section {
                Button(CloudSyncStrings.accountChangedTitle + "…") { controller.showsAccountChangedSheet = true }
            }
        }
        if controller.showsOpenICloudSettings {
            Section {
                Button(CloudSyncStrings.openICloudSettings) { Self.openICloudSettings() }
            }
        }
    }

    static func openICloudSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane") { NSWorkspace.shared.open(url) }
    }

    // MARK: recovery words, sync, delete

    private var recoverySection: some View {
        Section {
            if controller.recoverySaved {
                Label(CloudSyncStrings.recoverySavedLine, systemImage: "checkmark.seal").foregroundStyle(.secondary)
                Button(CloudSyncStrings.replaceRecoveryWords) { controller.beginCreateOrReplaceRecoveryWords() }
                    .disabled(controller.isWorking || controller.needsRecoveryWords)
                Text(CloudSyncStrings.replaceRecoveryDetail).font(.footnote).foregroundStyle(.secondary)
            } else {
                Label(CloudSyncStrings.recoveryNotSavedLine, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(controller.showsRecoveryReminder ? Color.orange : Color.secondary)
                    .accessibilityIdentifier("cloud-sync-recovery-reminder")
                Button(CloudSyncStrings.createRecoveryWords) { controller.beginCreateOrReplaceRecoveryWords() }
                    .disabled(controller.isWorking || controller.needsRecoveryWords)
            }
        } header: { Text(CloudSyncStrings.recoverySection) }
    }

    private var syncSection: some View {
        Section {
            Button(CloudSyncStrings.syncNow) { Task { await controller.syncNow() } }.disabled(controller.isWorking)
            Button(CloudSyncStrings.stopSyncing) { Task { await controller.stopSyncing() } }
            Text(CloudSyncStrings.stopSyncingDetail).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var deleteSection: some View {
        Section {
            Button(CloudSyncStrings.deleteCopy, role: .destructive) { confirmingDelete = true }.disabled(controller.isWorking)
            DisclosureGroup(CloudSyncStrings.advanced, isExpanded: $showsAdvanced) {
                Button(CloudSyncStrings.removeKey, role: .destructive) { confirmingRemoveKey = true }.disabled(controller.isWorking)
            }
        }
    }
}
