// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import BaerchenIOS

@Suite struct CaptureControlTests {
    @Test func allSixActionsHaveUniqueRoutesWithoutPersistedDeliveryIdentity() {
        #expect(WidgetCaptureAction.allCases.count == 6)
        #expect(Set(WidgetCaptureAction.allCases.map(\.rawValue)).count == 6)
        for action in WidgetCaptureAction.allCases {
            let parts = URLComponents(url: action.url(), resolvingAgainstBaseURL: false)
            #expect(parts?.scheme == WidgetRoutes.scheme && parts?.host == "widget")
            #expect(parts?.queryItems?.first { $0.name == "action" }?.value == action.rawValue)
            #expect(parts?.queryItems?.contains { $0.name == "delivery" } == false)
        }
        let id = "note?x=&é", library = "library#?="
        let parts = URLComponents(url: WidgetRoutes.note(id, libraryID: library), resolvingAgainstBaseURL: false)
        #expect(parts?.queryItems?.first { $0.name == "note" }?.value == id)
        #expect(parts?.queryItems?.first { $0.name == "library" }?.value == library)
    }
}

@Suite @MainActor struct CaptureControlDispatchTests {
    @Test func allRoutesReachTheHostWithDistinctDeliveryIDsAndMissingHostFailsClosed() async throws {
        defer { WidgetCaptureRuntime.handler = nil }
        WidgetCaptureRuntime.handler = nil
        await #expect(throws: WidgetCaptureRuntime.Unavailable.self) {
            try await WidgetCaptureRuntime.deliver(.thought, deliveryID: UUID())
        }
        var deliveries: [(WidgetCaptureAction, UUID)] = []
        WidgetCaptureRuntime.handler = { action, id in deliveries.append((action, id)) }
        for action in WidgetCaptureAction.allCases { _ = try await WidgetCaptureIntent(action).perform() }
        #expect(deliveries.map { $0.0 } == WidgetCaptureAction.allCases)
        #expect(Set(deliveries.map { $0.1 }).count == 6)
    }
}
