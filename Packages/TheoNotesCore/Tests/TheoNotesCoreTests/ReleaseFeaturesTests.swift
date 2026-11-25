// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

@Suite struct ReleaseFeaturesTests {
    private let key = "THEONOTES_SyncSetupAvailable"

    @Test func syncSetupIsOffUnlessTheBuildSaysYes() {
        #expect(ReleaseFeatures.syncSetupInfoKey == key)
        #expect(ReleaseFeatures.syncSetupAvailable(infoDictionary: nil) == false)
        #expect(ReleaseFeatures.syncSetupAvailable(infoDictionary: [:]) == false)
        #expect(ReleaseFeatures.syncSetupAvailable(infoDictionary: [key: "NO"]) == false)
        #expect(ReleaseFeatures.syncSetupAvailable(infoDictionary: [key: ""]) == false)
        // A build setting that was never substituted reaches the plist as its own name.
        #expect(ReleaseFeatures.syncSetupAvailable(infoDictionary: [key: "$(THEONOTES_SYNC_SETUP)"]) == false)
        #expect(ReleaseFeatures.syncSetupAvailable(infoDictionary: [key: "yes"]) == false)
        #expect(ReleaseFeatures.syncSetupAvailable(infoDictionary: [key: 1]) == false)
        #expect(ReleaseFeatures.syncSetupAvailable(infoDictionary: [key: "YES"]) == true)
        #expect(ReleaseFeatures.syncSetupAvailable(infoDictionary: [key: true]) == true)
    }

    @Test func aBundleWithoutTheKeyIsOff() {
        // The test runner's own bundle carries no such key: the strict side.
        #expect(ReleaseFeatures.syncSetupAvailable(bundle: Bundle(for: BundleToken.self)) == false)
    }

    // MARK: iCloud sync availability (CK-J2, Task 12)

    private let containerKey = "THEONOTES_CloudKitContainer"
    private let iCloudKey = "THEONOTES_ICloudSyncAvailable"
    private let container = "iCloud.com.truebrewbirdie.theonotes"

    @Test func theInfoKeysAreTheDocumentedOnes() {
        #expect(ReleaseFeatures.cloudKitContainerInfoKey == containerKey)
        #expect(ReleaseFeatures.iCloudSyncInfoKey == iCloudKey)
    }

    @Test func iCloudSyncNeedsAValidContainerAndTheFlag() {
        #expect(ReleaseFeatures.cloudSyncAvailable(infoDictionary: [containerKey: container, iCloudKey: "YES"]) == true)
        #expect(ReleaseFeatures.cloudSyncAvailable(infoDictionary: [containerKey: container, iCloudKey: true]) == true)
        // The flag off, or anything but YES, is off even with a container.
        #expect(ReleaseFeatures.cloudSyncAvailable(infoDictionary: [containerKey: container, iCloudKey: "NO"]) == false)
        #expect(ReleaseFeatures.cloudSyncAvailable(infoDictionary: [containerKey: container, iCloudKey: "yes"]) == false)
        #expect(ReleaseFeatures.cloudSyncAvailable(infoDictionary: [containerKey: container, iCloudKey: 1]) == false)
        #expect(ReleaseFeatures.cloudSyncAvailable(infoDictionary: [containerKey: container, iCloudKey: ""]) == false)
        #expect(ReleaseFeatures.cloudSyncAvailable(infoDictionary: [containerKey: container, iCloudKey: "$(THEONOTES_ICLOUD_SYNC)"]) == false)
        #expect(ReleaseFeatures.cloudSyncAvailable(infoDictionary: [containerKey: container]) == false)
    }

