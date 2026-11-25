// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesWatch

struct WatchComplicationTests {
    @Test func captureRouteContainsNoNoteOrTextPayload() throws {
        let route = try #require(URLComponents(url: WatchCaptureComplicationRoute.url, resolvingAgainstBaseURL: false))
        #expect(route.scheme == WatchCaptureComplicationRoute.scheme && route.host == "capture")
        #expect(route.query == nil && route.fragment == nil && route.user == nil)
    }
    @Test func debugAndProductionRoutesDoNotCollide() {
        #expect(WatchCaptureComplicationRoute.scheme(bundleIdentifier: "com.truebrewbirdie.theonotes.dev.ios.watchkitapp.widgets") == "theonotes-watch-dev")
        #expect(WatchCaptureComplicationRoute.scheme(bundleIdentifier: "com.truebrewbirdie.theonotes.ios.watchkitapp.widgets") == "theonotes-watch")
    }
}
