// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import SwiftUI
import TheoNotesCore
import UniformTypeIdentifiers

struct MobileAutomationSettings: View {
    let library: MobileLibrary
    @State private var hasToken = false
    @Environment(\.scenePhase) private var phase
    var body: some View {
        Form {
            Section("Apple Shortcuts") {
                Text("For a one-action capture, choose Save to Theo Notes. It uses shared text, links, images or files, picks a title automatically and copies the new note link. You can change the title or turn off copying in the action.")
                Text("To use it from another app, enable Show in Share Sheet in your shortcut and pass Shortcut Input to Content. Shortcuts may download web addresses as files. Pass a URL as text to save just the link.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("In Shortcuts, add an action and choose Theo Notes to create, find, open or read notes, or append text. A note returned by one action can be used in the next.")
                Text("These actions open Theo Notes and require an unlocked device and library. Password-protected notes are excluded. No API token is needed for native Shortcuts actions.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button(hasToken ? "Copy Token" : "Generate and Copy Token") {
                    library.perform {
                        guard !library.appLocked else { return }
                        let token = try MobileAutomationToken.load(library.paths) ?? MobileAutomationToken.generate(library.paths)
                        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: token]], options: [.localOnly: true, .expirationDate: Date.now.addingTimeInterval(300)])
                        hasToken = true
                    }
                }
                if hasToken {
                    Button("Replace API Token", role: .destructive) {
                        library.perform { guard !library.appLocked else { return }; try MobileAutomationToken.generate(library.paths); hasToken = true }
                    }
                }
            } header: { Text("URL Automation API Token") } footer: { Text("Use this device's token for URL automation that reads existing notes, lists tags or uses the selected note. Replacing the token disconnects existing URL integrations. Tokens stay on this device.") }
            Section {
                Text("\(AppIdentity.current.urlSchemes[0])://x-callback-url/create?text=Hello").font(.footnote.monospaced()).textSelection(.enabled)
                Text("Existing \(AppIdentity.current.urlSchemes[1]):// automation links continue to work.")
            } header: { Text("URL Scheme") }
        }
        .navigationTitle("Automation")
        .privacySensitive()
        .task { hasToken = (try? MobileAutomationToken.load(library.paths)) != nil }
        .onChange(of: phase) { _, value in
            hasToken = value == .active && (try? MobileAutomationToken.load(library.paths)) != nil
        }
    }
}
