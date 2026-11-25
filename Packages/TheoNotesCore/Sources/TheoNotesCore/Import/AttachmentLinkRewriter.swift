// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// Files in an import root, by file-system name key, for resolving Obsidian `[[name.ext]]` embeds.
final class VaultIndex {
    private var byName: [String: [URL]] = [:]

    init(root: URL) {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in walker where url.lastPathComponent != "__MACOSX" {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            byName[AttachmentFiles.fileSystemKey(url.lastPathComponent), default: []].append(url)
        }
        for key in byName.keys {
            byName[key]?.sort { ($0.pathComponents.count, $0.path) < ($1.pathComponents.count, $1.path) }
        }
    }

    /// The shallowest file with this name.
    func lookup(_ name: String) -> URL? { byName[AttachmentFiles.fileSystemKey(name)]?.first }
}

/// Rewrites a note's file links into Bear's attachment syntax (spec D4) while collecting the
/// files to copy: relative links (`assets/x.jpg`, `../files/b.pdf`) that resolve to a file inside
/// the import root become `x.jpg` / `b.pdf`; Obsidian `![[x.png]]` / `[[b.pdf]]` embeds become
/// Markdown links. Links in code are left alone, as are web links, links outside the root and
/// missing files (the last two are reported). Non-image links get a metadata comment so they
/// index as attachments.
struct AttachmentLinkRewriter {
    private struct Edit {
        var range: Range<Int>
        var replacement: String
    }

