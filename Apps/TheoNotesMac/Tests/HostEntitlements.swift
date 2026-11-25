// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Security
import Testing

/// What the signed test host (the app) was really given. The dev build is signed ad hoc (FOC-R368), so
/// it has no keychain access group; the tests that need the real data-protection keychain run only
/// when the host has one (a team-signed build), and say so when they do not.
enum HostEntitlements {
    static func value(_ key: String) -> Any? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(task, key as CFString, nil)
    }

    static let hasKeychainAccessGroup: Bool = value("keychain-access-groups") != nil

    static let keychainSkipReason: Comment =
        "needs a team-signed host with a keychain access group; the ad hoc dev build has none (FOC-R368)"
}