    @Test func aMissingOrBrokenContainerMeansNotAvailable() {
        func info(_ value: Any) -> [String: Any] { [iCloudKey: "YES", containerKey: value] }
        #expect(ReleaseFeatures.cloudSyncAvailable(infoDictionary: nil) == false)
        #expect(ReleaseFeatures.cloudSyncAvailable(infoDictionary: [iCloudKey: "YES"]) == false) // key missing
        // Empty container (the state of every build until the account exists), even with the flag on.
        #expect(ReleaseFeatures.cloudSyncAvailable(infoDictionary: info("")) == false)
        #expect(ReleaseFeatures.cloudSyncAvailable(infoDictionary: info("  ")) == false)
        // A build setting that was never substituted reaches the plist as its own name.
        #expect(ReleaseFeatures.cloudSyncAvailable(infoDictionary: info("$(THEONOTES_CLOUDKIT_CONTAINER)")) == false)
        // Wrong prefix, wrong shape, wrong type.
        for bad in ["com.truebrewbirdie.theonotes", "icloud.com.truebrewbirdie.theonotes", "iCloud.", "iCloud.theonotes",
                    "iCloud.com..theonotes", "iCloud.com.theonotes.", "iCloud.com.theo notes", "iCloud.com.theo/notes",
                    "iCloud.com.theonotes\n", " iCloud.com.truebrewbirdie.theonotes"] {
            #expect(ReleaseFeatures.cloudSyncAvailable(infoDictionary: info(bad)) == false, "\(bad)")
        }
        #expect(ReleaseFeatures.cloudSyncAvailable(infoDictionary: info(7)) == false)
    }

    @Test func theValidContainerIsReturnedAndOtherwiseNil() {
        #expect(ReleaseFeatures.cloudKitContainer(infoDictionary: [containerKey: container]) == container)
        #expect(ReleaseFeatures.cloudKitContainer(infoDictionary: [containerKey: "iCloud.com.example.app-2"]) == "iCloud.com.example.app-2")
        #expect(ReleaseFeatures.cloudKitContainer(infoDictionary: [containerKey: ""]) == nil)
        #expect(ReleaseFeatures.cloudKitContainer(infoDictionary: nil) == nil)
    }

    @Test func theCloudflareFlagAndTheICloudFlagAreIndependent() {
        let info: [String: Any] = ["THEONOTES_SyncSetupAvailable": "YES", containerKey: "", iCloudKey: "YES"]
        #expect(ReleaseFeatures.syncSetupAvailable(infoDictionary: info) == true)
        #expect(ReleaseFeatures.cloudSyncAvailable(infoDictionary: info) == false)
        let other: [String: Any] = ["THEONOTES_SyncSetupAvailable": "NO", containerKey: container, iCloudKey: "YES"]
        #expect(ReleaseFeatures.syncSetupAvailable(infoDictionary: other) == false)
        #expect(ReleaseFeatures.cloudSyncAvailable(infoDictionary: other) == true)
    }

    @Test func aBundleWithoutTheKeysHasNoICloudSync() {
        #expect(ReleaseFeatures.cloudSyncAvailable(bundle: Bundle(for: BundleToken.self)) == false)
        #expect(ReleaseFeatures.cloudKitContainer(bundle: Bundle(for: BundleToken.self)) == nil)
    }

    @Test func thePrivateSyncEndpointComesOnlyFromAPlainConfiguredHost() {
        let key = ReleaseFeatures.privateSyncHostInfoKey
        let none = ReleaseFeatures.unconfiguredPrivateSyncEndpoint
        #expect(none.host == "sync.invalid")
        #expect(ReleaseFeatures.privateSyncEndpoint(infoDictionary: [key: "sync.example.com"]).absoluteString == "https://sync.example.com")
        for bad: Any in ["", "$(THEONOTES_PRIVATE_SYNC_HOST)", "https://sync.example.com", "sync.example.com/path", "localhost", "a b.com", 1] {
            #expect(ReleaseFeatures.privateSyncEndpoint(infoDictionary: [key: bad]) == none)
        }
        #expect(ReleaseFeatures.privateSyncEndpoint(infoDictionary: nil) == none)
        #expect(ReleaseFeatures.privateSyncEndpoint(bundle: Bundle(for: BundleToken.self)) == none)
    }

    private final class BundleToken {}
}
