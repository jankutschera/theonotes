// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

@Suite struct CanonicalKeyTests {
    @Test func testCaseInsensitive() {
        #expect(CanonicalKey.make("Äpfel") == CanonicalKey.make("äpfel"))
        #expect(CanonicalKey.make("Work/Projects") == CanonicalKey.make("work/projects"))
    }

    @Test func testNFDEqualsNFC() {
        #expect(CanonicalKey.make("A\u{308}pfel") == CanonicalKey.make("\u{C4}pfel"))
    }

    @Test func testKeyIsNFC() {
        let key = CanonicalKey.make("İstanbul")
        #expect(key == key.precomposedStringWithCanonicalMapping)
        #expect(Array(key.unicodeScalars) == Array(key.precomposedStringWithCanonicalMapping.unicodeScalars))
        #expect(key.hasSuffix("stanbul"))
    }

    @Test func testDiacriticsAreKept() {
        #expect(CanonicalKey.make("Apfel") != CanonicalKey.make("Äpfel"))
    }
}
