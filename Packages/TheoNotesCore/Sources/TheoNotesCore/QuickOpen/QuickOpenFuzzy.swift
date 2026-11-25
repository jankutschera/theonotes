// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// Quick Open's fuzzy title matching (see `QuickOpen` for the scoring rules).
extension QuickOpen {
    static let matchScore = 16
    static let startBonus = 10
    static let boundaryBonus = 8
    static let consecutiveBonus = 4
    static let firstCharacterMultiplier = 2
    static let gapStart = -3
    static let gapExtension = -1

    /// Folded texts as Unicode scalar values in one flat buffer, with a 64-bit mask per text of
    /// the scalars it contains (by value mod 64) to skip most non-matches without scanning them.
    struct Corpus: Sendable, Equatable {
        var scalars: [UInt32] = []
        /// Text `i` is `scalars[starts[i]..<starts[i + 1]]`.
        var starts: [Int] = [0]
        var masks: [UInt64] = []
        /// The longest text, in scalars.
        var maxLength = 0

        var count: Int { masks.count }

        mutating func append(_ folded: String) {
            let appended: Void? = folded.utf8.withContiguousStorageIfAvailable { append(utf8: $0) }
            if appended == nil { appendScalars(of: folded) }
        }

        /// The fallback for a string without contiguous UTF-8 (bridged): scalar by scalar.
        mutating func appendScalars(of text: String) {
            var mask: UInt64 = 0
            for scalar in text.unicodeScalars {
                scalars.append(scalar.value)
                mask |= UInt64(1) &<< UInt64(scalar.value & 63)
            }
            finishText(mask: mask)
        }

        /// Appends a text given as (valid) UTF-8, decoded into a temporary buffer and appended at
        /// once (per-scalar appends dominate the load in debug builds).
        mutating func append(utf8 bytes: UnsafeBufferPointer<UInt8>) {
            var mask: UInt64 = 0
            let count = bytes.count
            if let base = bytes.baseAddress, count > 0 {
                withUnsafeTemporaryAllocation(of: UInt32.self, capacity: count) { decoded in
                    let out = decoded.baseAddress!
                    var i = 0, written = 0
                    while i < count {
                        let lead = UInt32(base[i])
                        var value: UInt32, length: Int
                        if lead < 0x80 {
                            value = lead; length = 1
                        } else if lead < 0xE0 {
                            value = lead & 0x1F; length = 2
                        } else if lead < 0xF0 {
                            value = lead & 0x0F; length = 3
                        } else {
                            value = lead & 0x07; length = 4
                        }
                        var k = 1
                        while k < length, i + k < count {
                            value = value &<< 6 | (UInt32(base[i + k]) & 0x3F)
                            k += 1
                        }
                        out[written] = value
                        written += 1
                        mask |= UInt64(1) &<< UInt64(value & 63)
                        i += length
                    }
                    scalars.append(contentsOf: UnsafeBufferPointer(start: out, count: written))
                }
            }
            finishText(mask: mask)
        }

        private mutating func finishText(mask: UInt64) {
            maxLength = Swift.max(maxLength, scalars.count - starts[starts.count - 1])
            starts.append(scalars.count)
            masks.append(mask)
        }

        /// Calls `body(index, score)` for every text `pattern` matches (each, scoring 0, when it
        /// is empty).
        func forEachMatch(_ pattern: [UInt32], _ body: (Int, Int) -> Void) {
            guard !pattern.isEmpty else {
                for index in masks.indices { body(index, 0) }
                return
            }
            let needed = pattern.reduce(UInt64(0)) { $0 | UInt64(1) &<< UInt64($1 & 63) }
            let scratch = Scratch(capacity: maxLength)
            defer { scratch.deallocate() }
            // Raw pointers and `while` loops: in debug builds, buffer subscripts and range
            // iterators are function calls on every character.
            pattern.withUnsafeBufferPointer { pattern in
                scalars.withUnsafeBufferPointer { all in
                    starts.withUnsafeBufferPointer { starts in
                        masks.withUnsafeBufferPointer { masks in
                            // No scalars at all: every text is empty, none can match.
                            guard let p = pattern.baseAddress, let starts = starts.baseAddress,
                                  let masks = masks.baseAddress, let all = all.baseAddress else { return }
                            let m = pattern.count, count = self.masks.count
                            var index = 0
                            while index < count {
                                if masks[index] & needed == needed {
                                    let start = starts[index]
                                    if let score = QuickOpen.fuzzyScore(p, m, all + start, starts[index + 1] - start, scratch) {
                                        body(index, score)
                                    }
                                }
                                index += 1
                            }
                        }
                    }
                }
            }
        }
    }

