// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation

/// Converts the HTML body Apple Notes' scripting interface returns into Bear-dialect Markdown.
/// Pure and tolerant: a small tokenizer builds an element tree (unclosed tags, stray end tags and
/// void elements are fine), a renderer walks it.
///
/// Notes writes one `<div>` per line (`<div><br></div>` is an empty line), `h1`–`h3`, `b`/`i`/`u`/
/// `strike`, `tt` for monostyled text, `a`, `ul`/`ol` (nested lists as siblings of `li`,
/// `ul class="Apple-dash-list"` for dashed lists), checklists (`ul class="checklist"`,
/// `li class="checked"`), tables and images as `data:` URLs.
///
/// Mapping: headings → `#`, bold → `**`, italic → `*`, underline → `~`, strike → `~~`, `tt` →
/// code spans, or a fenced code block when whole lines are monostyled, lists → `-` / `1.` with tab
/// indentation, checklists → `- [ ]` / `- [x]`, tables → GFM, images → attachments (`image.png`,
/// `image 2.png`, …). The first line becomes the title (`# `) unless it already is a heading.
///
/// Generic HTML pages (a saved web page, an export) use the same walker with `makesTitle: false`
/// and/or `keepsRelativeImages: true` (M8-R55): `p` is followed by an empty line, `pre` is a
/// fenced block whose `language-x` class becomes the info string, `mark` → `==`, and
/// `<img src="rel/p.png">` stays a Markdown image for `AttachmentLinkRewriter` to resolve.
public enum HTMLToMarkdown {
    public struct Result: Equatable, Sendable {
        public var markdown: String
        /// Images from `data:` URLs, named as linked in `markdown`.
        public var images: [ImportedAttachment]
        /// Things that could not be carried over (counts and kinds, never note text).
        public var warnings: [String]
        /// `data:` images left out because of `ImageLimits` (they were never decoded).
        public var oversizedImages = 0
    }

    /// The link target when it is a web or mail address (`http://`, `https://`, `mailto:`, case
    /// and surrounding blanks ignored, something after the scheme), else `nil`. Shared by the HTML
    /// and the RTF readers.
    static func allowedLinkTarget(_ target: String) -> String? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        for prefix in ["http://", "https://", "mailto:"] where lower.hasPrefix(prefix) && lower.count > prefix.count {
            return trimmed
        }
        return nil
    }

    /// Elements nested deeper than this are flattened into their ancestor at this depth. The
    /// walkers do not recurse (IMP-R41), so this no longer guards the stack; it bounds the work
    /// per level (link labels, strike checks, nested table cells) a hostile page can cause.
    public static let maxNesting = 128

    /// Caps on embedded `data:` images, checked against the encoded length before any decoding.
    public struct ImageLimits: Equatable, Sendable {
        public var each: Int
        public var total: Int

        public init(each: Int, total: Int) {
            self.each = each
            self.total = total
        }
    }

    /// `baseURL` resolves relative `<img src>` (text only, nothing is fetched); a result that is not
    /// http(s) is dropped like any unsupported source. `makesTitle: false` keeps the first line as
    /// it is. `keepsRelativeImages` keeps an `<img>` whose source has no scheme as
    /// `![alt](rel/p.png)` (it wins over `baseURL`); the caller resolves the file. The defaults
    /// are Apple Notes' behaviour; any other value selects the generic-HTML rules.
    public static func convert(
        _ html: String, imageLimits: ImageLimits? = nil, baseURL: URL? = nil,
        makesTitle: Bool = true, keepsRelativeImages: Bool = false
    ) -> Result {
        var flattened = false
        let root = TreeBuilder.build(html, flattened: &flattened)
        let renderer = Renderer()
        renderer.imageLimits = imageLimits
        renderer.baseURL = baseURL
        renderer.keepsRelativeImages = keepsRelativeImages
        renderer.isGeneric = !makesTitle || keepsRelativeImages
        if keepsRelativeImages { renderer.reserveLinkedNames(in: root.children) }
        var lines = renderer.blocks(root.children, fences: true)
        if makesTitle { makeTitle(&lines) }
        let markdown = assemble(lines)
        var warnings = renderer.warningLines
        if markdown.isEmpty, !Renderer.rawText(root.children, preserveWhitespace: false)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            warnings.append("body has text that could not be converted")
        }
        if flattened { warnings.append("nesting deeper than \(maxNesting) levels was flattened") }
        return Result(
            markdown: markdown, images: renderer.images, warnings: warnings, oversizedImages: renderer.oversizedImages)
    }

    // MARK: - Lines

    enum Kind: Equatable { case text, heading, list, quote, table, code, rule, empty }

    struct Line: Equatable {
        var text: String
        var kind: Kind
        /// Generic HTML: the first line of a `pre` block starts a new fence with `info`.
        var opensFence = false
        var info = ""
    }

    /// The first non-empty line becomes `# …` when it is plain prose (a fully bold line loses
    /// its `**`): Notes shows the first line as the title, Bear takes the first line too.
    static func makeTitle(_ lines: inout [Line]) {
        guard let index = lines.firstIndex(where: { $0.kind != .empty }), lines[index].kind == .text else { return }
        var text = lines[index].text
        guard !text.hasPrefix("![") else { return }
        if text.hasPrefix("**"), text.hasSuffix("**"), text.count > 4 {
            let inner = String(text.dropFirst(2).dropLast(2))
            if !inner.contains("**") { text = inner }
        }
        lines[index] = Line(text: "# " + text, kind: .heading)
    }

    /// Joins lines; groups code lines into fences (empty lines between two code lines stay inside)
    /// and puts blank lines around tables. Leading and trailing empty lines are dropped.
    static func assemble(_ input: [Line]) -> String {
        var lines = input
        while lines.first?.kind == .empty { lines.removeFirst() }
        while lines.last?.kind == .empty { lines.removeLast() }
        // Empty lines sandwiched between code lines belong to the code block.
        var i = 0
        while i < lines.count {
            if lines[i].kind == .empty, i > 0, lines[i - 1].kind == .code {
                var j = i
                while j < lines.count, lines[j].kind == .empty { j += 1 }
                if j < lines.count, lines[j].kind == .code, !lines[j].opensFence {
                    for k in i..<j { lines[k] = Line(text: "", kind: .code) }
                }
                i = j
            } else {
                i += 1
            }
        }
        var out: [String] = []
        func blankBefore() { if let last = out.last, !last.isEmpty { out.append("") } }
        i = 0
        while i < lines.count {
            let line = lines[i]
            switch line.kind {
            case .code:
                var block: [String] = []
                let info = line.info
                repeat {
                    block.append(lines[i].text)
                    i += 1
                } while i < lines.count && lines[i].kind == .code && !lines[i].opensFence
                let fence = String(repeating: "`", count: max(3, longestRun(of: "`", in: block.joined(separator: "\n")) + 1))
                out.append(fence + info)
                out.append(contentsOf: block)
                out.append(fence)
                continue
            case .table:
                blankBefore()
                while i < lines.count, lines[i].kind == .table {
                    out.append(lines[i].text)
                    i += 1
                }
                if i < lines.count, lines[i].kind != .empty { out.append("") }
                continue
            default:
                out.append(line.text)
            }
            i += 1
        }
        return out.joined(separator: "\n")
    }

    static func longestRun(of character: Character, in text: String) -> Int {
        var best = 0, current = 0
        for c in text {
            if c == character { current += 1; best = max(best, current) } else { current = 0 }
        }
        return best
    }
}

