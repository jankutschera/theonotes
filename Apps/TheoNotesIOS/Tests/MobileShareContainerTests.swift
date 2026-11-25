// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Testing
@testable import BaerchenIOS

@Suite @MainActor struct MobileShareContainerTests {
    @Test func fixtureLaunchesDoNotUseProductionContainer() {
        #if DEBUG
        #expect(!MobileShareContainer.usesProductionContainer(arguments: ["--ui-testing"], shortcutsUITesting: false))
        #expect(!MobileShareContainer.usesProductionContainer(arguments: [], shortcutsUITesting: true))
        #expect(!MobileShareContainer.usesProductionContainer(arguments: ["--ui-testing"], shortcutsUITesting: true))
        #else
        #expect(MobileShareContainer.usesProductionContainer(arguments: ["--ui-testing"], shortcutsUITesting: true))
        #endif
        #expect(MobileShareContainer.usesProductionContainer(arguments: [], shortcutsUITesting: false))
    }
}
