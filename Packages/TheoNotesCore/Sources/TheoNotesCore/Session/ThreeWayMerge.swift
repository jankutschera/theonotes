// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

public enum MergeResult: Equatable, Sendable {
    case clean(String)
    case conflict
}

public enum ThreeWayMerge {
    /// Line-based diff3: changes from both sides merge when they touch disjoint regions of `base`
    /// (separated by at least one line both sides kept) or are identical; otherwise `.conflict`.
    public static func merge(base: String, local: String, remote: String) -> MergeResult {
        let same = TextNormalization.identical
        if same(local, remote) { return .clean(local) }
        if same(local, base) { return .clean(remote) }
        if same(remote, base) { return .clean(local) }

        // Lines split on the "\n" scalar ("\r\n" is one Character) and are identified by their
        // bytes (String/Substring equality is canonical equivalence).
        var ids: [[UInt8]: Int] = [:]
        func tokens(_ s: String) -> (lines: [String], ids: [Int]) {
            let lines = s.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
                .map { String(String.UnicodeScalarView($0)) }
            return (lines, lines.map { line in
                let key = Array(line.utf8)
                if let id = ids[key] { return id }
                let id = ids.count
                ids[key] = id
                return id
            })
        }
        let o = tokens(base), a = tokens(local), b = tokens(remote)
        let matchA = lineMatches(o.ids, a.ids)
        let matchB = lineMatches(o.ids, b.ids)

        var out: [String] = []
        var io = 0, ia = 0, ib = 0
        while true {
            // Stable run: base lines kept in place by both sides.
            var run = 0
            while io + run < o.ids.count, matchA[io + run] == ia + run, matchB[io + run] == ib + run {
                run += 1
            }
            if run > 0 {
                out += o.lines[io..<io + run]
                io += run; ia += run; ib += run
                continue
            }
            if io == o.ids.count && ia == a.ids.count && ib == b.ids.count { break }

            // Unstable chunk up to the next base line both sides kept (or the end).
            let anchor = (io..<o.ids.count).first { matchA[$0] != nil && matchB[$0] != nil }
            let endO = anchor ?? o.ids.count
            let endA = anchor.map { matchA[$0]! } ?? a.ids.count
            let endB = anchor.map { matchB[$0]! } ?? b.ids.count
            let chunkO = o.ids[io..<endO], chunkA = a.ids[ia..<endA], chunkB = b.ids[ib..<endB]
            if chunkA.elementsEqual(chunkO) {
                out += b.lines[ib..<endB]
            } else if chunkB.elementsEqual(chunkO) || chunkA.elementsEqual(chunkB) {
                out += a.lines[ia..<endA]
            } else {
                return .conflict
            }
            io = endO; ia = endA; ib = endB
        }
        return .clean(out.joined(separator: "\n"))
    }

    /// Single-replacement UTF-16 changeset turning `old` into `new` (common prefix/suffix trimmed,
    /// boundaries backed off so no surrogate pair is split).
    public static func changeSet(from old: String, to new: String) -> ChangeSet {
        let o = Array(old.utf16), n = Array(new.utf16)
        if o == n { return ChangeSet(sections: o.isEmpty ? [] : [.retain(o.count)]) }

        var prefix = 0
        while prefix < o.count, prefix < n.count, o[prefix] == n[prefix] { prefix += 1 }
        if prefix > 0, UTF16.isLeadSurrogate(o[prefix - 1]) { prefix -= 1 }

        var suffix = 0
        let maxSuffix = min(o.count, n.count) - prefix
        while suffix < maxSuffix, o[o.count - 1 - suffix] == n[n.count - 1 - suffix] { suffix += 1 }
        if suffix > 0, UTF16.isTrailSurrogate(o[o.count - suffix]) { suffix -= 1 }

        var sections: [ChangeSet.Section] = []
        if prefix > 0 { sections.append(.retain(prefix)) }
        let insert = String(decoding: n[prefix..<(n.count - suffix)], as: UTF16.self)
        sections.append(.replace(deleteLength: o.count - prefix - suffix, insert: insert))
        if suffix > 0 { sections.append(.retain(suffix)) }
        return ChangeSet(sections: sections)
    }

    /// For each element of `a`, the index of its partner in `b` under a longest common subsequence
    /// (Myers O(ND) diff after trimming the common prefix and suffix), or nil if it was removed.
    static let maxEditDistance = 2000

    static func lineMatches(_ a: [Int], _ b: [Int]) -> [Int?] {
        var result = [Int?](repeating: nil, count: a.count)
        var start = 0
        while start < a.count, start < b.count, a[start] == b[start] {
            result[start] = start
            start += 1
        }
        var endA = a.count, endB = b.count
        while endA > start, endB > start, a[endA - 1] == b[endB - 1] {
            endA -= 1; endB -= 1
            result[endA] = endB
        }
        let n = endA - start, m = endB - start
        guard n > 0, m > 0 else { return result }

        // Past `maxEditDistance` the middle is left unmatched: the merge then degrades to one
        // unstable chunk (clean only if one side left it untouched), which is conservative.
        let maxD = min(n + m, maxEditDistance)
        let offset = maxD + 1
        var v = [Int](repeating: 0, count: 2 * maxD + 3)
        var trace: [[Int]] = []  // trace[d] = v[-d...d] at the start of round d
        var found = false
        search: for d in 0...maxD {
            trace.append(Array(v[(offset - d)...(offset + d)]))
            for k in stride(from: -d, through: d, by: 2) {
                var x = (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]))
                    ? v[offset + k + 1] : v[offset + k - 1] + 1
                var y = x - k
                while x < n, y < m, a[start + x] == b[start + y] { x += 1; y += 1 }
                v[offset + k] = x
                if x >= n, y >= m { found = true; break search }
            }
        }
        guard found else { return result }

        var x = n, y = m
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let snapshot = trace[d]
            func at(_ k: Int) -> Int { snapshot[k + d] }
            let k = x - y
            let prevK = (k == -d || (k != d && at(k - 1) < at(k + 1))) ? k + 1 : k - 1
            let prevX = d == 0 ? 0 : at(prevK)
            let prevY = d == 0 ? 0 : prevX - prevK
            while x > prevX, y > prevY {
                x -= 1; y -= 1
                result[start + x] = start + y
            }
            x = prevX; y = prevY
        }
        return result
    }
}
