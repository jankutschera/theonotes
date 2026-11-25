// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import UIKit

/// The silent push of the iCloud sync (Gate G0 A4: it arrived in 15 s once the app registered for remote notifications, and never
/// without). The system calls this on the app delegate; the controller of the open library does the rest. A build or a library
/// without iCloud sync has no controller connected, so the answer is "no data" and nothing happens (CK-R172).
extension MobileBackgroundSessionDelegate {
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        await MobileCloudSyncRouter.handle(userInfo)
    }
}
