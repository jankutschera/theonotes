// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

@Suite struct ThreeWayMergeTests {
    @Test func testCleanMergeOfNonOverlappingChanges() {
        let base = "line1\nline2\nline3"
        let local = "LINE1\nline2\nline3"
        let remote = "line1\nline2\nLINE3"
        #expect(ThreeWayMerge.merge(base: base, local: local, remote: remote) == .clean("LINE1\nline2\nLINE3"))
    }

    @Test func testCleanMergeWithInsertionsAndDeletions() {
        let base = "a\nb\nc\nd\ne"
        let local = "a\nnew\nb\nc\nd\ne"
        let remote = "a\nb\nc\ne\nend"
        #expect(ThreeWayMerge.merge(base: base, local: local, remote: remote) == .clean("a\nnew\nb\nc\ne\nend"))
    }

    @Test func testConflictWhenBothChangeSameLine() {
        let base = "line1\nline2\nline3"
        let local = "line1\nlocal\nline3"
        let remote = "line1\nremote\nline3"
        #expect(ThreeWayMerge.merge(base: base, local: local, remote: remote) == .conflict)
    }

    @Test func testIdenticalChangeOnBothSidesMerges() {
        let base = "line1\nline2\nline3"
        let both = "line1\nsame 漢字 👩‍👩‍👧\nline3"
        #expect(ThreeWayMerge.merge(base: base, local: both, remote: both) == .clean(both))
    }

    @Test func testOneSideUnchangedTakesOther() {
        let base = "x\ny"
        #expect(ThreeWayMerge.merge(base: base, local: base, remote: "z") == .clean("z"))
        #expect(ThreeWayMerge.merge(base: base, local: "x\ny\n", remote: base) == .clean("x\ny\n"))
        #expect(ThreeWayMerge.merge(base: "", local: "a", remote: "") == .clean("a"))
    }

    @Test func testCRLFInputsMergeLineByLine() {
        // "\r\n" is one Swift Character; lines must still split at every "\n".
        let base = "line1\r\nline2\r\nline3"
        let local = "LINE1\r\nline2\r\nline3"
        let remote = "line1\r\nline2\r\nLINE3"
        #expect(ThreeWayMerge.merge(base: base, local: local, remote: remote) == .clean("LINE1\r\nline2\r\nLINE3"))
        let n = TextNormalization.normalizeLineEndings
        #expect(ThreeWayMerge.merge(base: n(base), local: n(local), remote: n(remote)) == .clean("LINE1\nline2\nLINE3"))
    }

    @Test func testCanonicallyEquivalentLinesAreDistinct() {
        // NFC "é" vs NFD "e\u{301}": Swift String == says equal, the bytes differ.
        let base = "caf\u{E9}\nmid\nend"
        let local = "cafe\u{301}\nmid\nend"
        let remote = "caf\u{E9}\nmid\nEND"
        guard case .clean(let merged) = ThreeWayMerge.merge(base: base, local: local, remote: remote) else {
            Issue.record("expected a clean merge")
            return
        }
        #expect(Array(merged.utf8) == Array("cafe\u{301}\nmid\nEND".utf8))
        guard case .clean(let remoteOnly) = ThreeWayMerge.merge(base: base, local: base, remote: local) else {
            Issue.record("expected a clean merge")
            return
        }
        #expect(Array(remoteOnly.utf8) == Array(local.utf8))
    }

    @Test func testConflictingAppendsAtEnd() {
        #expect(ThreeWayMerge.merge(base: "a", local: "a\nb", remote: "a\nc") == .conflict)
    }

    @Test func testChangeSetIdentityAndSimpleCases() throws {
        #expect(ThreeWayMerge.changeSet(from: "abc", to: "abc").sections == [.retain(3)])
        #expect(ThreeWayMerge.changeSet(from: "", to: "").sections == [])
        #expect(ThreeWayMerge.changeSet(from: "abc", to: "aXc").sections
            == [.retain(1), .replace(deleteLength: 1, insert: "X"), .retain(1)])
        #expect(try ThreeWayMerge.changeSet(from: "", to: "a\nb").apply(to: "") == "a\nb")
    }

    @Test func testChangeSetNeverSplitsSurrogatePairs() throws {
        // 😀 = D83D DE00, 😁 = D83D DE01 (shared lead); 🈀 = D83C DE00 (shared trail with 😀).
        let pairs: [(String, String)] = [("😀", "😁"), ("x😀y", "x😁y"), ("😀", "🈀"), ("a😀", "a🈀"), ("😀😀", "😀😁")]
        for (old, new) in pairs {
            let cs = ThreeWayMerge.changeSet(from: old, to: new)
            #expect(try cs.apply(to: old) == new, "\(old) -> \(new)")
        }
    }

    @Test func testChangeSetRoundTripRandomEmojiAndCJK() throws {
        let alphabet: [String] = [
            "a", "b", " ", "\n", "é", "漢", "字", "語", "😀", "😁", "🈀", "👍🏽", "👩‍👩‍👧", "🇩🇪",
        ]
        var rng = SplitMix64(seed: 0xBAE2C4E2)
        func randomString(_ maxLen: Int) -> String {
            let len = Int.random(in: 0...maxLen, using: &rng)
            return (0..<len).map { _ in alphabet.randomElement(using: &rng)! }.joined()
        }
        for i in 0..<200 {
            let old = randomString(12)
            let new: String
            if i.isMultiple(of: 2) {
                new = randomString(12)
            } else {
                // Shared prefix/suffix with a random middle to exercise boundary trimming.
                new = String(old.prefix(Int.random(in: 0...old.count, using: &rng))) + randomString(3)
                    + String(old.suffix(Int.random(in: 0...old.count, using: &rng)))
            }
            let cs = ThreeWayMerge.changeSet(from: old, to: new)
            #expect(cs.oldLength == old.utf16.count)
            #expect(try cs.apply(to: old) == new, "\(old.debugDescription) -> \(new.debugDescription)")
        }
    }
}

struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
