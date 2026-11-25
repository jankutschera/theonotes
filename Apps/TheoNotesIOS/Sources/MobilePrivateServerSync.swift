// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation

/// REL-R5, REL-R6, REL-R9: the private-server sync (Jan's builds) exists only in a build made with `THEONOTES_SYNC_SETUP = YES` (the
/// Info.plist key `THEONOTES_SyncSetupAvailable`). In any other build the Settings page is not linked, and nothing of it is made:
/// no controller, no scheduler, no background session, no background refresh. Every caller asks here instead of reading
/// `library.sync` (which builds the controller on first use).
enum MobilePrivateServerSync {
    static func isAvailable(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) -> Bool {
        ReleaseFeatures.syncSetupAvailable(infoDictionary: infoDictionary)
    }

    /// The library's private-server sync controller, or nil (and nothing built) when the build does not offer it.
    @MainActor static func controller(for library: MobileLibrary, infoDictionary: [String: Any]? = Bundle.main.infoDictionary) -> MobileSyncController? {
        isAvailable(infoDictionary: infoDictionary) ? library.sync : nil
    }
}