    static let noteExtensions: Set<String> = ["md", "markdown", "mdown", "txt"]
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "svg", "avif",
    ]
    /// Extensions that make an unresolvable `[[name.ext]]` a missing file rather than a note title.
    private static let attachmentExtensions: Set<String> = imageExtensions.union([
        "pdf", "mp3", "m4a", "wav", "aac", "flac", "ogg", "mp4", "mov", "m4v", "webm", "mkv",
        "zip", "docx", "doc", "xlsx", "xls", "pptx", "ppt", "key", "pages", "numbers", "csv", "json", "epub",
    ])

    /// Size caps for the files a note's links copy; without them (`nil`) a file is read whole.
    struct Limits: Equatable, Sendable {
        /// A single file over this is not copied.
        var each: Int
        /// All files of one note together; a file that would pass it is not copied.
        var total: Int
    }

    private let noteDir: URL
    private let root: URL
    private let index: VaultIndex?
    /// A TextBundle's `assets/` folder: everything linked inside it is an attachment, whatever its
    /// extension (elsewhere a `.md` / `.txt` link target is another note, not a file to copy).
    private let attachmentsFolder: URL?
    private let limits: Limits?
    /// Store a file whose own name is a UUID under its link text (`![Invoice 7](Attachments/<UUID>.pdf)`
    /// becomes `Invoice 7.pdf`) when that text can be a file name; other names are kept.
    private let namesFromLinkText: Bool
    private var copiedBytes = 0

    private(set) var attachments: [ImportedAttachment] = []
    private(set) var warnings: [String] = []
    private var nameBySource: [String: String] = [:]
    private var usedKeys: Set<String> = []
    private var remoteImages = 0

    /// `reservedNames`: attachment names the note already uses (images converted from `data:`
    /// URLs); copied files never take them.
    init(
        noteDir: URL, root: URL, index: VaultIndex?, reservedNames: [String] = [], attachmentsFolder: URL? = nil,
        namesFromLinkText: Bool = false, limits: Limits? = nil
    ) {
        self.limits = limits
        self.namesFromLinkText = namesFromLinkText
        self.noteDir = noteDir.standardizedFileURL
        self.root = root.standardizedFileURL
        self.index = index
        self.attachmentsFolder = attachmentsFolder?.standardizedFileURL
        self.usedKeys = Set(reservedNames.map(AttachmentFiles.fileSystemKey))
    }

    // MARK: - Text

    mutating func rewrite(_ text: String) -> String {
        var out: [String] = []
        var fence: (marker: Unicode.Scalar, length: Int)?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = Array(line.unicodeScalars)
            if let open = fence {
                if Self.closesFence(s, open) { fence = nil }
                out.append(String(line))
            } else if let open = Self.fenceOpening(s) {
                fence = open
                out.append(String(line))
            } else {
                out.append(rewriteLine(s, original: line))
            }
        }
        if remoteImages > 0 {
            warnings.append("\(remoteImages) image link(s) to the web left as is (not downloaded)")
        }
        return out.joined(separator: "\n")
    }

    private static func fenceOpening(_ s: [Unicode.Scalar]) -> (marker: Unicode.Scalar, length: Int)? {
        var i = 0
        while i < s.count, s[i] == " " || s[i] == "\t" { i += 1 }
        guard i < s.count, s[i] == "`" || s[i] == "~" else { return nil }
        let marker = s[i]
        var j = i
        while j < s.count, s[j] == marker { j += 1 }
        guard j - i >= 3 else { return nil }
        if marker == "`", s[j...].contains("`") { return nil }
        return (marker, j - i)
    }

    private static func closesFence(_ s: [Unicode.Scalar], _ open: (marker: Unicode.Scalar, length: Int)) -> Bool {
        var i = 0
        while i < s.count, s[i] == " " || s[i] == "\t" { i += 1 }
        var j = i
        while j < s.count, s[j] == open.marker { j += 1 }
        guard j - i >= open.length else { return false }
        return s[j...].allSatisfy { $0 == " " || $0 == "\t" }
    }

    // MARK: - Line scan

    private mutating func rewriteLine(_ s: [Unicode.Scalar], original: Substring) -> String {
        var edits: [Edit] = []
        var openers: [(pos: Int, isImage: Bool)] = []
        let n = s.count
        var i = 0
        while i < n {
            let c = s[i]
            if c == "\\" {
                i += 2
            } else if c == "`" {
                var j = i
                while j < n, s[j] == "`" { j += 1 }
                let length = j - i
                var k = j, closed: Int?
                while k < n {
                    if s[k] == "`" {
                        var m = k
                        while m < n, s[m] == "`" { m += 1 }
                        if m - k == length { closed = m; break }
                        k = m
                    } else {
                        k += 1
                    }
                }
                i = closed ?? j
            } else if c == "[" || (c == "!" && i + 1 < n && s[i + 1] == "[") {
                let bang = c == "!"
                let open = bang ? i + 1 : i
                if open + 1 < n, s[open + 1] == "[", let close = Self.wikiClose(s, from: open + 2) {
                    wikiLink(s, start: i, inner: open + 2..<close, bang: bang, edits: &edits)
                    i = close + 2
                } else {
                    openers.append((i, bang))
                    i = open + 1
                }
            } else if c == "]" {
                if let opener = openers.popLast(), i + 1 < n, s[i + 1] == "(",
                   let dest = LinkDestination.parseWithRange(s, from: i + 2) {
                    link(s, opener: opener, close: i, dest: dest, edits: &edits)
                    i = dest.end
                } else {
                    i += 1
                }
            } else {
                i += 1
            }
        }
        guard !edits.isEmpty else { return String(original) }
        var result = s
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            result.replaceSubrange(edit.range, with: Array(edit.replacement.unicodeScalars))
        }
        return String(String.UnicodeScalarView(result))
    }

    private static func wikiClose(_ s: [Unicode.Scalar], from start: Int) -> Int? {
        var i = start
        while i + 1 < s.count {
            if s[i] == "]", s[i + 1] == "]" { return i }
            if s[i] == "[" { return nil }
            i += 1
        }
        return nil
    }

    // MARK: - Markdown links

    private mutating func link(
        _ s: [Unicode.Scalar], opener: (pos: Int, isImage: Bool), close: Int,
        dest: (text: String, end: Int, textRange: Range<Int>), edits: inout [Edit]
    ) {
        let raw = dest.text
        if Self.isWeb(raw) {
            if opener.isImage { remoteImages += 1 }
            return
        }
        guard let target = resolve(raw) else { return }
        let preferred = namesFromLinkText && UUID(uuidString: target.url.deletingPathExtension().lastPathComponent) != nil
            ? Self.displayName(
                String(String.UnicodeScalarView(s[opener.pos + (opener.isImage ? 2 : 1)..<close])),
                ext: target.url.pathExtension)
            : nil
        guard let name = copy(target.url, preferredName: preferred ?? target.name) else { return }
        let ext = target.url.pathExtension.lowercased()
        let isAngled = dest.textRange.lowerBound > 0 && s[dest.textRange.lowerBound - 1] == "<"
        let spelled = Self.spelling(of: name, replacing: raw, angled: isAngled)
        edits.append(Edit(range: dest.textRange, replacement: spelled))
        if opener.isImage, Self.imageExtensions.contains(ext) { return }
        if opener.isImage {
            let altEmpty = s[opener.pos + 2..<close].allSatisfy { $0 == " " || $0 == "\t" }
            edits.append(Edit(range: opener.pos..<opener.pos + 2, replacement: "[" + (altEmpty ? Self.escapeText(target.name) : "")))
        }
        if LinkDestination.metadataCommentStart(s, after: dest.end) == nil {
            edits.append(Edit(range: dest.end..<dest.end, replacement: " " + Self.comment(ext: ext)))
        }
    }

    /// `text` plus the file's own extension as a file name, or `nil` when the text cannot be one
    /// (empty, or no letter or digit left once the characters that do not belong in a name are
    /// replaced). Backslash escapes are read; `/ \ :` and control characters become `-`; leading
    /// dots are dropped so a name never starts a hidden file; at most 100 characters.
    static func displayName(_ text: String, ext: String) -> String? {
        var plain = ""
        var escaped = false
        for ch in text {
            if !escaped, ch == "\\" { escaped = true; continue }
            escaped = false
            let unwanted = ch.unicodeScalars.contains {
                $0.properties.generalCategory == .control || "/\\:".unicodeScalars.contains($0)
            }
            plain.append(unwanted ? "-" : ch)
        }
        var name = String(plain.trimmingCharacters(in: .whitespacesAndNewlines).drop { $0 == "." }.prefix(100))
        name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        guard !ext.isEmpty, !name.lowercased().hasSuffix("." + ext.lowercased()) else { return name }
        return name + "." + ext
    }

    private static func isWeb(_ dest: String) -> Bool {
        let lower = dest.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }

    /// A link destination as a file inside the root, or `nil` (untouched; reported when it is a
    /// relative link to a file that is outside the root or missing).
    private mutating func resolve(_ raw: String) -> (url: URL, name: String)? {
        let isFileURL = raw.lowercased().hasPrefix("file://")
        let isAbsolute = raw.hasPrefix("/") || isFileURL
        guard isAbsolute || LinkDestination.isRelative(raw) else { return nil }
        var path = raw
        if isFileURL { path = URL(string: raw)?.path ?? String(raw.dropFirst(7)) }
        path = path.removingPercentEncoding ?? path

        func url(_ path: String) -> URL {
            (isAbsolute ? URL(fileURLWithPath: path) : URL(fileURLWithPath: path, relativeTo: noteDir)).standardizedFileURL
        }
        var target = url(path)
        var shown = path
        if !FileManager.default.fileExists(atPath: target.path) {
            // `file.pdf#page=2` / `file.pdf?raw=1`
            let stripped = String(path.prefix { $0 != "#" && $0 != "?" })
            if stripped != path, !stripped.isEmpty { target = url(stripped); shown = stripped }
        }
        let ext = target.pathExtension.lowercased()
        if Self.noteExtensions.contains(ext), !isInAttachmentsFolder(target) { return nil }

        guard inside(target) else {
            if !isAbsolute || FileManager.default.fileExists(atPath: target.path) {
                warnings.append("'\(raw)' points outside the import folder, left as is")
            }
            return nil
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) else {
            if !isAbsolute { warnings.append("attachment '\(shown)' not found, link left as is") }
            return nil
        }
        guard !isDirectory.boolValue else { return nil }
        guard inside(target.resolvingSymlinksInPath(), realRoot: true) else {
            warnings.append("'\(raw)' points outside the import folder, left as is")
            return nil
        }
        guard !isHidden(target), !isHidden(target.resolvingSymlinksInPath(), realRoot: true) else {
            warnings.append("'\(raw)' is in a hidden folder or hidden file, not copied, link left as is")
            return nil
        }
        return (target, (shown as NSString).lastPathComponent)
    }

    private func isInAttachmentsFolder(_ url: URL) -> Bool {
        guard let folder = attachmentsFolder else { return false }
        return url.standardizedFileURL.path.hasPrefix(folder.path.hasSuffix("/") ? folder.path : folder.path + "/")
    }

    private func inside(_ url: URL, realRoot: Bool = false) -> Bool {
        let base = (realRoot ? root.resolvingSymlinksInPath() : root).path
        let path = url.standardizedFileURL.path
        return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    /// Any path component below the root starting with `.` (`.ssh`, `.git`, `.env`, `.obsidian`).
    private func isHidden(_ url: URL, realRoot: Bool = false) -> Bool {
        let base = (realRoot ? root.resolvingSymlinksInPath() : root).path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base) else { return false }
        return path.dropFirst(base.count).split(separator: "/").contains { $0.hasPrefix(".") }
    }

    // MARK: - Obsidian embeds

    private mutating func wikiLink(
        _ s: [Unicode.Scalar], start: Int, inner: Range<Int>, bang: Bool, edits: inout [Edit]
    ) {
        var target = String(String.UnicodeScalarView(s[inner]))
        if let bar = target.firstIndex(of: "|") { target = String(target[..<bar]) }
        if let hash = target.firstIndex(of: "#") { target = String(target[..<hash]) }
        target = target.trimmingCharacters(in: .whitespaces)
        let name = (target as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, !Self.noteExtensions.contains(ext) else { return }
        guard let url = lookup(target, name: name) else {
            if Self.attachmentExtensions.contains(ext) {
                warnings.append("attachment '\(target)' not found, link left as is")
            }
            return
        }
        guard !isHidden(url), !isHidden(url.resolvingSymlinksInPath(), realRoot: true) else {
            warnings.append("'\(target)' is in a hidden folder or hidden file, not copied, link left as is")
            return
        }
        guard let stored = copy(url, preferredName: name) else { return }
        let display = Self.escapeText(name)
        let replacement = bang && Self.imageExtensions.contains(ext)
            ? "![\(display)](\(Self.encode(stored)))"
            : "[\(display)](\(Self.encode(stored))) \(Self.comment(ext: ext))"
        edits.append(Edit(range: start..<inner.upperBound + 2, replacement: replacement))
    }

    /// Relative to the note, then to the root (Obsidian paths), then by name anywhere in the root.
    private func lookup(_ target: String, name: String) -> URL? {
        let fm = FileManager.default
        var candidates = [URL(fileURLWithPath: target, relativeTo: noteDir).standardizedFileURL]
        if target.contains("/") { candidates.append(URL(fileURLWithPath: target, relativeTo: root).standardizedFileURL) }
        for url in candidates where inside(url) {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
               inside(url.resolvingSymlinksInPath(), realRoot: true) { return url }
        }
        guard let found = index?.lookup(name), inside(found.resolvingSymlinksInPath(), realRoot: true) else { return nil }
        return found
    }

    // MARK: - Copying

    /// The filename the file gets in the note (collisions become `x 2.jpg`), or `nil` when it
    /// cannot be read (reported).
    private mutating func copy(_ url: URL, preferredName: String) -> String? {
        if let existing = nameBySource[url.path] { return existing }
        let data: Data
        if let limits {
            // The size is looked at before anything is read, and the read itself stops one byte
            // past the cap, so a file that grows meanwhile cannot fill the memory either.
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else {
                warnings.append("attachment '\(preferredName)' could not be read, link left as is")
                return nil
            }
            guard size <= limits.each else {
                warnings.append("attachment '\(preferredName)' is larger than \(limits.each >> 20) MB, not copied, link left as is")
                return nil
            }
            guard size <= limits.total - copiedBytes else {
                warnings.append("attachment '\(preferredName)' would pass the size limit for this import's attachments, not copied, link left as is")
                return nil
            }
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                warnings.append("attachment '\(preferredName)' could not be read, link left as is")
                return nil
            }
            defer { try? handle.close() }
            guard let read = try? handle.read(upToCount: limits.each + 1) else {
                warnings.append("attachment '\(preferredName)' could not be read, link left as is")
                return nil
            }
            guard read.count <= limits.each, read.count <= limits.total - copiedBytes else {
                warnings.append("attachment '\(preferredName)' grew while it was read, not copied, link left as is")
                return nil
            }
            data = read
        } else if let read = try? Data(contentsOf: url) {
            data = read
        } else {
            warnings.append("attachment '\(preferredName)' could not be read, link left as is")
            return nil
        }
        copiedBytes += data.count
        var name = preferredName
        var counter = 2
        let base = (preferredName as NSString).deletingPathExtension
        let ext = (preferredName as NSString).pathExtension
        while usedKeys.contains(AttachmentFiles.fileSystemKey(name)) {
            name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            counter += 1
        }
        usedKeys.insert(AttachmentFiles.fileSystemKey(name))
        nameBySource[url.path] = name
        attachments.append(ImportedAttachment(filename: name, data: data, source: url))
        return name
    }

    // MARK: - Syntax helpers

    static func comment(ext: String) -> String {
        ext == "pdf" ? #"<!-- {"preview":"true","embed":"true"} -->"# : #"<!-- {"embed":"true"} -->"#
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Percent-encodes everything but RFC 3986 unreserved characters (parentheses and spaces
    /// would end the destination).
    static func encode(_ filename: String) -> String {
        filename.addingPercentEncoding(withAllowedCharacters: unreserved) ?? filename
    }

    /// The destination text for `name`, in the form the source link used: only the path changes.
    /// An angle-bracket destination keeps raw spaces; a percent-encoded name keeps the case of
    /// its escapes (`%c3%a9` stays lower-case). Anything else, and any name that would not read
    /// back as itself, is written with `encode`.
    static func spelling(of name: String, replacing raw: String, angled: Bool) -> String {
        let written = String(raw.split(separator: "/", omittingEmptySubsequences: false).last ?? "")
        if angled {
            let readsBack = (written.removingPercentEncoding ?? written) == name
            if readsBack, !written.contains(where: { $0 == "<" || $0 == ">" || $0.isNewline }) { return written }
        } else if written.lowercased() == encode(name).lowercased() {
            return written
        }
        return encode(name)
    }

    private static func escapeText(_ text: String) -> String {
        text.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
    }
}
