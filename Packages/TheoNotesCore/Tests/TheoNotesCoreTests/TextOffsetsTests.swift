// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Testing
@testable import TheoNotesCore

@Suite struct TextOffsetsTests {
    @Test func testUTF16ToUTF8AndBack() throws {
        let text = "a😀b"
        #expect(try TextOffsets.utf8Offset(fromUTF16: 3, in: text) == 5)
        #expect(try TextOffsets.utf16Offset(fromUTF8: 5, in: text) == 3)
        #expect(try TextOffsets.utf8Offset(fromUTF16: 0, in: text) == 0)
        #expect(try TextOffsets.utf8Offset(fromUTF16: 4, in: text) == 6)
        #expect(try TextOffsets.utf16Offset(fromUTF8: 6, in: text) == 4)
    }

    @Test func testSplitScalarThrows() {
        let text = "a😀b"
        #expect(throws: TextOffsetError.splitsScalar) {
            try TextOffsets.utf8Offset(fromUTF16: 2, in: text)
        }
        #expect(throws: TextOffsetError.splitsScalar) {
            try TextOffsets.utf16Offset(fromUTF8: 3, in: text)
        }
    }

    @Test func testOutOfBoundsThrows() {
        #expect(throws: TextOffsetError.outOfBounds) {
            try TextOffsets.utf8Offset(fromUTF16: 5, in: "a😀b")
        }
        #expect(throws: TextOffsetError.outOfBounds) {
            try TextOffsets.utf8Offset(fromUTF16: -1, in: "ab")
        }
        #expect(throws: TextOffsetError.outOfBounds) {
            try TextOffsets.utf16Offset(fromUTF8: 7, in: "a😀b")
        }
    }

    @Test func testIsValidUTF16Boundary() {
        let text = "a😀b"
        #expect(TextOffsets.isValidUTF16Boundary(0, in: text))
        #expect(TextOffsets.isValidUTF16Boundary(1, in: text))
        #expect(!TextOffsets.isValidUTF16Boundary(2, in: text))
        #expect(TextOffsets.isValidUTF16Boundary(3, in: text))
        #expect(TextOffsets.isValidUTF16Boundary(4, in: text))
        #expect(!TextOffsets.isValidUTF16Boundary(5, in: text))
        #expect(!TextOffsets.isValidUTF16Boundary(-1, in: text))
    }

    @Test func testCJKOffsets() throws {
        #expect(try TextOffsets.utf8Offset(fromUTF16: 2, in: "漢字") == 6)
        #expect(try TextOffsets.utf16Offset(fromUTF8: 3, in: "漢字") == 1)
    }
}
