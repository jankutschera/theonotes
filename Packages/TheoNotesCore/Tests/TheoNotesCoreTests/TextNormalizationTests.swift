// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

@Suite struct TextNormalizationTests {
    @Test func testCRLFAndLoneCRBecomeLF() {
        #expect(TextNormalization.normalizeLineEndings("a\r\nb") == "a\nb")
        #expect(TextNormalization.normalizeLineEndings("a\rb") == "a\nb")
        #expect(TextNormalization.normalizeLineEndings("a\r\r\nb\n\rc\r") == "a\n\nb\n\nc\n")
        #expect(TextNormalization.normalizeLineEndings("\r\n👩‍👩‍👧\r漢字\r\n") == "\n👩‍👩‍👧\n漢字\n")
        #expect(TextNormalization.normalizeLineEndings("no breaks é") == "no breaks é")
        #expect(TextNormalization.normalizeLineEndings("") == "")
        // The result has as many UTF-16 units as CodeMirror's document for the same input.
        #expect(TextNormalization.normalizeLineEndings("a\r\nb").utf16.count == 3)
    }
}
