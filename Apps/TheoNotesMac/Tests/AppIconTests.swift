// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import Foundation
import Testing

@MainActor
@Suite struct AppIconTests {
    @Test func theAppIconHasEveryMacSize() {
        let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        let sides = Set(icon.representations.map { Int($0.pixelsWide) })
        #expect(sides.isSuperset(of: [16, 32, 64, 128, 256, 512, 1024]))
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String == "AppIcon")
    }
}
