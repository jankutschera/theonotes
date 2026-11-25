// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import SwiftUI

struct MobileSyncSettings: View {
    @Bindable var sync: MobileSyncController
    let library: MobileLibrary
    @State private var setupCode = ""
    @State private var words = ""
    @State private var notePassword = ""
    @State private var newNotePassword = ""
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingPairing = false
    @State private var showingSignOut = false
    @State private var showingRecoveryCopy = false
    @State private var showingOriginalLibrary = false
    @State private var showingRotation = false
    @State private var showingCreate = false
    @State private var showingRecovery = false
    @State private var recoverySaved = false
    @State private var showingRecoveryWords = false
    @State private var revokeTarget: MobileSyncController.Device?

    var body: some View {
        Form {
            Section {
                Label(sync.status, systemImage: sync.ready ? "icloud" : "icloud.slash")
                if sync.busy { ProgressView().accessibilityLabel("Working on sync") }
                if sync.syncing {
                    Button("Pause and Use App") { Task { await sync.pauseCurrentSync() } }.disabled(sync.paused)
                }
                if let notice = sync.recoveryNotice { Text(notice).foregroundStyle(.orange).textSelection(.enabled) }
                if let lastSync = sync.lastSync { LabeledContent("Last Sync", value: lastSync.formatted(date: .abbreviated, time: .shortened)) }
                if let error = sync.errorMessage { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            if sync.paused {
                Section { Button("Resume Sync") { Task { await sync.setPaused(false) } }.disabled(sync.busy) }
            }
            if sync.isRecoveryLibrary {
                Section("Recovery Library") {
                    Text("This separate library preserves your original and its pending sync history. Sign in and enter both note passwords when asked to reconcile protected notes.")
                    Button("Return to Original Library") { showingOriginalLibrary = true }.disabled(sync.busy)
                }
            }
            if sync.needsSeparateLibrary || sync.preparedRecoveryLibrary != nil {
                Section("Reconcile Different Note Vaults") {
                    Text("Create a verified separate copy. Your original library, published ancestors and pending changes stay intact. The new library requires its own sync sign-in and note-password authorization.")
                    if sync.preparedRecoveryLibrary != nil {
                        Button("Open Verified Recovery Library") { Task { await sync.openRecoveryCopy() } }.disabled(sync.busy)
                    } else {
                        Button("Create Separate Recovery Library") { showingRecoveryCopy = true }.disabled(sync.busy)
                    }
                }
            }
            if let phrase = sync.recoveryWords {
                Section("Save Your Recovery Key") {
                    Text("Save this one-time backup in a private place separate from this device. These 24 words recover your notes if you lose every connected device. To connect another device normally, use your passkey and approve it on this device.")
                    DisclosureGroup("Show recovery words", isExpanded: $showingRecoveryWords) {
                        if scenePhase == .active {
                            let words = phrase.split(separator: " ").map(String.init)
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                                ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                                    Text("\(index + 1). \(word)").font(.system(.body, design: .monospaced))
                                        .accessibilityLabel("Word \(index + 1), \(word)")
                                }
                            }.privacySensitive()
                        }
                    }
                    Toggle("I saved all 24 words securely", isOn: $recoverySaved)
                    Button("Continue to Sync") { Task { await sync.confirmRecoverySaved() } }
                        .disabled(!recoverySaved || sync.busy)
                }
            } else if !sync.ready {
                if sync.connected {
                    Section {
                        Button("Sign Out", role: .destructive) { showingSignOut = true }.disabled(sync.busy)
                        Button("Reconnect with a Passkey") { Task { await sync.signIn(create: false, setupCode: "") } }.disabled(sync.busy)
                    }
                }
                if !sync.connected {
                    Section("Connect Your Devices") {
                        Text("Sign in with your passkey, compare six words with a device that already has your notes, then approve sending your sync key there. Your notes and attachments stay end-to-end encrypted.")
                        Button("Sign In with a Passkey") { Task { await sync.signIn(create: false, setupCode: "") } }
                            .disabled(sync.busy)
                        Button("Recover My Account") { showingRecovery.toggle() }.disabled(sync.busy)
                        Button("Set Up the First Device") { showingCreate.toggle() }.disabled(sync.busy)
                    }
                }
                if showingCreate && !sync.connected {
                    Section("First-Time Setup") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Private setup code")
                            SecureField("Paste your setup code here", text: $setupCode)
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Private setup code")
                                .accessibilityIdentifier("sync-setup-code")
                        }
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Text("Use the setup code from your Theo Notes service installation. It is needed only when creating the first account.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Create Passkey and Account") {
                            let code = setupCode; setupCode = ""
                            Task { await sync.signIn(create: true, setupCode: code) }
                        }.disabled(setupCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sync.busy)
                    }
                }
                if sync.needsRecovery || sync.pendingPairing != nil || sync.receivingInvitation != nil {
                    MobilePairingReceiver(sync: sync)
                    Section { Button("No connected device? Use recovery key") { showingRecovery.toggle() }.disabled(sync.busy) }
                }
                if showingRecovery {
                    Section("Recovery Key") {
                        Text("Enter the 24 words in order, separated by spaces.")
                        TextEditor(text: $words).frame(minHeight: 110)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                            .accessibilityLabel("24-word recovery key")
                        Button("Unlock Sync") {
                            let phrase = words; words = ""
                            Task { await sync.recover(words: phrase) }
                        }.disabled(words.split(whereSeparator: \.isWhitespace).count != 24 || sync.busy)
                    }
                }
            } else {
                MobilePairingRequests(sync: sync)
                Section("Sync") {
                    Toggle("Pause Sync", isOn: Binding(get: { sync.paused }, set: { value in Task { await sync.setPaused(value) } }))
                        .disabled(sync.busy)
                    Button("Sync Now") { Task { await sync.synchronize() } }.disabled(sync.busy || sync.paused)
                    Text("Changes stay saved on this device while sync is paused. A verified local backup is created before the first sync.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if sync.waitingForNotePassword {
                    Section("Protected Note Changes") {
                        Text("Enter your note password to merge encrypted edits. Conflicting versions are kept as separate protected notes.")
                        SecureField("Current password on this device", text: $notePassword).textContentType(.password)
                        SecureField("New password, if changed on another device", text: $newNotePassword).textContentType(.password)
                        Button("Resolve Protected Changes") {
                            let password = notePassword, changedPassword = newNotePassword
                            notePassword = ""; newNotePassword = ""
                            Task { await sync.resolveProtectedChanges(password: password, newPassword: changedPassword) }
                        }.disabled(sync.busy || sync.paused || notePassword.isEmpty)
                    }
                }
                Section("Recovery and Account") {
                    Button("Replace Recovery Key") { showingRotation = true }.disabled(sync.busy || sync.paused)
                    Text("The new key replaces the old 24 words. Connected devices keep access; notes and their encryption keys stay unchanged.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Sign Out", role: .destructive) { showingSignOut = true }.disabled(sync.busy)
                }
                Section("This Device") {
                    TextField("Device name", text: $sync.deviceName)
                    Button("Save Device Name") { Task { await sync.renameDevice() } }
                        .disabled(sync.busy || sync.deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section("Connected Devices") {
                    Button("Connect Another Device") { showingPairing = true }.disabled(sync.busy)
                    ForEach(sync.devices) { device in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(device.name)
                                if device.current { Text("This device").font(.caption).foregroundStyle(.secondary) }
                            }
                            Text("Last seen " + device.lastSeen.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                            if !device.current {
                                Button("Remove Access", role: .destructive) { revokeTarget = device }.disabled(sync.busy)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Sync")
        .task {
            sync.setSensitivePresentation(scenePhase == .active)
            await sync.load()
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await sync.refreshPairingRequests()
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
            }
        }
        .sheet(isPresented: $showingPairing) { MobilePairingSender(sync: sync) }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                setupCode = ""; words = ""; notePassword = ""; newNotePassword = ""; recoverySaved = false; showingRecoveryWords = false; showingRecovery = false
                sync.setSensitivePresentation(false)
            } else { sync.setSensitivePresentation(true); Task { await sync.load() } }
            if phase == .background, sync.receivingInvitation != nil { Task { await sync.cancelPairing() } }
        }
        .onDisappear {
            if sync.receivingInvitation != nil { Task { await sync.cancelPairing() } }
        }
        .onDisappear { notePassword = ""; newNotePassword = "" }
        .confirmationDialog("Remove this device’s access?", isPresented: Binding(get: { revokeTarget != nil }, set: { if !$0 { revokeTarget = nil } }), titleVisibility: .visible) {
            if let target = revokeTarget {
                Button("Remove \(target.name)", role: .destructive) { Task { await sync.revoke(target.id) }; revokeTarget = nil }
            }
        } message: {
            Text("The device will stop receiving and uploading changes. Notes already downloaded remain on that device.")
        }
        .confirmationDialog("Create a separate recovery library?", isPresented: $showingRecoveryCopy, titleVisibility: .visible) {
            Button("Pause Sync and Create Verified Copy") { Task { await sync.prepareRecoveryCopy() } }
        } message: {
            Text("Your original library and every pending change remain on this device. A verified backup and a new local library use additional storage. Nothing is deleted or uploaded by creating the copy.")
        }
        .confirmationDialog("Return to your original library?", isPresented: $showingOriginalLibrary, titleVisibility: .visible) {
            Button("Pause Sync and Open Original") { Task { await sync.returnToOriginalLibrary() } }
        } message: {
            Text("The recovery library stays on this device. Your original library reopens with sync paused, keeping its pending changes and published history.")
        }
        .confirmationDialog("Replace your recovery key?", isPresented: $showingRotation, titleVisibility: .visible) {
            Button("Create New Recovery Key") { recoverySaved = false; Task { await sync.rotateRecoveryKey() } }
        } message: {
            Text("Save the new 24 words before activating them. Once activated, the old words cannot recover this account.")
        }
        .confirmationDialog("Sign out of sync?", isPresented: $showingSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { Task { await sync.signOut() } }
        } message: {
            Text("Your local notes and pending changes are kept. Sync stops and this device’s saved account keys are removed. You need a connected device or the recovery key to reconnect. Remote notes and passkeys are not deleted.")
        }
        .onChange(of: sync.recoveryWords) { _, _ in recoverySaved = false; showingRecoveryWords = false }
        .onDisappear { setupCode = ""; words = "" }
    }
}
