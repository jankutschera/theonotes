// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import Foundation

/// Word (DOCX) export. Our own writer, because the system writer drops every link
/// target and flattens tables to one paragraph per cell. It walks the attributed string RTF export
/// already uses and writes WordprocessingML: paragraphs, runs (bold, italic, underline, strike,
/// monospace, size, colour, superscript), Word heading styles from the paragraph's `headerLevel`,
/// external hyperlinks, tables from `NSTextTableBlock` (with spans) and list paragraphs that keep
/// the marker text and indent the importer produced.
///
/// Not covered: images (the string carries `[filename]` text, as in RTF), real Word numbering
/// (list markers are text), footnotes (the importer's superscript digit and numbered line), page
/// layout (Word's defaults), fonts beyond the family name.
enum DocxWriter {
    static func data(from text: NSAttributedString) -> Data {
        var body = Body()
        body.add(text)
        return package(body)
    }

    // MARK: - Body

    private struct Body {
        var xml = ""
        var links: [String] = []
        var headings = Set<Int>()
        var usesHyperlinkStyle = false

        mutating func add(_ text: NSAttributedString) {
            let string = text.string as NSString
            var paragraphs: [(range: NSRange, style: NSParagraphStyle?)] = []
            var position = 0
            while position < string.length {
                let range = string.paragraphRange(for: NSRange(location: position, length: 0))
                paragraphs.append((range, text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle))
                position = NSMaxRange(range)
            }
            var index = 0
            var lastWasTable = false
            while index < paragraphs.count {
                if let table = Self.table(of: paragraphs[index].style) {
                    var end = index
                    while end < paragraphs.count, Self.table(of: paragraphs[end].style) === table { end += 1 }
                    if lastWasTable { xml += "<w:p/>" }
                    addTable(table, paragraphs[index..<end].map { ($0.range, $0.style) }, in: text)
                    lastWasTable = true
                    index = end
                } else {
                    addParagraph(paragraphs[index].range, paragraphs[index].style, in: text)
                    lastWasTable = false
                    index += 1
                }
            }
            if lastWasTable { xml += "<w:p/>" }
        }

        private static func table(of style: NSParagraphStyle?) -> NSTextTable? {
            (style?.textBlocks.first as? NSTextTableBlock)?.table
        }

        // MARK: Tables

