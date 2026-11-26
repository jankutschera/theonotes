// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

/// two identities. The production values below are pinned on purpose: Jan's
/// installed app keeps its keychain items, notification permission, App Group and links only while
/// they never change. Editing one of these literals is a data-migration decision, not a refactor.
@Suite struct AppIdentityTests {
    @Test func productionValuesArePinned() {
        let production = AppIdentity.production
        #expect(production.bundleIdentifier == "com.truebrewbirdie.theonotes")
        #expect(production.displayName == "Theo Notes")
        #expect(production.appGroupIdentifier == "Q446J364FH.com.truebrewbirdie.notes")
        #expect(production.urlSchemes == ["theonotes", "baerchen"])
        #expect(production.keychainAccessGroup == "Q446J364FH.com.truebrewbirdie.theonotes")
        #if os(macOS)
        #expect(production.libraryFolderName == "Theo Notes")
        #endif
    }

    @Test func theSyncKeychainServiceIsUnchanged() {
        // Items of the installed app's sync account live under this service.
        #expect(KeychainSyncStore.keychainService == IdentityPinsTests.expectedSyncService)
    }

    @Test func devValuesAreSeparateFromProductionInEveryField() {
        let dev = AppIdentity.dev
        let production = AppIdentity.production
        #expect(dev.bundleIdentifier == "com.truebrewbirdie.theonotes.dev")
        #expect(dev.displayName == "Theo Notes Dev")
        #expect(dev.appGroupIdentifier == "Q446J364FH.com.truebrewbirdie.notes.dev")
        #expect(dev.urlSchemes == ["theonotes-dev", "baerchen-dev"])
        #expect(dev.keychainAccessGroup == "Q446J364FH.com.truebrewbirdie.theonotes.dev")
        #expect(dev.shareExtensionBundleIdentifier == "com.truebrewbirdie.theonotes.dev.share")
        #expect(production.shareExtensionBundleIdentifier == "com.truebrewbirdie.theonotes.share")
        #expect(dev.libraryFolderName != production.libraryFolderName)
        #expect(dev.libraryFolderName.hasSuffix(" Dev"))
        #expect(Set(dev.urlSchemes).isDisjoint(with: production.urlSchemes))
        #expect(dev.appGroupIdentifier != production.appGroupIdentifier)
        #if os(macOS)
        #expect(dev.libraryFolderName == "Theo Notes Dev")
        #endif
    }

    @Test func theIdentityComesFromTheBundleIdentifier() {
        #expect(AppIdentity.identity(forBundleIdentifier: "com.truebrewbirdie.theonotes") == .production)
        #expect(AppIdentity.identity(forBundleIdentifier: "com.truebrewbirdie.theonotes.share") == .production)
        #expect(AppIdentity.identity(forBundleIdentifier: "com.truebrewbirdie.theonotes.dev") == .dev)
        #expect(AppIdentity.identity(forBundleIdentifier: "com.truebrewbirdie.theonotes.dev.share") == .dev)
        // Anything else is production, which is the strict side: a dev build must say so exactly.
        #expect(AppIdentity.identity(forBundleIdentifier: nil) == .production)
        #expect(AppIdentity.identity(forBundleIdentifier: "com.apple.dt.xctest.tool") == .production)
        #expect(AppIdentity.identity(forBundleIdentifier: "com.truebrewbirdie.theonotes.devious") == .production)
        #expect(AppIdentity.identity(forBundleIdentifier: "com.truebrewbirdie.theonotes.tests") == .production)
    }

    @Test func aProcessWithoutAnAppBundleIsProduction() {
        // `swift test` and the command line tool are not an app bundle: they are never the dev app.
        #expect(AppIdentity.current == .production)
    }

    @Test func everyIdentitysSchemesAreKnownToTheCallbackParser() {
        #expect(Set(AppIdentity.allCases.flatMap(\.urlSchemes)) == ["theonotes", "baerchen", "theonotes-dev", "baerchen-dev"])
    }
}
