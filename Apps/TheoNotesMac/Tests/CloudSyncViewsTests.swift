// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import SwiftUI
import Testing
@testable import TheoNotes

/// The iCloud tab and its two sheets lay out and carry the right controls. Optional pictures (never a window on the screen):
/// `TEST_RUNNER_BAERCHEN_CLOUD_PNG_DIR=/some/dir xcodebuild … test` writes one PNG per state; run it only with the screen unlocked.
@MainActor @Suite(.serialized) struct CloudSyncViewsTests {
    private func render<V: View>(_ view: V, name: String, width: CGFloat, height: CGFloat? = nil) async throws -> NSHostingView<some View> {
        let hosting = NSHostingView(rootView: view.frame(width: width).environment(\.scenePhase, .active))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height ?? 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.fittingSize.width > 0 && hosting.fittingSize.height > 0, "\(name) lays out")
        if let dir = ProcessInfo.processInfo.environment["BAERCHEN_CLOUD_PNG_DIR"] {
            window.appearance = NSAppearance(named: .aqua)
            hosting.frame = CGRect(origin: .zero, size: CGSize(width: width, height: height ?? max(hosting.fittingSize.height, 200)))
            hosting.layoutSubtreeIfNeeded()
            if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
            }
        }
        return hosting
    }

    @Test func theTabInEveryStateLaysOut() async throws {
        let device = try CloudMacDevice()
        defer { device.cleanup() }
        let note = try device.note("# Mine\n")
        _ = try await render(CloudSyncSettingsView(controller: device.controller), name: "icloud-tab-off", width: 500, height: 330)

        try await device.turnOnAndSkip()
        _ = try await render(CloudSyncSettingsView(controller: device.controller), name: "icloud-tab-on-recovery-not-saved", width: 500, height: 640)

        await device.cloud.removeRecord("e.note.\(note.id)")
        await device.controller.syncNow()
        await device.fake.pushRemoteChange()
        await device.controller.syncNow()
        #expect(device.controller.missingCount == 1)
        _ = try await render(CloudSyncSettingsView(controller: device.controller), name: "icloud-tab-error-notes-missing", width: 500, height: 720)
        await device.controller.shutdown()
    }

    @Test func theRecoverySheetShowsTwentyFourWordsACopyButtonThreeFieldsAndTheRiskSentence() async throws {
        let device = try CloudMacDevice()
        defer { device.cleanup() }
        await device.controller.turnOn()
        let hosting = try await render(CloudRecoveryKeySheet(controller: device.controller), name: "icloud-recovery-sheet", width: 460, height: 760)
        let offer = try #require(device.controller.recoveryOffer)
        #expect(offer.words.split(separator: " ").count == 24)
        #expect(hosting.fittingSize.height > 300)
        #expect(CloudSyncStrings.sheetRiskSentence == "If I lose all my devices and iCloud Keychain, my notes in iCloud cannot be recovered")
        #expect(CloudSyncStrings.sheetSkip == "Skip for now")
        await device.controller.cancelRecoverySheet()
    }

    @Test func theAccountChangedSheetOffersKeepOfflineFirst() async throws {
        let device = try CloudMacDevice()
        defer { device.cleanup() }
        _ = try await render(CloudAccountChangedSheet(controller: device.controller), name: "icloud-account-changed-sheet", width: 440, height: 380)
        #expect(CloudSyncStrings.keepOffline == "Keep this library offline")
        #expect(CloudSyncStrings.syncWithNewAccount == "Sync with the new iCloud account")
    }

    @Test func thePrivateServerLibraryShowsItsOwnLine() async throws {
        let device = try CloudMacDevice()
        defer { device.cleanup() }
        try await device.environment.database.pool.write { try $0.execute(sql: "UPDATE sync_control SET backend='cloudflare' WHERE id=1") }
        await device.controller.start()
        _ = try await render(CloudSyncSettingsView(controller: device.controller), name: "icloud-tab-private-server", width: 500, height: 240)
        #expect(device.controller.boundToPrivateServer)
    }

    @Test func theSettingsPaneBuildsTheTabOnlyWithTheFlag() async throws {
        let on = try CloudMacDevice(flag: true)
        let off = try CloudMacDevice(flag: false)
        defer { on.cleanup(); off.cleanup() }
        let settings = SettingsModel(database: on.environment.database)
        let offSettings = SettingsModel(database: off.environment.database)
        let pane = NSHostingView(rootView: SettingsPane(tab: .icloud, settings: settings, environment: on.environment).frame(width: 500))
        pane.layoutSubtreeIfNeeded()
        #expect(pane.fittingSize.height > 50)
        let empty = NSHostingView(rootView: SettingsPane(tab: .icloud, settings: offSettings, environment: off.environment).frame(width: 500))
        empty.layoutSubtreeIfNeeded()
        #expect(empty.fittingSize.height < 50, "a build without the flag builds nothing for the tab")
        #expect(!off.environment.cloudSyncStarted)
    }
}