        private mutating func addTable(_ table: NSTextTable, _ cells: [(NSRange, NSParagraphStyle?)], in text: NSAttributedString) {
            struct Cell { var block: NSTextTableBlock; var paragraphs: [(NSRange, NSParagraphStyle?)] }
            var grid: [Int: [Int: Cell]] = [:]
            var rowCount = 0
            for (range, style) in cells {
                guard let block = style?.textBlocks.first as? NSTextTableBlock else { continue }
                grid[block.startingRow, default: [:]][block.startingColumn, default: Cell(block: block, paragraphs: [])]
                    .paragraphs.append((range, style))
                rowCount = max(rowCount, block.startingRow + block.rowSpan)
            }
            let columns = max(table.numberOfColumns, 1)
            var covered: [Int: [Int: Int]] = [:]  // row -> column -> column span of the cell that covers it
            // The importer resolves a source width (`width` attribute) to points; none means it sizes to its content.
            let width = table.contentWidthValueType == .absoluteValueType && table.contentWidth > 0
                ? "<w:tblW w:w=\"\(Int(table.contentWidth * 20))\" w:type=\"dxa\"/>" : "<w:tblW w:w=\"0\" w:type=\"auto\"/>"
            xml += "<w:tbl><w:tblPr>\(width)<w:tblBorders>"
            for side in ["top", "left", "bottom", "right", "insideH", "insideV"] {
                xml += "<w:\(side) w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"A0A0A0\"/>"
            }
            xml += "</w:tblBorders><w:tblCellMar><w:top w:w=\"40\" w:type=\"dxa\"/><w:left w:w=\"100\" w:type=\"dxa\"/>"
                + "<w:bottom w:w=\"40\" w:type=\"dxa\"/><w:right w:w=\"100\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr><w:tblGrid>" + String(repeating: "<w:gridCol w:w=\"2000\"/>", count: columns) + "</w:tblGrid>"
            for row in 0..<rowCount {
                xml += "<w:tr>"
                var column = 0
                while column < columns {
                    if let span = covered[row]?[column] {
                        xml += "<w:tc><w:tcPr>\(span > 1 ? "<w:gridSpan w:val=\"\(span)\"/>" : "")<w:vMerge/></w:tcPr><w:p/></w:tc>"
                        column += span
                    } else if let cell = grid[row]?[column] {
                        let colSpan = max(cell.block.columnSpan, 1), rowSpan = max(cell.block.rowSpan, 1)
                        if rowSpan > 1 { for r in (row + 1)..<(row + rowSpan) { covered[r, default: [:]][column] = colSpan } }
                        xml += "<w:tc><w:tcPr>\(colSpan > 1 ? "<w:gridSpan w:val=\"\(colSpan)\"/>" : "")"
                            + "\(rowSpan > 1 ? "<w:vMerge w:val=\"restart\"/>" : "")</w:tcPr>"
                        for (range, style) in cell.paragraphs { addParagraph(range, style, in: text) }
                        xml += "</w:tc>"
                        column += colSpan
                    } else {
                        xml += "<w:tc><w:p/></w:tc>"
                        column += 1
                    }
                }
                xml += "</w:tr>"
            }
            xml += "</w:tbl>"
        }

        // MARK: Paragraphs and runs

        private mutating func addParagraph(_ range: NSRange, _ style: NSParagraphStyle?, in text: NSAttributedString) {
            var content = NSRange(location: range.location, length: range.length)
            if content.length > 0, (text.string as NSString).character(at: NSMaxRange(content) - 1) == 0x0A { content.length -= 1 }
            let level = style.map { min(max($0.headerLevel, 0), 6) } ?? 0
            var properties = ""
            if level > 0 { headings.insert(level); properties += "<w:pStyle w:val=\"Heading\(level)\"/>" }
            // The importer writes "\t•\t" and "\t1\t"; the leading tab goes and the hanging indent does its job.
            var body = text.attributedSubstring(from: content)
            let listLevel = style?.textLists.count ?? 0
            if listLevel > 0 {
                if body.string.hasPrefix("\t") { body = body.attributedSubstring(from: NSRange(location: 1, length: body.length - 1)) }
                // An ordered marker reads "1.", not "1".
                if style?.textLists.last?.markerFormat == .decimal, let digits = body.string.range(of: #"^\d+(?=\t)"#, options: .regularExpression) {
                    let mutable = NSMutableAttributedString(attributedString: body)
                    let at = body.string.distance(from: body.string.startIndex, to: digits.upperBound)
                    mutable.replaceCharacters(in: NSRange(location: at, length: 0), with: NSAttributedString(string: ".", attributes: body.attributes(at: 0, effectiveRange: nil)))
                    body = mutable
                }
                properties += "<w:ind w:left=\"\(360 * listLevel)\" w:hanging=\"360\"/>"
            }
            if let style {
                if listLevel == 0, style.headIndent > 0 || style.firstLineHeadIndent > 0 {
                    let left = Int(style.headIndent * 20), hanging = Int((style.headIndent - style.firstLineHeadIndent) * 20)
                    properties += "<w:ind w:left=\"\(left)\""
                        + (hanging > 0 ? " w:hanging=\"\(hanging)\"" : (hanging < 0 ? " w:firstLine=\"\(-hanging)\"" : "")) + "/>"
                }
                switch style.alignment {
                case .center: properties += "<w:jc w:val=\"center\"/>"
                case .right: properties += "<w:jc w:val=\"right\"/>"
                case .justified: properties += "<w:jc w:val=\"both\"/>"
                default: break
                }
            }
            xml += "<w:p>" + (properties.isEmpty ? "" : "<w:pPr>\(properties)</w:pPr>")
            var position = 0
            while position < body.length {
                var runRange = NSRange()
                let attributes = body.attributes(at: position, longestEffectiveRange: &runRange, in: NSRange(location: 0, length: body.length))
                addRun(body.attributedSubstring(from: runRange).string, attributes, heading: level > 0)
                position = NSMaxRange(runRange)
            }
            xml += "</w:p>"
        }

        private mutating func addRun(_ raw: String, _ attributes: [NSAttributedString.Key: Any], heading: Bool) {
            let string = raw.unicodeScalars.filter { $0 != "\u{FFFC}" }.map(String.init).joined()
            if string.isEmpty { return }
            var properties = ""
            var target: String?
            if let link = attributes[.link] {
                target = (link as? URL)?.absoluteString ?? (link as? String)
            }
            if target != nil {
                usesHyperlinkStyle = true
                properties += "<w:rStyle w:val=\"Hyperlink\"/>"
            }
            if let font = attributes[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                // Body text follows the document default (Arial); only code keeps its own face.
                if traits.contains(.monoSpace), let family = font.familyName {
                    properties += "<w:rFonts w:ascii=\"\(Self.family(family))\" w:hAnsi=\"\(Self.family(family))\" w:cs=\"\(Self.family(family))\"/>"
                }
                if !heading {
                    if traits.contains(.bold) { properties += "<w:b/>" }
                    if traits.contains(.italic) { properties += "<w:i/>" }
                }
            }
            if (attributes[.strikethroughStyle] as? Int ?? 0) != 0 { properties += "<w:strike/>" }
            let font = attributes[.font] as? NSFont
            if target == nil, let color = (attributes[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB), !Self.isBlack(color) {
                properties += "<w:color w:val=\"\(Self.hex(color))\"/>"
            }
            let baseline = (attributes[.baselineOffset] as? NSNumber)?.doubleValue ?? 0
            let script = attributes[NSAttributedString.Key("NSSuperScript")] as? Int ?? 0
            let raised = baseline > 0 || script > 0, lowered = baseline < 0 || script < 0
            // The importer's body is 12 pt and ours 11 pt: sizes scale with it, and a body-sized run writes none.
            if !heading, !raised, !lowered, let font {
                let half = Int((font.pointSize * 2 * Self.bodyHalfPoints / Self.importerBodyHalfPoints).rounded())
                if half != Int(Self.bodyHalfPoints) { properties += "<w:sz w:val=\"\(half)\"/>" }
            }
            if target == nil, (attributes[.underlineStyle] as? Int ?? 0) != 0 { properties += "<w:u w:val=\"single\"/>" }
            if raised { properties += "<w:vertAlign w:val=\"superscript\"/>" } else if lowered { properties += "<w:vertAlign w:val=\"subscript\"/>" }
            var runs = ""
            var current = ""
            func flush() { if !current.isEmpty { runs += "<w:t xml:space=\"preserve\">\(DocxWriter.escape(current))</w:t>"; current = "" } }
            for character in string.unicodeScalars {
                switch character {
                case "\t": flush(); runs += "<w:tab/>"
                case "\u{2028}", "\u{0B}": flush(); runs += "<w:br/>"
                case "\n", "\r": break
                default: if DocxWriter.isXMLChar(character) { current.unicodeScalars.append(character) }
                }
            }
            flush()
            let run = "<w:r>" + (properties.isEmpty ? "" : "<w:rPr>\(properties)</w:rPr>") + runs + "</w:r>"
            if let target {
                var id = links.firstIndex(of: target).map { $0 + 1 }
                if id == nil { links.append(target); id = links.count }
                xml += "<w:hyperlink r:id=\"rId\(id! + 2)\">\(run)</w:hyperlink>"
            } else {
                xml += run
            }
        }

        static let bodyHalfPoints = 22.0
        private static let importerBodyHalfPoints = 24.0

        private static func family(_ name: String) -> String {
            switch name {
            case "Times": "Times New Roman"
            case "Courier": "Courier New"
            case "Helvetica": "Arial"
            default: DocxWriter.escape(name)
            }
        }

        private static func isBlack(_ color: NSColor) -> Bool { color.redComponent < 0.01 && color.greenComponent < 0.01 && color.blueComponent < 0.01 }

        private static func hex(_ color: NSColor) -> String {
            [color.redComponent, color.greenComponent, color.blueComponent]
                .map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
        }
    }

    // MARK: - XML

    static func escape(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: if isXMLChar(ch) { out.unicodeScalars.append(ch) }
            }
        }
        return out
    }

    /// XML 1.0 `Char` (tab, newline and carriage return are handled by the callers).
    fileprivate static func isXMLChar(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x9, 0xA, 0xD, 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF: true
        default: false
        }
    }

    // MARK: - Package

    private static let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
    private static let wordNS = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\""
    private static let relNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    private static func package(_ body: Body) -> Data {
        let contentTypes = header + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
            + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
            + "<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>"
            + "<Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/>"
            + "<Override PartName=\"/word/settings.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml\"/>"
            + "</Types>"
        let rootRels = header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" Type=\"\(relNS)/officeDocument\" Target=\"word/document.xml\"/></Relationships>"
        var documentRels = header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" Type=\"\(relNS)/styles\" Target=\"styles.xml\"/>"
            + "<Relationship Id=\"rId2\" Type=\"\(relNS)/settings\" Target=\"settings.xml\"/>"
        for (index, target) in body.links.enumerated() {
            documentRels += "<Relationship Id=\"rId\(index + 3)\" Type=\"\(relNS)/hyperlink\" Target=\"\(escape(target))\" TargetMode=\"External\"/>"
        }
        documentRels += "</Relationships>"
        let document = header + "<w:document \(wordNS) xmlns:r=\"\(relNS)\"><w:body>\(body.xml)</w:body></w:document>"

        let sizes = [1: 40, 2: 34, 3: 30, 4: 28, 5: 26, 6: 24]
        var styles = header + "<w:styles \(wordNS)><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=\"Arial\" w:hAnsi=\"Arial\" w:cs=\"Arial\"/><w:sz w:val=\"22\"/></w:rPr></w:rPrDefault></w:docDefaults>"
            + "<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/><w:pPr><w:spacing w:after=\"120\" w:line=\"264\" w:lineRule=\"auto\"/></w:pPr>"
            + "<w:rPr><w:rFonts w:ascii=\"Arial\" w:hAnsi=\"Arial\" w:cs=\"Arial\"/><w:sz w:val=\"22\"/></w:rPr></w:style>"
        for level in body.headings.sorted() {
            styles += "<w:style w:type=\"paragraph\" w:styleId=\"Heading\(level)\"><w:name w:val=\"heading \(level)\"/><w:basedOn w:val=\"Normal\"/>"
                + "<w:next w:val=\"Normal\"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before=\"240\" w:after=\"80\"/><w:outlineLvl w:val=\"\(level - 1)\"/></w:pPr>"
                + "<w:rPr><w:b/><w:sz w:val=\"\(sizes[level] ?? 24)\"/></w:rPr></w:style>"
        }
        if body.usesHyperlinkStyle {
            styles += "<w:style w:type=\"character\" w:styleId=\"Hyperlink\"><w:name w:val=\"Hyperlink\"/>"
                + "<w:rPr><w:color w:val=\"0563C1\"/><w:u w:val=\"single\"/></w:rPr></w:style>"
        }
        styles += "</w:styles>"

        // Mode 15 is Word 2013 and later; without it Word opens the file in Compatibility Mode.
        let settings = header + "<w:settings \(wordNS)><w:compat><w:compatSetting w:name=\"compatibilityMode\" "
            + "w:uri=\"http://schemas.microsoft.com/office/word\" w:val=\"15\"/></w:compat></w:settings>"

        return ZipArchive.data(entries: [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(rootRels.utf8)),
            ("word/document.xml", Data(document.utf8)),
            ("word/_rels/document.xml.rels", Data(documentRels.utf8)),
            ("word/styles.xml", Data(styles.utf8)),
            ("word/settings.xml", Data(settings.utf8)),
        ])
    }
}
