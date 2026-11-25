// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import SwiftUI

@main struct TheoNotesWatchApp: App {
    @State private var transport = TheoNotesWatchTransport()
    var body: some Scene {
        WindowGroup {
            TheoNotesWatchRootView(presentation: transport.presentation, actions: transport)
        }
    }
}