// MARK: - Tree

final class HTMLElement {
    let name: String
    let attributes: [String: String]
    var children: [HTMLNode] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    /// Releases the subtree from a worklist: letting each element release its children would
    /// use stack per nesting level (IMP-R41).
    deinit {
        var pending: [HTMLElement] = []
        for case .element(let child) in children { pending.append(child) }
        children = []
        while var element = pending.popLast() {
            guard isKnownUniquelyReferenced(&element) else { continue }
            for case .element(let child) in element.children { pending.append(child) }
            element.children = []
        }
    }

    var classes: Set<String> {
        Set((attributes["class"] ?? "").split(whereSeparator: { $0 == " " || $0 == "\t" }).map { $0.lowercased() })
    }

    /// `style` declarations, lowercased names and values.
    var style: [String: String] {
        var result: [String: String] = [:]
        for declaration in (attributes["style"] ?? "").split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            result[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] =
                parts[1].trimmingCharacters(in: .whitespaces).lowercased()
        }
        return result
    }
}

enum HTMLNode {
    case text(String)
    case element(HTMLElement)
}

enum TreeBuilder {
    static let voidElements: Set<String> = [
        "br", "img", "hr", "input", "meta", "link", "wbr", "col", "area", "base", "source", "embed", "param",
    ]
    static let rawTextElements: Set<String> = ["script", "style", "head", "title", "template"]

    /// `flattened` is set when an element was nested deeper than `HTMLToMarkdown.maxNesting`: it
    /// is kept as an empty leaf and its content goes to the element at the limit, or, where a
    /// table would drop it (anything in a table outside its cells), to the nearest open element
    /// that keeps it.
    static func build(_ html: String, flattened: inout Bool) -> HTMLElement {
        let root = HTMLElement(name: "#root", attributes: [:])
        var stack: [HTMLElement] = [root]
        let b = Array(html.utf8)
        let n = b.count
        var i = 0
        var textStart = 0
        var limitContainer: (top: HTMLElement, container: HTMLElement)?

        /// The open element new content goes into.
        func container() -> HTMLElement {
            let top = stack.last!
            guard stack.count > HTMLToMarkdown.maxNesting else { return top }
            if let limitContainer, limitContainer.top === top { return limitContainer.container }
            // The table walk renders only the cells of a table's rows (`Renderer.TableTask`).
            enum Walk { case flow, table, row, dropped }
            var walk = Walk.flow
            var keeper = root
            for element in stack.dropFirst() {
                switch walk {
                case .flow: walk = element.name == "table" ? .table : .flow
                case .table: walk = element.name == "tr" ? .row : element.name == "table" ? .dropped : .table
                case .row: walk = element.name == "td" || element.name == "th" ? .flow : .dropped
                case .dropped: break
                }
                if walk == .flow { keeper = element }
            }
            limitContainer = (top, keeper)
            return keeper
        }
        func flushText(_ end: Int) {
            guard end > textStart else { return }
            let text = Entities.decode(String(decoding: b[textStart..<end], as: UTF8.self))
            container().children.append(.text(text))
        }
        func hasPrefix(_ s: String, at p: Int) -> Bool {
            let u = Array(s.utf8)
            guard p + u.count <= n else { return false }
            for k in 0..<u.count where lower(b[p + k]) != u[k] { return false }
            return true
        }
        func find(_ s: String, from p: Int) -> Int? {
            var q = p
            while q < n {
                if hasPrefix(s, at: q) { return q }
                q += 1
            }
            return nil
        }
        func close(_ name: String) {
            guard let index = stack.lastIndex(where: { $0.name == name }), index > 0 else { return }
            stack.removeSubrange(index...)
        }
        /// Pops an open `name` that sits above the nearest element in `boundary`.
        func closeImplicit(_ names: Set<String>, boundary: Set<String>) {
            for index in stack.indices.reversed() where index > 0 {
                if boundary.contains(stack[index].name) { return }
                if names.contains(stack[index].name) {
                    stack.removeSubrange(index...)
                    return
                }
            }
        }

        while i < n {
            guard b[i] == UInt8(ascii: "<") else { i += 1; continue }
            if hasPrefix("<!--", at: i) {
                flushText(i)
                i = (find("-->", from: i + 4).map { $0 + 3 }) ?? n
                textStart = i
                continue
            }
            if i + 1 < n, b[i + 1] == UInt8(ascii: "!") || b[i + 1] == UInt8(ascii: "?") {
                flushText(i)
                i = (find(">", from: i + 2).map { $0 + 1 }) ?? n
                textStart = i
                continue
            }
            if i + 1 < n, b[i + 1] == UInt8(ascii: "/") {
                var p = i + 2
                let nameStart = p
                while p < n, isNameByte(b[p]) { p += 1 }
                guard p > nameStart else { i += 1; continue }
                flushText(i)
                let name = String(decoding: b[nameStart..<p].map(lower), as: UTF8.self)
                i = (find(">", from: p).map { $0 + 1 }) ?? n
                textStart = i
                close(name)
                continue
            }
            guard i + 1 < n, isLetter(b[i + 1]) else { i += 1; continue }
            flushText(i)
            var p = i + 1
            let nameStart = p
            while p < n, isNameByte(b[p]) { p += 1 }
            let name = String(decoding: b[nameStart..<p].map(lower), as: UTF8.self)
            var attributes: [String: String] = [:]
            var selfClosing = false
            while p < n {
                while p < n, isSpace(b[p]) { p += 1 }
                guard p < n else { break }
                if b[p] == UInt8(ascii: ">") { p += 1; break }
                if b[p] == UInt8(ascii: "/") { selfClosing = true; p += 1; continue }
                let attrStart = p
                while p < n, !isSpace(b[p]), b[p] != UInt8(ascii: "="), b[p] != UInt8(ascii: ">"),
                      b[p] != UInt8(ascii: "/") || p == attrStart { p += 1 }
                let attrName = String(decoding: b[attrStart..<p].map(lower), as: UTF8.self)
                while p < n, isSpace(b[p]) { p += 1 }
                var value = ""
                if p < n, b[p] == UInt8(ascii: "=") {
                    p += 1
                    while p < n, isSpace(b[p]) { p += 1 }
                    if p < n, b[p] == UInt8(ascii: "\"") || b[p] == UInt8(ascii: "'") {
                        let quote = b[p]
                        let valueStart = p + 1
                        p = valueStart
                        while p < n, b[p] != quote { p += 1 }
                        value = String(decoding: b[valueStart..<min(p, n)], as: UTF8.self)
                        if p < n { p += 1 }
                    } else {
                        let valueStart = p
                        while p < n, !isSpace(b[p]), b[p] != UInt8(ascii: ">") { p += 1 }
                        value = String(decoding: b[valueStart..<p], as: UTF8.self)
                    }
                }
                if !attrName.isEmpty, attributes[attrName] == nil { attributes[attrName] = Entities.decode(value) }
            }
            i = p
            textStart = i

            if rawTextElements.contains(name) {
                // The close tag is `</name` followed by whitespace, `/` or `>`; `</scriptx>` is not one.
                var end = n
                var from = i
                while let q = find("</\(name)", from: from) {
                    let after = q + 2 + name.utf8.count
                    if after >= n || isSpace(b[after]) || b[after] == UInt8(ascii: "/") || b[after] == UInt8(ascii: ">") {
                        end = find(">", from: q).map { $0 + 1 } ?? n
                        break
                    }
                    from = q + 1
                }
                i = end
                textStart = i
                continue
            }
            switch name {
            case "li": closeImplicit(["li"], boundary: ["ul", "ol"])
            case "tr": closeImplicit(["tr"], boundary: ["table"])
            case "td", "th": closeImplicit(["td", "th"], boundary: ["tr", "table"])
            case "p": closeImplicit(["p"], boundary: ["div", "li", "td", "th", "blockquote"])
            default: break
            }
            let element = HTMLElement(name: name, attributes: attributes)
            container().children.append(.element(element))
            if !selfClosing, !voidElements.contains(name) {
                if stack.count <= HTMLToMarkdown.maxNesting { stack.append(element) } else { flattened = true }
            }
        }
        flushText(n)
        return root
    }

