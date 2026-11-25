// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

enum WatchCaptureComplicationRoute {
    static func scheme(bundleIdentifier: String) -> String {
        bundleIdentifier.contains(".dev.ios.watchkitapp") ? "theonotes-watch-dev" : "theonotes-watch"
    }
    static var scheme: String { scheme(bundleIdentifier: Bundle.main.bundleIdentifier ?? "") }
    static var url: URL { URL(string: "\(scheme)://capture")! }
}
