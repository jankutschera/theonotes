// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Security
import Testing
@testable import TheoNotes

/// FOC-R360 ... FOC-R363: the build that runs the tests is a dev-identity build, and the identity the
/// code reports is the one the bundle was really built and signed with (Info.plist, entitlements).
/// The production side is pinned by `AppIdentityTests` (values) and `scripts/check-identities.sh`
/// (build settings of both configurations).
@Suite struct AppIdentityBuildTests {
    private var identity: AppIdentity { .current }

    private func entitlement(_ key: String) -> Any? { HostEntitlements.value(key) }

    @Test func testsNeverRunAsTheProductionIdentity() {
        // A test host with the production bundle id would share notifications, keychain items and link
        // registrations with the installed app. Build tests with the Debug configuration.
        #expect(identity == .dev)
        #expect(Bundle.main.bundleIdentifier == AppIdentity.devBundleIdentifier)
    }

    @Test func theBundleCarriesTheIdentitysNameAndLinks() throws {
        let info = try #require(Bundle.main.infoDictionary)
        #expect(Bundle.main.bundleIdentifier == identity.bundleIdentifier)
        #expect(info["CFBundleDisplayName"] as? String == identity.displayName)
        let types = try #require(info["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        #expect(schemes == identity.urlSchemes)
        #expect(types.compactMap { $0["CFBundleURLName"] as? String } == [identity.bundleIdentifier])
    }

    @Test func theSignedEntitlementsMatchTheIdentity() {
        #expect(entitlement("com.apple.security.application-groups") as? [String] == [identity.appGroupIdentifier])
        // Team-signed builds carry the identity's keychain access group. The ad hoc dev build (project.yml)
        // carries none; what it must never carry is another identity's group.
        let groups = entitlement("keychain-access-groups") as? [String]
        #expect(groups == nil || groups == [identity.keychainAccessGroup])
        if identity == .production { #expect(groups == [identity.keychainAccessGroup]) }
    }

    @Test func theTeamIsOneBuildSettingThatEveryDerivedValueFollows() throws {
        // REL-R20 / R21: THEONOTES_TEAM_ID is written into the Info.plist, and the team the code uses, the
        // App Group and (when team-signed) the application identifier and keychain access group all start with it.
        let info = try #require(Bundle.main.infoDictionary)
        let team = try #require(info[AppIdentity.teamInfoKey] as? String, "Info.plist has no THEONOTES_TeamID")
        #expect(team.count == 10 && !team.contains("$"))
        #expect(AppIdentity.teamPrefix == team)
        #expect(identity.appGroupIdentifier.hasPrefix(team + "."))
        let groups = try #require(entitlement("com.apple.security.application-groups") as? [String])
        #expect(groups.allSatisfy { $0.hasPrefix(team + ".") })
        if let signed = entitlement("com.apple.application-identifier") as? String {
            #expect(signed == team + "." + identity.bundleIdentifier)
        }
        if let keychain = entitlement("keychain-access-groups") as? [String] {
            #expect(keychain == [team + "." + identity.bundleIdentifier])
        }
    }

    @Test func theLibraryAndShareGroupFollowTheIdentity() {
        #expect(AppPaths.production.root.lastPathComponent == identity.libraryFolderName)
        #expect(AppEnvironment.shareGroupIdentifier == identity.appGroupIdentifier)
        #expect(ShareRequestBuilder.groupIdentifier == identity.appGroupIdentifier)
    }

    @Test func theExportedTypesKeepTheirIdentifiers() throws {
        // REN2-R46: the note-ids and tag-path ids come from THEONOTES_BUNDLE_ROOT, the Swift ids from LegacyNames (a changed
        // id orphans every dragged note list). REN2-R50: the backup type is fixed; old and internal backups keep the
        // imported legacy type so every backup file the system knows still opens.
        let info = try #require(Bundle.main.infoDictionary)
        let types = try #require(info["UTExportedTypeDeclarations"] as? [[String: Any]])
        let ids = types.compactMap { $0["UTTypeIdentifier"] as? String }
        #expect(ids == ["com.truebrewbirdie.theonotes.backup", "com.truebrewbirdie.theonotes.note-ids",
                        "com.truebrewbirdie.theonotes.tag-path"])
        #expect(ids == [BackupFileType.identifier, LegacyNames.noteIDsUTI, LegacyNames.tagPathUTI])
        let imported = try #require(info["UTImportedTypeDeclarations"] as? [[String: Any]])
        #expect(imported.compactMap { $0["UTTypeIdentifier"] as? String }.contains(LegacyNames.backupUTI))
    }

    @Test func theLockedNoteKeychainServiceFollowsTheBundleRoot() {
        // The Touch ID copy of the note key is stored under this service. The cutover (B7, REN2-R57) moved it with the
        // bundle id: the old items stay in the old access group and the new app asks for the password once.
        #expect(KeychainVaultKeyCache.defaultService == "com.truebrewbirdie.theonotes.note-vault")
    }
}