    private static func lower(_ c: UInt8) -> UInt8 {
        c >= 65 && c <= 90 ? c + 32 : c
    }

    private static func isLetter(_ c: UInt8) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
    }

    private static func isNameByte(_ c: UInt8) -> Bool {
        isLetter(c) || (c >= 48 && c <= 57) || c == UInt8(ascii: "-") || c == UInt8(ascii: ":")
    }

    static func isSpace(_ c: UInt8) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0C
    }
}

enum Entities {
    static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’", "sbquo": "‚",
        "ldquo": "“", "rdquo": "”", "bdquo": "„", "laquo": "«", "raquo": "»", "bull": "•",
        "middot": "·", "copy": "©", "reg": "®", "trade": "™", "euro": "€", "pound": "£", "yen": "¥",
        "cent": "¢", "deg": "°", "times": "×", "divide": "÷", "plusmn": "±", "sect": "§", "para": "¶",
        "shy": "", "zwj": "\u{200D}", "zwnj": "\u{200C}", "thinsp": "\u{2009}", "ensp": "\u{2002}",
        "emsp": "\u{2003}", "auml": "ä", "ouml": "ö", "uuml": "ü", "Auml": "Ä", "Ouml": "Ö",
        "Uuml": "Ü", "szlig": "ß", "eacute": "é", "egrave": "è", "agrave": "à", "ccedil": "ç",
        "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓", "hearts": "♥", "check": "✓",
    ]

    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        out.reserveCapacity(text.utf8.count)
        var index = text.startIndex
        while index < text.endIndex {
            let c = text[index]
            guard c == "&", let semi = text[index...].prefix(12).firstIndex(of: ";") else {
                out.append(c)
                index = text.index(after: index)
                continue
            }
            let body = text[text.index(after: index)..<semi]
            var replacement: String?
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                replacement = UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if body.hasPrefix("#") {
                replacement = UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                replacement = named[String(body)]
            }
            if let replacement {
                out += replacement
                index = text.index(after: semi)
            } else {
                out.append(c)
                index = text.index(after: index)
            }
        }
        return out
    }
}

// MARK: - Rendering

/// One call of a tree walker, run by `Renderer.drive` (see there).
protocol RenderTask<Value>: AnyObject {
    associatedtype Value
    /// First called with `nil`, then with the result of each nested call the task asked for.
    func resume(with value: Value?) -> RenderStep<Value>
}

enum RenderStep<Value> {
    case call(any RenderTask<Value>)
    case done(Value)
}

final class Renderer {
    static let blockElements: Set<String> = [
        "div", "p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "table", "blockquote", "hr", "pre",
        "object", "section", "article", "header", "footer", "body", "html", "main", "nav", "aside", "dl", "dt",
        "dd", "figure", "figcaption", "center", "address",
    ]

    private(set) var images: [ImportedAttachment] = []
    private var nameByDigest: [String: String] = [:]
    private var usedKeys: Set<String> = []
    private var unsupportedImages = 0
    private var undecodableImages = 0
    var imageLimits: HTMLToMarkdown.ImageLimits?
    /// The page the HTML came from: relative image sources are resolved against it.
    var baseURL: URL?
    private(set) var oversizedImages = 0
    private var decodedBytes = 0
    /// Generic HTML rules (see `HTMLToMarkdown`).
    var isGeneric = false
    var keepsRelativeImages = false

    /// Keeps `data:` image names (`image.png`, …) from colliding with the file names of the
    /// relative images and links, which the attachment rewriter copies under their own names.
    func reserveLinkedNames(in nodes: [HTMLNode]) {
        var pending = [nodes]
        while let siblings = pending.popLast() {
            for case .element(let element) in siblings {
                let value = element.name == "img" ? element.attributes["src"] : nil
                if let value, let name = Self.relativeFileName(value) { usedKeys.insert(AttachmentFiles.fileSystemKey(name)) }
                pending.append(element.children)
            }
        }
    }

