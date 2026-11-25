// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

struct MobileWidgetCleanupError: LocalizedError {
    var errorDescription: String? {
        "Sharing and widget data could not be cleared safely. Check the app's shared container and reopen Theo Notes."
    }
}