    /// DP rows for texts of up to `capacity` scalars: two score rows, two run-bonus rows and the
    /// position bonuses, in one allocation.
    struct Scratch {
        let capacity: Int
        let base: UnsafeMutablePointer<Int>

        init(capacity: Int) {
            self.capacity = Swift.max(capacity, 1)
            base = .allocate(capacity: 5 * self.capacity)
        }

        func deallocate() { base.deallocate() }
    }

    private static let impossible = Int.min / 4

    /// The query's folded scalars without whitespace.
    static func pattern(_ filter: String) -> [UInt32] {
        SearchText.fold(filter).unicodeScalars.filter { !$0.properties.isWhitespace }.map(\.value)
    }

    /// The best alignment score of `pattern` as a subsequence of `text` (both folded), nil when it
    /// is not one. Dynamic programming over the window between the first possible start and the
    /// last possible end: O(pattern × window). `text` has at most `s.capacity` scalars. Written
    /// with raw pointers and `while` loops (the per-keystroke hot loop; spec §6 measures debug
    /// builds, where subscripts and range iteration are calls).
    static func fuzzyScore(
        _ pattern: UnsafePointer<UInt32>, _ m: Int, _ text: UnsafePointer<UInt32>, _ n: Int, _ s: Scratch
    ) -> Int? {
        guard m > 0 else { return 0 }
        guard n >= m else { return nil }
        // Forward: the first possible start, and whether it matches at all.
        var p = 0, low = 0, j = 0
        while j < n {
            if text[j] == pattern[p] {
                if p == 0 { low = j }
                p += 1
                if p == m { break }
            }
            j += 1
        }
        guard p == m else { return nil }
        // Backward: the last possible end.
        var q = m - 1, high = n - 1
        j = n - 1
        while j >= low {
            if text[j] == pattern[q] {
                if q == m - 1 { high = j }
                if q == 0 { break }
                q -= 1
            }
            j -= 1
        }

        // Locals: static constants are read through accessors in debug builds.
        let impossible = Self.impossible, match = matchScore, gapStart = Self.gapStart
        let gapExtension = Self.gapExtension, consecutiveBonus = Self.consecutiveBonus
        let boundary = boundaryBonus
        let width = high - low + 1
        let window = text + low
        let capacity = s.capacity
        let bonus = s.base
        var previous = s.base + capacity, current = s.base + 2 * capacity
        var previousRun = s.base + 3 * capacity, currentRun = s.base + 4 * capacity
        var k = 0
        while k < width {
            let position = low + k
            if position == 0 {
                bonus[k] = Self.startBonus
            } else {
                let before = text[position - 1]
                // ASCII inline; other scripts through the Unicode properties.
                let isWordCharacter = before < 0x80
                    ? (before >= 0x30 && before <= 0x39) || (before >= 0x61 && before <= 0x7A)
                        || (before >= 0x41 && before <= 0x5A)
                    : isAlphanumeric(before)
                bonus[k] = isWordCharacter ? 0 : boundary
            }
            k += 1
        }
        let first = pattern[0], firstMultiplier = firstCharacterMultiplier
        k = 0
        while k < width {
            if window[k] == first {
                previous[k] = match + bonus[k] * firstMultiplier
                previousRun[k] = bonus[k]
            } else {
                previous[k] = impossible
            }
            k += 1
        }
        var i = 1
        while i < m {
            let character = pattern[i]
            // Best score of a path into column k after a gap (a run broken before k).
            var gapped = impossible
            k = 0
            while k < width {
                if k >= 2 {
                    if gapped != impossible { gapped += gapExtension }
                    let opened = previous[k - 2]
                    if opened != impossible, opened + gapStart > gapped { gapped = opened + gapStart }
                }
                if window[k] != character {
                    current[k] = impossible
                } else {
                    var best = impossible, run = bonus[k]
                    if gapped != impossible { best = gapped + match + bonus[k] }
                    if k >= 1, previous[k - 1] != impossible {
                        var runBonus = previousRun[k - 1]
                        if bonus[k] > runBonus { runBonus = bonus[k] }
                        if consecutiveBonus > runBonus { runBonus = consecutiveBonus }
                        let consecutive = previous[k - 1] + match + runBonus
                        if consecutive >= best {
                            best = consecutive
                            run = runBonus
                        }
                    }
                    current[k] = best
                    currentRun[k] = run
                }
                k += 1
            }
            swap(&previous, &current)
            swap(&previousRun, &currentRun)
            i += 1
        }
        var best = impossible
        k = 0
        while k < width {
            if previous[k] > best { best = previous[k] }
            k += 1
        }
        return best == impossible ? nil : best
    }

    /// Letters and digits of any script.
    private static func isAlphanumeric(_ value: UInt32) -> Bool {
        guard let scalar = Unicode.Scalar(value) else { return false }
        return scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }
}
