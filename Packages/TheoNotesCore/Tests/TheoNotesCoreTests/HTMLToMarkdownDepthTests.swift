// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Darwin
import Foundation
import Testing
@testable import TheoNotesCore

/// Hostile nesting must never overflow the stack (task H). Every conversion runs
/// on a thread with the 512 KiB stack that secondary threads and background import tasks get, in
/// the Debug build the tests use (the worst case for frame sizes).
@Suite struct HTMLToMarkdownDepthTests {
    struct Kind: CustomTestStringConvertible, Sendable {
        var name: String
        var open: String
        var close: String
        /// `li` and `p` close an open one of their kind, so they do not nest.
        var nests = true
        var testDescription: String { name }
    }

    static let kinds: [Kind] = [
        Kind(name: "a", open: #"<a href="https://example.com/x">"#, close: "</a>"),
        Kind(name: "span", open: "<span>", close: "</span>"),
        Kind(name: "b", open: "<b>", close: "</b>"),
        Kind(name: "i", open: "<i>", close: "</i>"),
        Kind(name: "em", open: "<em>", close: "</em>"),
        Kind(name: "strong", open: "<strong>", close: "</strong>"),
        Kind(name: "u", open: "<u>", close: "</u>"),
        Kind(name: "s", open: "<s>", close: "</s>"),
        Kind(name: "mark", open: "<mark>", close: "</mark>"),
        Kind(name: "div", open: "<div>", close: "</div>"),
        Kind(name: "p", open: "<p>", close: "</p>", nests: false),
        Kind(name: "h2", open: "<h2>", close: "</h2>"),
        Kind(name: "blockquote", open: "<blockquote>", close: "</blockquote>"),
        Kind(name: "ul/li", open: "<ul><li>", close: "</li></ul>"),
        Kind(name: "ol/li", open: "<ol><li>", close: "</li></ol>"),
        Kind(name: "li", open: "<li>", close: "</li>", nests: false),
        Kind(name: "checklist", open: #"<ul class="checklist"><li><span>"#, close: "</span></li></ul>"),
        Kind(name: "table/tr/td", open: "<table><tr><td>", close: "</td></tr></table>"),
        Kind(name: "pre", open: "<pre>", close: "</pre>"),
        Kind(name: "code", open: "<code>", close: "</code>"),
        Kind(name: "font", open: #"<font color="red">"#, close: "</font>"),
        Kind(name: "font face", open: #"<font face="Menlo">"#, close: "</font>"),
        Kind(name: "mixed", open: #"<a href="https://example.com/x"><div><ul><li><blockquote>"#,
             close: "</blockquote></li></ul></div></a>"),
    ]

    static let stackSize = 512 * 1024
    static var depth: Int { HTMLToMarkdown.maxNesting * 10 }
    static var warning: String { "nesting deeper than \(HTMLToMarkdown.maxNesting) levels was flattened" }

    final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    /// Runs `body` on a new thread with `stackSize` bytes of stack and waits for it.
    static func onThread<T: Sendable>(stackSize: Int = stackSize, _ body: @escaping @Sendable () -> T) -> T {
        let box = Box<T?>(nil)
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.value = body()
            done.signal()
        }
        thread.stackSize = stackSize
        thread.start()
        done.wait()
        return box.value!
    }

    static func convert(_ html: String, generic: Bool) -> HTMLToMarkdown.Result {
        onThread {
            generic
                ? HTMLToMarkdown.convert(html, makesTitle: false, keepsRelativeImages: true)
                : HTMLToMarkdown.convert(html)
        }
    }

    @Test(arguments: kinds, [false, true])
    func deepClosedNestingConvertsOnASmallStack(_ kind: Kind, generic: Bool) {
        let html = String(repeating: kind.open, count: Self.depth) + "deep text"
            + String(repeating: kind.close, count: Self.depth) + "<div>after</div>"
        let r = Self.convert(html, generic: generic)
        #expect(r.markdown.contains("deep text"))
        #expect(r.markdown.contains("after"))
        if kind.nests { #expect(r.warnings.contains(Self.warning)) }
    }

    @Test(arguments: kinds, [false, true])
    func deepUnclosedNestingConvertsOnASmallStack(_ kind: Kind, generic: Bool) {
        let html = String(repeating: kind.open + "q ", count: Self.depth) + "deep text"
        let r = Self.convert(html, generic: generic)
        #expect(r.markdown.contains("deep text"))
        // Flattened content is kept as text: every level's own text survives.
        #expect(r.markdown.filter { $0 == "q" }.count == Self.depth)
        if kind.nests { #expect(r.warnings.contains(Self.warning)) }
    }

    /// Alternating kinds, one level each, unclosed.
    @Test(arguments: [false, true])
    func deepMixedNestingConvertsOnASmallStack(generic: Bool) {
        let cycle = [#"<a href="https://example.com/x">"#, "<div>", "<ul><li>", "<blockquote>"]
        let html = (0..<Self.depth).map { cycle[$0 % cycle.count] + "q " }.joined() + "deep text"
        let r = Self.convert(html, generic: generic)
        #expect(r.markdown.contains("deep text"))
        #expect(r.markdown.filter { $0 == "q" }.count == Self.depth)
        #expect(r.warnings.contains(Self.warning))
    }

    /// Content flattened into a table outside its cells moves to the nearest element that renders
    /// it, after the table and in source order. `prefix` opens the table structure whose
    /// last element sits exactly at the nesting limit.
    @Test(arguments: [
        (prefix: "<table>", open: 1, suffix: "</table>", table: ""),
        (prefix: "<table><tr>", open: 2, suffix: "</tr></table>", table: ""),
        (prefix: "<table><tr><td>cell</td></tr><tbody><div>", open: 3, suffix: "</div></tbody></table>",
         table: "| cell |\n| --- |\n\n"),
    ])
    func contentFlattenedInATableIsKeptInOrder(prefix: String, open: Int, suffix: String, table: String) {
        // `open`: elements of `prefix` still open at its end (table; table, tr; table, tbody, div).
        let divs = HTMLToMarkdown.maxNesting - open
        // At the limit `span` and `td` can only be empty leaves; their text is flattened.
        let html = String(repeating: "<div>", count: divs) + prefix + "first <span>second</span> <td>third</td>" + suffix
            + " after" + String(repeating: "</div>", count: divs)
        let r = Self.convert(html, generic: true)
        #expect(r.markdown == table + "first second third after")
        #expect(r.warnings == [Self.warning])
    }

    /// `<ol start>` is clamped to what a Markdown list marker can hold (at most nine digits,
    /// never negative) and the count never overflows.
    @Test(arguments: [
        (start: "9223372036854775807", markers: ["999999999", "999999999"]),
        (start: "-9223372036854775808", markers: ["1", "2"]),
        (start: "99999999999999999999999999", markers: ["1", "2"]),
        (start: "abc", markers: ["1", "2"]),
        (start: "-5", markers: ["1", "2"]),
        (start: "0", markers: ["0", "1"]),
        (start: "999999998", markers: ["999999998", "999999999"]),
        (start: "999999999", markers: ["999999999", "999999999"]),
        (start: "1000000000", markers: ["999999999", "999999999"]),
    ])
    func orderedListStartIsClamped(start: String, markers: [String]) {
        let html = "<ol start=\"\(start)\"><li>a</li><li>b</li></ol>"
        for generic in [false, true] {
            let r = Self.convert(html, generic: generic)
            let lines = r.markdown.components(separatedBy: "\n").suffix(2)
            #expect(Array(lines) == ["\(markers[0]). a", "\(markers[1]). b"], "\(start)")
        }
    }

    /// Stack use does not grow with nesting: at the bound every kind stays far below a 512 KiB
    /// stack (measured under 28 KiB in Debug,; before the walkers became iterative the
    /// `a` kind needed 733 KB here).
    @Test(arguments: kinds)
    func stackUseAtTheBoundLeavesMargin(_ kind: Kind) {
        let html = String(repeating: kind.open + "q ", count: HTMLToMarkdown.maxNesting + 1) + "deep text"
        let used = Self.peakStackUse {
            _ = HTMLToMarkdown.convert(html)
            _ = HTMLToMarkdown.convert(html, makesTitle: false, keepsRelativeImages: true)
        }
        #expect(used < 64 * 1024, "\(kind.name): \(used) bytes")
    }

    /// 1 MB of nested unclosed tags of every kind converts in bounded time.
    @Test(.tags(.perf)) func testPerfMegabyteOfNestedUnclosedTags() {
        let cycle = Self.kinds.map(\.open).joined(separator: "q ")
        var html = ""
        while html.utf8.count < 1_000_000 { html += cycle + "q " }
        let source = html
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            let r = Self.onThread { HTMLToMarkdown.convert(source, makesTitle: false, keepsRelativeImages: true) }
            #expect(r.warnings.contains(Self.warning))
            #expect(!r.markdown.isEmpty)
        }
        #expect(elapsed < PerfGate.bound(.seconds(5), sanity: .seconds(30)), "\(elapsed)")
    }

    /// Peak stack bytes `body` uses on a fresh 8 MiB thread, found by painting the unused stack
    /// with a pattern before the call and looking for the deepest overwritten byte after it.
    static func peakStackUse(_ body: @escaping @Sendable () -> Void) -> Int {
        onThread(stackSize: 8 << 20) {
            let pattern: UInt8 = 0xA5
            let margin = 16 * 1024
            let thread = pthread_self()
            let top = UInt(bitPattern: pthread_get_stackaddr_np(thread))
            let bottom = top - UInt(pthread_get_stacksize_np(thread))
            var probe = 0
            let here = withUnsafeMutablePointer(to: &probe) { UInt(bitPattern: $0) }
            let start = bottom + UInt(margin), end = here - UInt(margin)
            memset(UnsafeMutableRawPointer(bitPattern: start)!, Int32(pattern), Int(end - start))
            body()
            let bytes = UnsafePointer<UInt8>(bitPattern: start)!
            var deepest = Int(end - start)
            for offset in 0..<Int(end - start) where bytes[offset] != pattern {
                deepest = offset
                break
            }
            return Int(here - (start + UInt(deepest)))
        }
    }
}