    /// Last path component of a scheme-less, non-fragment URL reference.
    private static func relativeFileName(_ reference: String) -> String? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard LinkDestination.isRelative(trimmed), !trimmed.hasPrefix("//") else { return nil }
        let path = String(trimmed.prefix { $0 != "#" && $0 != "?" })
        let name = (path.removingPercentEncoding ?? path).split(separator: "/").last.map(String.init)
        return name?.isEmpty == false ? name : nil
    }

    var warningLines: [String] {
        var lines: [String] = []
        if undecodableImages > 0 { lines.append("\(undecodableImages) embedded image(s) could not be decoded") }
        if unsupportedImages > 0 { lines.append("\(unsupportedImages) image(s) without embedded data skipped") }
        return lines
    }

    // MARK: Walkers

    /// The tree walkers keep their state in task objects on an explicit stack instead of
    /// recursing, so nesting depth costs heap memory, not thread stack (IMP-R41): a 512 KiB
    /// background thread converts any page. Each task stands for one call of the walker it is
    /// named after and does the same work in the same order: it runs until it needs the result of
    /// a nested call (`.call`) and is resumed with that result, or it finishes (`.done`).
    static func drive<Value>(_ first: any RenderTask<Value>) -> Value {
        var stack = [first]
        var value: Value?
        while true {
            let task = stack[stack.count - 1]
            switch task.resume(with: value) {
            case .call(let child):
                stack.append(child)
                value = nil
            case .done(let result):
                stack.removeLast()
                if stack.isEmpty { return result }
                value = result
            }
        }
    }

    typealias Lines = [HTMLToMarkdown.Line]

    // MARK: Blocks

    /// Lines for a sequence of sibling nodes. `fences`: monostyled lines may become code blocks
    /// (top level only; inside lists, quotes and tables they stay code spans).
    func blocks(_ nodes: [HTMLNode], fences: Bool) -> Lines {
        Self.drive(BlocksTask(self, nodes, fences: fences))
    }

    /// `blocks`: block elements are nested calls; the inline runs between them render here.
    private final class BlocksTask: RenderTask {
        let renderer: Renderer
        let nodes: [HTMLNode]
        let fences: Bool
        var index = 0
        var run: [HTMLNode] = []
        var lines: Lines = []

        init(_ renderer: Renderer, _ nodes: [HTMLNode], fences: Bool) {
            self.renderer = renderer
            self.nodes = nodes
            self.fences = fences
        }

        func resume(with value: Lines?) -> RenderStep<Lines> {
            if let value { lines += value }
            while index < nodes.count {
                let node = nodes[index]
                index += 1
                if case .element(let element) = node, Renderer.blockElements.contains(element.name) {
                    flush()
                    return .call(BlockTask(renderer, element, fences: fences))
                }
                run.append(node)
            }
            flush()
            return .done(lines)
        }

        private func flush() {
            defer { run = [] }
            guard Renderer.hasContent(run) else { return }
            lines += renderer.inlineLines(run, fences: fences)
        }
    }

    /// One block element.
    private final class BlockTask: RenderTask {
        let renderer: Renderer
        let element: HTMLElement
        let fences: Bool

        init(_ renderer: Renderer, _ element: HTMLElement, fences: Bool) {
            self.renderer = renderer
            self.element = element
            self.fences = fences
        }

        func resume(with value: Lines?) -> RenderStep<Lines> {
            guard let value else { return start() }
            switch element.name {
            case "blockquote":
                var inner = value
                if renderer.isGeneric { while inner.last?.kind == .empty { inner.removeLast() } }
                return .done(inner.map { line in
                    .init(text: line.kind == .empty ? ">" : "> " + line.text, kind: .quote)
                })
            case "p" where renderer.isGeneric:
                var lines = value
                if let last = lines.last, last.kind != .empty { lines.append(.init(text: "", kind: .empty)) }
                return .done(lines)
            default:
                return .done(value)
            }
        }

        private func start() -> RenderStep<Lines> {
            switch element.name {
            case "h1", "h2", "h3", "h4", "h5", "h6":
                let level = Int(String(element.name.dropFirst())) ?? 1
                var context = InlineContext()
                context.bold = true
                let text = Renderer.cleanLine(
                    renderer.inline(element.children, context).split(separator: "\n").joined(separator: " "))
                guard !text.isEmpty else { return .done([.init(text: "", kind: .empty)]) }
                return .done([.init(text: String(repeating: "#", count: level) + " " + text, kind: .heading)])
            case "ul", "ol":
                return .call(ListTask(renderer, element, depth: 0))
            case "li":
                return .call(renderer.listItem(element, depth: 0, marker: "- "))
            case "table":
                return .call(TableTask(renderer, element))
            case "blockquote":
                return .call(BlocksTask(renderer, element.children, fences: false))
            case "hr":
                return .done([.init(text: "---", kind: .rule)])
            case "pre":
                let raw = Renderer.rawText(element.children, preserveWhitespace: true)
                var lines = raw.components(separatedBy: "\n")
                if lines.last == "" { lines.removeLast() }
                var result = lines.map { HTMLToMarkdown.Line(text: $0, kind: fences ? .code : .text) }
                if renderer.isGeneric, fences, !result.isEmpty {
                    result[0].opensFence = true
                    result[0].info = Renderer.language(of: element)
                }
                return .done(result)
            default:
                // Generic `p` and any other container: the lines of its content.
                return .call(BlocksTask(renderer, element.children, fences: fences))
            }
        }
    }

    /// One inline run (between block elements) → its lines. A trailing `<br>` only ends the line.
    private func inlineLines(_ nodes: [HTMLNode], fences: Bool) -> Lines {
        if fences, Self.isMonostyled(nodes) {
            var raw = Self.rawText(nodes, preserveWhitespace: false)
            if raw.hasSuffix("\n") { raw.removeLast() }
            return raw.components(separatedBy: "\n").map {
                .init(text: $0.replacingOccurrences(of: "\u{00A0}", with: " "), kind: .code)
            }
        }
        var text = inline(nodes, InlineContext())
        if text.hasSuffix("\n") { text.removeLast() }
        return text.components(separatedBy: "\n").map { raw in
            let line = Self.escapeLineStart(Self.cleanLine(raw))
            return .init(text: line, kind: line.isEmpty ? .empty : .text)
        }
    }

    // MARK: Lists

    /// `ul`/`ol`: one item per child; a nested list is indented one level deeper.
    private final class ListTask: RenderTask {
        let renderer: Renderer
        let children: [HTMLNode]
        let depth: Int
        let checklist: Bool
        let ordered: Bool
        var number: Int
        var index = 0
        var lines: Lines = []

        init(_ renderer: Renderer, _ element: HTMLElement, depth: Int) {
            self.renderer = renderer
            children = element.children
            self.depth = depth
            let classes = element.classes
            checklist = classes.contains("checklist") || classes.contains("apple-checklist")
            ordered = element.name == "ol"
            number = Self.start(element.attributes["start"])
        }

        /// The largest number a Markdown list marker holds (nine digits).
        static let maxNumber = 999_999_999

        /// `start` as a list number: unparsable or negative → 1, larger than a marker holds →
        /// `maxNumber` (IMP-R41).
        static func start(_ value: String?) -> Int {
            guard let parsed = Int(value ?? ""), parsed >= 0 else { return 1 }
            return min(parsed, maxNumber)
        }

        func resume(with value: Lines?) -> RenderStep<Lines> {
            if let value { lines += value }
            while index < children.count {
                let child = children[index]
                index += 1
                switch child {
                case .text(let text):
                    if !text.allSatisfy(\.isWhitespace) {
                        return .call(ItemTask(renderer, own: [child], nested: [], depth: depth, marker: "- "))
                    }
                case .element(let item):
                    if item.name == "ul" || item.name == "ol" {
                        return .call(ListTask(renderer, item, depth: depth + 1))
                    }
                    let marker: String
                    if checklist || Renderer.checkbox(in: item) != nil {
                        let checked = item.classes.contains("checked") || Renderer.checkbox(in: item) == true
                        marker = checked ? "- [x] " : "- [ ] "
                    } else if ordered {
                        marker = "\(number). "
                        number = min(number + 1, Self.maxNumber)
                    } else {
                        marker = "- "
                    }
                    return .call(renderer.listItem(item, depth: depth, marker: marker))
                }
            }
            return .done(lines)
        }
    }

    private func listItem(_ item: HTMLElement, depth: Int, marker: String) -> ItemTask {
        var own: [HTMLNode] = [], nested: [HTMLElement] = []
        for child in item.children {
            if case .element(let element) = child, element.name == "ul" || element.name == "ol" {
                nested.append(element)
            } else {
                own.append(child)
            }
        }
        if item.name != "li" { own = [.element(item)] ; nested = [] }
        return ItemTask(self, own: own, nested: nested, depth: depth, marker: marker)
    }

    /// One list item: its own content on the marker line (further lines indented below it),
    /// then its nested lists.
    private final class ItemTask: RenderTask {
        let renderer: Renderer
        let own: [HTMLNode]
        let nested: [HTMLElement]
        let depth: Int
        let marker: String
        var started = false
        var lines: Lines = []
        var nestedIndex = 0

        init(_ renderer: Renderer, own: [HTMLNode], nested: [HTMLElement], depth: Int, marker: String) {
            self.renderer = renderer
            self.own = own
            self.nested = nested
            self.depth = depth
            self.marker = marker
        }

        func resume(with value: Lines?) -> RenderStep<Lines> {
            if !started {
                started = true
                return .call(BlocksTask(renderer, own, fences: false))
            }
            if let value {
                if nestedIndex == 0 {
                    let indent = String(repeating: "\t", count: depth)
                    let content = value.filter { $0.kind != .empty }.map(\.text)
                    lines = [HTMLToMarkdown.Line(
                        text: (indent + marker + (content.first ?? "")).trimmingTrailingSpaces(), kind: .list)]
                    for continuation in content.dropFirst() {
                        lines.append(.init(text: indent + "\t" + continuation, kind: .list))
                    }
                } else {
                    lines += value
                }
            }
            guard nestedIndex < nested.count else { return .done(lines) }
            nestedIndex += 1
            return .call(ListTask(renderer, nested[nestedIndex - 1], depth: depth + 1))
        }
    }

    /// `nil` without a checkbox input, else whether it is checked. The first input in document
    /// order wins; nested lists are not searched.
    private static func checkbox(in element: HTMLElement) -> Bool? {
        var pending = Array(element.children.reversed())
        while let node = pending.popLast() {
            guard case .element(let e) = node else { continue }
            if e.name == "input", (e.attributes["type"] ?? "").lowercased() == "checkbox" {
                return e.attributes["checked"] != nil
            }
            if e.name == "ul" || e.name == "ol" { continue }
            pending.append(contentsOf: e.children.reversed())
        }
        return nil
    }

    // MARK: Tables

    /// A GFM table from the `tr` rows found in document order (rows of nested tables stay inside
    /// their cell); each cell's blocks are joined on one line.
    private final class TableTask: RenderTask {
        let renderer: Renderer
        let rows: [[HTMLElement]]
        var texts: [[String]] = []
        var cells: [String] = []
        var rowIndex = 0
        var cellIndex = 0

        init(_ renderer: Renderer, _ element: HTMLElement) {
            self.renderer = renderer
            var rows: [[HTMLElement]] = []
            var pending = Array(element.children.reversed())
            while let node = pending.popLast() {
                guard case .element(let child) = node else { continue }
                switch child.name {
                case "tr":
                    rows.append(child.children.compactMap { cell in
                        guard case .element(let td) = cell, td.name == "td" || td.name == "th" else { return nil }
                        return td
                    })
                case "table": continue
                default: pending.append(contentsOf: child.children.reversed())
                }
            }
            self.rows = rows
        }

        func resume(with value: Lines?) -> RenderStep<Lines> {
            if let value {
                let text = value.filter { $0.kind != .empty }.map(\.text).joined(separator: " ")
                cells.append(text.replacingOccurrences(of: "|", with: "\\|"))
            }
            while rowIndex < rows.count {
                if cellIndex < rows[rowIndex].count {
                    cellIndex += 1
                    return .call(BlocksTask(renderer, rows[rowIndex][cellIndex - 1].children, fences: false))
                }
                texts.append(cells)
                cells = []
                rowIndex += 1
                cellIndex = 0
            }
            return .done(Self.lines(texts))
        }

        static func lines(_ rows: [[String]]) -> Lines {
            let width = rows.map(\.count).max() ?? 0
            guard width > 0 else { return [] }
            func row(_ cells: [String]) -> String {
                let padded = cells + Array(repeating: "", count: width - cells.count)
                return "| " + padded.joined(separator: " | ") + " |"
            }
            var lines = [HTMLToMarkdown.Line(text: row(rows[0]), kind: .table)]
            lines.append(.init(text: "|" + Array(repeating: " --- |", count: width).joined(), kind: .table))
            for cells in rows.dropFirst() { lines.append(.init(text: row(cells), kind: .table)) }
            return lines
        }
    }

    // MARK: Inline

    struct InlineContext {
        var bold = false, italic = false, underline = false, strike = false, highlight = false
    }

    /// Inline Markdown for `nodes`; `\n` is a hard line break (`<br>`).
    ///
    /// Never emits three tildes in a row (`~~~` opens a code fence at a line start): where an
    /// underline (`~`) or strike (`~~`) marker would touch the previous piece's marker, two strikes
    /// merge into one, otherwise the underline is dropped (strike wins).
    private func inline(_ nodes: [HTMLNode], _ context: InlineContext) -> String {
        Self.drive(InlineNodesTask(self, nodes, context))
    }

    /// `inline(nodes)`: one piece per node, with the tilde repair above.
    private final class InlineNodesTask: RenderTask {
        enum Phase {
            /// Render the node at `index`.
            case next
            /// The node's piece is the incoming value.
            case piece
            /// The node rendered without underline is the incoming value; `piece` is the plain one.
            case plainCheck(piece: String)
            /// The node rendered without underline (again) is the incoming value: it is the piece.
            case plainPiece
            /// The previous node rendered without underline is the incoming value.
            case plainPrevious(piece: String)
        }

        let renderer: Renderer
        let nodes: [HTMLNode]
        let context: InlineContext
        var index = 0
        var pieces: [(node: HTMLNode, text: String)] = []
        var phase = Phase.next

        init(_ renderer: Renderer, _ nodes: [HTMLNode], _ context: InlineContext) {
            self.renderer = renderer
            self.nodes = nodes
            self.context = context
        }

        var plain: InlineContext {
            var plain = context
            plain.underline = true
            return plain
        }

        func resume(with value: String?) -> RenderStep<String> {
            var value = value
            while true {
                switch phase {
                case .next:
                    guard index < nodes.count else { return .done(pieces.map(\.text).joined()) }
                    phase = .piece
                    switch nodes[index] {
                    case .text(let text): value = Renderer.escape(Renderer.collapse(text))
                    case .element(let element): return .call(InlineElementTask(renderer, element, context))
                    }
                case .piece:
                    var piece = value!
                    value = nil
                    guard let previous = pieces.last, Renderer.endsWithMarkerTilde(previous.text), piece.hasPrefix("~")
                    else {
                        append(piece)
                        continue
                    }
                    if previous.text.hasSuffix("~~"), piece.hasPrefix("~~"), !piece.hasPrefix("~~~"),
                       !Renderer.endsWithMarkerTilde(String(previous.text.dropLast(2))) {
                        pieces[pieces.count - 1].text.removeLast(2)
                        piece.removeFirst(2)
                        append(piece)
                    } else if case .element(let element) = nodes[index] {
                        phase = .plainCheck(piece: piece)
                        return .call(InlineElementTask(renderer, element, plain))
                    } else if let call = renderPreviousPlain(piece) {
                        return call
                    } else {
                        append(piece)
                    }
                case .plainCheck(let piece):
                    let checked = value!
                    value = nil
                    if !checked.hasPrefix("~"), case .element(let element) = nodes[index] {
                        phase = .plainPiece
                        return .call(InlineElementTask(renderer, element, plain))
                    }
                    if let call = renderPreviousPlain(piece) { return call }
                    append(piece)
                case .plainPiece:
                    append(value!)
                    value = nil
                case .plainPrevious(let piece):
                    pieces[pieces.count - 1].text = value!
                    value = nil
                    append(piece)
                }
            }
        }

        private func renderPreviousPlain(_ piece: String) -> RenderStep<String>? {
            guard case .element(let element) = pieces[pieces.count - 1].node else { return nil }
            phase = .plainPrevious(piece: piece)
            return .call(InlineElementTask(renderer, element, plain))
        }

        private func append(_ piece: String) {
            pieces.append((nodes[index], piece))
            index += 1
            phase = .next
        }
    }

    /// Ends in a `~` that is markup (not preceded by an odd number of backslashes).
    static func endsWithMarkerTilde(_ text: String) -> Bool {
        guard text.hasSuffix("~") else { return false }
        let backslashes = text.dropLast().reversed().prefix { $0 == "\\" }.count
        return backslashes % 2 == 0
    }

    /// Whether strike-through applies somewhere inside `nodes`.
    static func containsStrike(_ nodes: [HTMLNode]) -> Bool {
        var pending = [nodes]
        while let siblings = pending.popLast() {
            for case .element(let element) in siblings {
                if isStrike(element) { return true }
                pending.append(element.children)
            }
        }
        return false
    }

    static func isStrike(_ element: HTMLElement) -> Bool {
        let style = element.style
        let decoration = (style["text-decoration"] ?? "") + " " + (style["text-decoration-line"] ?? "")
        return ["strike", "s", "del"].contains(element.name) || decoration.contains("line-through")
    }

    /// `inline(element)`: leaves render at once; a link or a styled element waits for its content.
    private final class InlineElementTask: RenderTask {
        let renderer: Renderer
        let element: HTMLElement
        let context: InlineContext
        /// Emphasis markers to wrap the content in; `nil` for a link.
        var markers: [String]?

        init(_ renderer: Renderer, _ element: HTMLElement, _ context: InlineContext) {
            self.renderer = renderer
            self.element = element
            self.context = context
        }

        func resume(with value: String?) -> RenderStep<String> {
            guard var text = value else { return start() }
            guard let markers else { return .done(renderer.link(element, inner: text)) }
            if Renderer.blockElements.contains(element.name), !text.hasSuffix("\n") { text += "\n" }
            for marker in markers.reversed() { text = Renderer.wrap(text, marker) }
            return .done(text)
        }

        private func start() -> RenderStep<String> {
            let style = element.style
            switch element.name {
            case "br":
                return .done("\n")
            case "img":
                return .done(renderer.image(element))
            case "input":
                return .done("")
            case "tt", "code", "kbd", "samp":
                return .done(Renderer.codeSpan(Renderer.rawText(element.children, preserveWhitespace: false)))
            case "a":
                return .call(InlineNodesTask(renderer, element.children, context))
            default:
                break
            }
            if element.name == "font", Renderer.isMonospaceFace(element.attributes["face"]) {
                return .done(Renderer.codeSpan(Renderer.rawText(element.children, preserveWhitespace: false)))
            }
            if Renderer.isMonospaceFace(style["font-family"]) {
                return .done(Renderer.codeSpan(Renderer.rawText(element.children, preserveWhitespace: false)))
            }
            var inner = context
            var markers: [String] = []
            let weight = style["font-weight"] ?? ""
            if !context.bold, ["b", "strong"].contains(element.name) || weight == "bold" || weight == "bolder" || (Int(weight) ?? 0) >= 600 {
                inner.bold = true
                markers.append("**")
            }
            if !context.italic, ["i", "em", "cite", "var"].contains(element.name) || style["font-style"] == "italic" {
                inner.italic = true
                markers.append("*")
            }
            if renderer.isGeneric, !context.highlight, element.name == "mark" {
                inner.highlight = true
                markers.append("==")
            }
            let decoration = (style["text-decoration"] ?? "") + " " + (style["text-decoration-line"] ?? "")
            let strikeHere = !context.strike && Renderer.isStrike(element)
            if strikeHere {
                inner.strike = true
                markers.append("~~")
            }
            // Underline and strike together would need `~~~`: strike wins.
            if !context.underline, !context.strike, !strikeHere,
               ["u", "ins"].contains(element.name) || decoration.contains("underline"),
               !Renderer.containsStrike(element.children) {
                inner.underline = true
                markers.append("~")
            }
            self.markers = markers
            return .call(InlineNodesTask(renderer, element.children, inner))
        }
    }

    /// A link around its rendered content `inner`.
    private func link(_ element: HTMLElement, inner: String) -> String {
        let href = (element.attributes["href"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let plain = Self.collapse(Self.rawText(element.children, preserveWhitespace: false))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !href.isEmpty, !plain.isEmpty, !href.lowercased().hasPrefix("javascript:") else { return inner }
        // A page of unknown origin links only the web and mail; any other target is just text (M8-R55).
        if isGeneric, HTMLToMarkdown.allowedLinkTarget(href) == nil { return inner }
        let destination = href
            .replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
        if plain == href {
            return href.contains(" ") ? "<\(destination)>" : href
        }
        if href.lowercased().hasPrefix("mailto:"), plain == String(href.dropFirst(7)) { return plain }
        let label = inner.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return "[\(label)](\(destination))"
    }

    private func image(_ element: HTMLElement) -> String {
        let src = (element.attributes["src"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if src.lowercased().hasPrefix("data:") {
            guard let comma = src.firstIndex(of: ","), let semi = src.firstIndex(of: ";"), semi < comma,
                  src[semi..<comma].lowercased().contains("base64")
            else {
                undecodableImages += 1
                return ""
            }
            let payload = src[src.index(after: comma)...]
            // The decoded size is at most three quarters of the encoded length: refuse before decoding.
            if let limits = imageLimits {
                let bound = payload.utf8.count / 4 * 3 + 3
                if bound > limits.each || decodedBytes + bound > limits.total {
                    oversizedImages += 1
                    return ""
                }
            }
            guard let data = Data(base64Encoded: String(payload), options: .ignoreUnknownCharacters), !data.isEmpty
            else {
                undecodableImages += 1
                return ""
            }
            decodedBytes += data.count
            let mime = String(src[src.index(src.startIndex, offsetBy: 5)..<semi]).lowercased()
            let name = attachmentName(for: data, ext: Self.fileExtension(mime: mime))
            return "![](\(AttachmentLinkRewriter.encode(name)))"
        }
        let lower = src.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return "![](\(src.replacingOccurrences(of: " ", with: "%20")))"
        }
        if let kept = relativeImage(element, src: src) { return kept }
        if let resolved = resolved(src) { return "![](\(resolved))" }
        unsupportedImages += 1
        return ""
    }

    /// The `language-x` / `lang-x` class of a `pre` or of its `code` child, as a fence info string.
    static func language(of pre: HTMLElement) -> String {
        var candidates = [pre.classes]
        for case .element(let child) in pre.children where child.name == "code" { candidates.append(child.classes) }
        for classes in candidates {
            for name in classes.sorted() {
                for prefix in ["language-", "lang-"] where name.hasPrefix(prefix) {
                    let language = String(name.dropFirst(prefix.count))
                    if !language.isEmpty, language.unicodeScalars.allSatisfy({
                        Chars.isASCIILetter($0) || ("0"..."9").contains($0) || "+#-_.".unicodeScalars.contains($0)
                    }) { return language }
                }
            }
        }
        return ""
    }

    /// `![alt](src)` for a source without a scheme: the file is resolved by the attachment
    /// rewriter. `//host/x` (protocol-relative) is not a file.
    private func relativeImage(_ element: HTMLElement, src: String) -> String? {
        guard keepsRelativeImages, LinkDestination.isRelative(src), !src.hasPrefix("//"),
              let name = Self.relativeFileName(src),
              AttachmentLinkRewriter.imageExtensions.contains((name as NSString).pathExtension.lowercased())
        else { return nil }
        let alt = Self.cleanLine((element.attributes["alt"] ?? "").replacingOccurrences(of: "\n", with: " "))
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        let destination = src
            .replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
        return "![\(alt)](\(destination))"
    }

    /// `src` made absolute against `baseURL`, if that gives an http(s) URL with a host.
    private func resolved(_ src: String) -> String? {
        guard let baseURL, !src.isEmpty else { return nil }
        let encoded = src.replacingOccurrences(of: " ", with: "%20")
        guard let url = URL(string: encoded, relativeTo: baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else { return nil }
        return url.absoluteString
    }

    /// `image.png`, `image 2.png`, … (case-insensitive collisions). Identical data reuses its name.
    private func attachmentName(for data: Data, ext: String) -> String {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let existing = nameByDigest[digest] { return existing }
        var name = "image.\(ext)"
        var counter = 2
        while usedKeys.contains(AttachmentFiles.fileSystemKey(name)) {
            name = "image \(counter).\(ext)"
            counter += 1
        }
        usedKeys.insert(AttachmentFiles.fileSystemKey(name))
        nameByDigest[digest] = name
        images.append(ImportedAttachment(filename: name, data: data))
        return name
    }

    static func fileExtension(mime: String) -> String {
        switch mime {
        case "image/png": "png"
        case "image/jpeg", "image/jpg", "image/pjpeg": "jpg"
        case "image/gif": "gif"
        case "image/heic": "heic"
        case "image/heif": "heif"
        case "image/tiff": "tiff"
        case "image/webp": "webp"
        case "image/bmp": "bmp"
        case "image/svg+xml": "svg"
        default:
            mime.hasPrefix("image/") && mime.dropFirst(6).allSatisfy({ $0.isLetter || $0.isNumber })
                ? String(mime.dropFirst(6)) : "png"
        }
    }

    // MARK: Helpers

    static func isMonospaceFace(_ face: String?) -> Bool {
        guard let face = face?.lowercased() else { return false }
        return ["courier", "menlo", "monaco", "monospace", "sf mono", "consolas", "andale mono"].contains { face.contains($0) }
    }

    private static func isCode(_ element: HTMLElement) -> Bool {
        ["tt", "code", "kbd", "samp", "pre"].contains(element.name)
            || (element.name == "font" && isMonospaceFace(element.attributes["face"]))
            || isMonospaceFace(element.style["font-family"])
    }

    /// Every visible character of the run is inside `tt`/`code` (and there is at least one).
    static func isMonostyled(_ nodes: [HTMLNode]) -> Bool {
        var sawCode = false
        var pending = [nodes]
        while let siblings = pending.popLast() {
            for node in siblings {
                switch node {
                case .text(let text):
                    if !text.allSatisfy({ $0.isWhitespace }) { return false }
                case .element(let element):
                    if isCode(element) {
                        sawCode = true
                    } else if element.name == "img" {
                        return false
                    } else if element.name != "br" {
                        pending.append(element.children)
                    }
                }
            }
        }
        return sawCode
    }

    /// Text with `<br>` as `\n`, no Markdown. Without `preserveWhitespace` HTML whitespace collapses.
    /// Each open element collects its own text, which is appended to its parent's when it ends.
    static func rawText(_ nodes: [HTMLNode], preserveWhitespace: Bool) -> String {
        struct Open {
            var element: HTMLElement?
            var nodes: [HTMLNode]
            var index = 0
            var out = ""
        }
        var stack = [Open(element: nil, nodes: nodes)]
        while true {
            let top = stack.count - 1
            guard stack[top].index < stack[top].nodes.count else {
                let done = stack.removeLast()
                guard let element = done.element else { return done.out }
                stack[top - 1].out += done.out
                if blockElements.contains(element.name), !stack[top - 1].out.hasSuffix("\n") { stack[top - 1].out += "\n" }
                continue
            }
            let node = stack[top].nodes[stack[top].index]
            stack[top].index += 1
            switch node {
            case .text(let text): stack[top].out += preserveWhitespace ? text : collapse(text)
            case .element(let element):
                if element.name == "br" {
                    stack[top].out += "\n"
                } else if element.name != "img" {
                    stack.append(Open(element: element, nodes: element.children))
                }
            }
        }
    }

    static func hasContent(_ nodes: [HTMLNode]) -> Bool {
        nodes.contains { node in
            switch node {
            case .text(let text): !text.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
            case .element: true
            }
        }
    }

    /// HTML whitespace (not U+00A0) collapses to one space.
    static func collapse(_ text: String) -> String {
        var out = ""
        var pendingSpace = false
        for c in text.unicodeScalars {
            if c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\u{0C}" {
                pendingSpace = true
            } else {
                if pendingSpace { out.unicodeScalars.append(" "); pendingSpace = false }
                out.unicodeScalars.append(c)
            }
        }
        if pendingSpace { out += " " }
        return out
    }

    /// Collapses runs of spaces, turns non-breaking spaces into spaces, trims the line.
    static func cleanLine(_ line: String) -> String {
        var out = ""
        var lastSpace = false
        for c in line.unicodeScalars {
            if c == " " {
                if !lastSpace { out.unicodeScalars.append(c) }
                lastSpace = true
            } else {
                out.unicodeScalars.append(c == "\u{00A0}" ? " " : c)
                lastSpace = false
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
    }

    /// Wraps each line segment's non-space core in `marker` (Markdown emphasis must hug text).
    static func wrap(_ text: String, _ marker: String) -> String {
        text.components(separatedBy: "\n").map { segment in
            let scalars = Array(segment.unicodeScalars)
            func isSpace(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\u{00A0}" || c == "\t" }
            guard let first = scalars.firstIndex(where: { !isSpace($0) }),
                  let last = scalars.lastIndex(where: { !isSpace($0) }) else { return segment }
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[..<first])
            view.append(contentsOf: marker.unicodeScalars)
            view.append(contentsOf: scalars[first...last])
            view.append(contentsOf: marker.unicodeScalars)
            view.append(contentsOf: scalars[(last + 1)...])
            return String(view)
        }.joined(separator: "\n")
    }

    /// A code span per line, the fence longer than any backtick run inside.
    static func codeSpan(_ raw: String) -> String {
        raw.components(separatedBy: "\n").map { segment in
            let text = segment.replacingOccurrences(of: "\u{00A0}", with: " ")
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return segment }
            let fence = String(repeating: "`", count: HTMLToMarkdown.longestRun(of: "`", in: text) + 1)
            let padded = text.hasPrefix("`") || text.hasSuffix("`") ? " \(text) " : text
            return fence + padded + fence
        }.joined(separator: "\n")
    }

    private static let escaped: Set<Unicode.Scalar> = ["\\", "*", "`", "[", "]"]

    /// Backslash-escapes characters that would start Markdown inline syntax. Web URLs stay as
    /// they are (Bear links bare URLs); `#` stays so Notes hashtags become tags. Left alone where
    /// the parser cannot read them as markup (`InlineStripper`/`InlineScanner` rules): `_` between
    /// two letters or digits (intraword); `~` and `$` with whitespace on both sides *and* other
    /// text on both sides within this node. A node's edges are unsafe: `wrap` moves edge
    /// whitespace outside emphasis markers (`~~` + `~` would make `~~~`, a fence) and a neighbour
    /// node may be markup. For the same reason `=` at a node edge is escaped (`==` across nodes).
    static func escape(_ text: String) -> String {
        let s = Array(text.unicodeScalars)
        func visible(_ c: Unicode.Scalar) -> Bool { !Chars.isSpace(c) && c != "\u{00A0}" }
        // Computed once (not per character): linear in the node's length.
        let firstVisible = s.firstIndex(where: visible) ?? s.count
        let lastVisible = s.lastIndex(where: visible) ?? -1
        var out = String.UnicodeScalarView()
        var i = 0
        while i < s.count {
            if let end = urlEnd(s, at: i) {
                out.append(contentsOf: s[i..<end])
                i = end
                continue
            }
            let c = s[i]
            let prev: Unicode.Scalar? = i > 0 ? s[i - 1] : nil
            let next: Unicode.Scalar? = i + 1 < s.count ? s[i + 1] : nil
            func space(_ x: Unicode.Scalar?) -> Bool { x.map { Chars.isSpace($0) || $0 == "\u{00A0}" } ?? false }
            func alnum(_ x: Unicode.Scalar?) -> Bool { x.map(Chars.isAlnum) ?? false }
            let isolated = space(prev) && space(next) && firstVisible < i && i < lastVisible
            if escaped.contains(c)
                || (c == "_" && !(alnum(prev) && alnum(next)))
                || ((c == "~" || c == "$") && !isolated)
                || (c == "=" && (i == 0 || i == s.count - 1 || s[i + 1] == "=" || s[i - 1] == "="))
                || (c == "<" && i + 1 < s.count && s[i + 1] == "!") {
                out.append("\\")
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }

    /// End of a `http(s)://` URL starting at `i` (at a word start), or `nil`.
    private static func urlEnd(_ s: [Unicode.Scalar], at i: Int) -> Int? {
        guard s[i] == "h" || s[i] == "H", i == 0 || s[i - 1] == " " || s[i - 1] == "(" || s[i - 1] == "\u{00A0}" else {
            return nil
        }
        let prefix = String(String.UnicodeScalarView(s[i..<min(s.count, i + 8)])).lowercased()
        guard prefix.hasPrefix("https://") || prefix.hasPrefix("http://") else { return nil }
        var end = i
        while end < s.count, s[end] != " ", s[end] != "\u{00A0}", s[end] != "<", s[end] != ">" { end += 1 }
        while end > i, [".", ",", ";", ":", "!", "?", ")"].contains(s[end - 1]) { end -= 1 }
        return end
    }

    /// Escapes what would make a prose line a heading, list item, quote or rule.
    static func escapeLineStart(_ line: String) -> String {
        guard let first = line.unicodeScalars.first else { return line }
        let rest = line.dropFirst()
        switch first {
        case "#":
            let hashes = line.prefix { $0 == "#" }
            let after = line.dropFirst(hashes.count)
            if hashes.count <= 6, after.isEmpty || after.hasPrefix(" ") { return "\\" + line }
        case ">":
            return "\\" + line
        case "-", "+":
            if rest.isEmpty || rest.hasPrefix(" ") || line.allSatisfy({ $0 == "-" || $0 == " " }) { return "\\" + line }
        case "=":
            if line.allSatisfy({ $0 == "=" || $0 == " " }) { return "\\" + line }
        default:
            let digits = line.prefix { $0.isASCII && $0.isNumber }
            if !digits.isEmpty, digits.count <= 9 {
                let after = line.dropFirst(digits.count)
                if let marker = after.first, marker == "." || marker == ")",
                   after.dropFirst().isEmpty || after.dropFirst().hasPrefix(" ") {
                    return String(digits) + "\\" + String(after)
                }
            }
        }
        return line
    }
}

private extension String {
    func trimmingTrailingSpaces() -> String {
        var s = self
        while s.last == " " { s.removeLast() }
        return s
    }
}
