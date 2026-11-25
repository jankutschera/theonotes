// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import Foundation
import Testing
@testable import TheoNotes

/// A8 (MAC11-R15 replacement): the own Word writer. The fragment is the pre-check fixture
/// (`docs/release/evidence/2026-11-14-mac-export-1.1/docx-precheck/fragment.html`) plus a line of
/// characters XML must escape.
@MainActor
@Suite(.serialized) struct DocxExportTests {
    static let fragment = """
        <p>Fixture Note</p>
        <h1>Heading one</h1>
        <h2>Heading two</h2>
        <p>Some <strong>bold</strong> and <em>italic</em> and <s>gone</s> text with a <a href="https://example.com/page?a=1&amp;b=2">link</a>.</p>
        <p>Tricky &amp; &lt;b&gt; &quot;quoted&quot; caf\u{e9} \u{1F600}</p>
        <ul><li>fruit<ul><li>apples<ul><li>green</li></ul></li><li>pears</li></ul></li><li>veg</li></ul>
        <ol><li>one</li><li>two</li></ol>
        <table><thead><tr><th>Name</th><th>Qty</th></tr></thead>
        <tbody><tr><td>Tea</td><td>2</td></tr><tr><td>Milk</td><td>5</td></tr></tbody></table>
        <pre><code>let x = 1</code></pre>
        <p>[photo.png]</p>
        """

    static func write(_ fragment: String = fragment) throws -> (url: URL, data: Data) {
        let data = try RichText.docxData(fromFragment: fragment)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("docx-\(UUID().uuidString).docx")
        try data.write(to: url)
        return (url, data)
    }

    static func unzip(_ arguments: [String]) throws -> (status: Int32, out: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, out)
    }

    static func part(_ name: String, of url: URL) throws -> String {
        String(decoding: try unzip(["-p", url.path, name.replacingOccurrences(of: "[", with: "\\[")]).out, as: UTF8.self)
    }

    @Test func theContainerIsAValidZipWithWellFormedParts() throws {
        let (url, _) = try Self.write()
        defer { try? FileManager.default.removeItem(at: url) }
        let test = try Self.unzip(["-t", url.path])
        #expect(test.status == 0, "\(String(decoding: test.out, as: UTF8.self))")
        let names = ["[Content_Types].xml", "_rels/.rels", "word/document.xml", "word/_rels/document.xml.rels", "word/styles.xml", "word/settings.xml"]
        for name in names {
            let xml = try Self.part(name, of: url)
            #expect((try? XMLDocument(xmlString: xml, options: [])) != nil, "\(name) is not well-formed")
        }
    }

    @Test func theFileOpensOutsideCompatibilityModeAndCellsHavePadding() throws {
        let (url, _) = try Self.write()
        defer { try? FileManager.default.removeItem(at: url) }
        let settings = try Self.part("word/settings.xml", of: url)
        #expect(settings.contains("<w:compatSetting w:name=\"compatibilityMode\" w:uri=\"http://schemas.microsoft.com/office/word\" w:val=\"15\"/>"))
        let types = try Self.part("[Content_Types].xml", of: url)
        let rels = try Self.part("word/_rels/document.xml.rels", of: url)
        #expect(types.contains("/word/settings.xml") && rels.contains("Target=\"settings.xml\""))
        let document = try Self.part("word/document.xml", of: url)
        #expect(document.contains("<w:tblCellMar><w:top w:w=\"40\" w:type=\"dxa\"/><w:left w:w=\"100\" w:type=\"dxa\"/><w:bottom w:w=\"40\" w:type=\"dxa\"/><w:right w:w=\"100\" w:type=\"dxa\"/></w:tblCellMar>"))
        #expect(document.contains("<w:tblW w:w=\"0\" w:type=\"auto\"/>"))
        // A table the source gives a width follows it.
        let (wide, _) = try Self.write("<table width=\"300\"><tr><td>a</td></tr></table>")
        defer { try? FileManager.default.removeItem(at: wide) }
        let wideXML = try Self.part("word/document.xml", of: wide)
        #expect(wideXML.contains("<w:tblW w:w=\"6000\" w:type=\"dxa\"/>"), "\(wideXML.prefix(400))")
    }

    @Test func hyperlinkTableHeadingsAndRunsAreWritten() throws {
        let (url, _) = try Self.write()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try Self.part("word/document.xml", of: url)
        let rels = try Self.part("word/_rels/document.xml.rels", of: url)
        let styles = try Self.part("word/styles.xml", of: url)

        let id = try #require(document.range(of: #"<w:hyperlink r:id="(rId\d+)">"#, options: .regularExpression)
            .map { String(document[$0]).replacingOccurrences(of: #"<w:hyperlink r:id=""#, with: "").replacingOccurrences(of: "\">", with: "") })
        #expect(rels.contains("Id=\"\(id)\"") && rels.contains("Target=\"https://example.com/page?a=1&amp;b=2\"") && rels.contains("TargetMode=\"External\""))

        #expect(document.components(separatedBy: "<w:tbl>").count == 2)
        #expect(document.components(separatedBy: "<w:tr>").count == 4)
        #expect(document.components(separatedBy: "<w:tc>").count == 7)
        for cell in ["Name", "Qty", "Tea", "2", "Milk", "5"] { #expect(document.contains(">\(cell)</w:t>"), "cell \(cell)") }

        #expect(document.contains("<w:pStyle w:val=\"Heading1\"/>") && document.contains("<w:pStyle w:val=\"Heading2\"/>"))
        #expect(styles.contains("w:styleId=\"Heading1\"") && styles.contains("w:styleId=\"Heading2\"") && !styles.contains("Heading3"))
        #expect(document.range(of: #"<w:rPr>[^>]*(<[^>]+>)*?<w:b/>(<[^>]+>)*?</w:rPr><w:t xml:space="preserve">bold</w:t>"#, options: .regularExpression) != nil)
        #expect(document.range(of: #"<w:i/>(<[^>]+>)*?</w:rPr><w:t xml:space="preserve">italic</w:t>"#, options: .regularExpression) != nil)
        #expect(document.range(of: #"<w:strike/>(<[^>]+>)*?</w:rPr><w:t xml:space="preserve">gone</w:t>"#, options: .regularExpression) != nil)

        #expect(document.contains("Tricky &amp; &lt;b&gt; &quot;quoted&quot; caf\u{e9} \u{1F600}"))
        #expect(document.contains("fruit") && document.contains("<w:tab/>") && document.contains("w:hanging="))
    }

    @Test func bodyTextFollowsTheDocumentDefaultAndOnlyCodeKeepsItsOwnFont() throws {
        let (url, _) = try Self.write()
        defer { try? FileManager.default.removeItem(at: url) }
        let styles = try Self.part("word/styles.xml", of: url)
        let document = try Self.part("word/document.xml", of: url)
        #expect(styles.contains("<w:rPrDefault><w:rPr><w:rFonts w:ascii=\"Arial\" w:hAnsi=\"Arial\" w:cs=\"Arial\"/><w:sz w:val=\"22\"/></w:rPr></w:rPrDefault>"))
        #expect(styles.contains("w:styleId=\"Normal\"><w:name w:val=\"Normal\"/><w:pPr><w:spacing w:after=\"120\" w:line=\"264\" w:lineRule=\"auto\"/></w:pPr><w:rPr><w:rFonts w:ascii=\"Arial\" w:hAnsi=\"Arial\" w:cs=\"Arial\"/><w:sz w:val=\"22\"/></w:rPr></w:style>"))
        #expect(!document.contains("Times New Roman"))
        #expect(document.contains("w:ascii=\"Courier New\""))
        #expect(document.components(separatedBy: "<w:rFonts").count == 2, "only the code run names a font")
        // A body run writes no size; the heading size comes from its style.
        #expect(document.contains("<w:r><w:t xml:space=\"preserve\">Heading one</w:t></w:r>"))
    }

    @Test func listsIndentThreeHundredSixtyPerLevelAndOrderedMarkersKeepTheirDot() throws {
        let (url, _) = try Self.write()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try Self.part("word/document.xml", of: url)
        #expect(document.contains("<w:ind w:left=\"360\" w:hanging=\"360\"/>"))
        #expect(document.contains("<w:ind w:left=\"720\" w:hanging=\"360\"/>"))
        #expect(document.contains("<w:ind w:left=\"1080\" w:hanging=\"360\"/>"))
        #expect(!document.contains("w:hanging=\"720\""))
        #expect(document.contains(">1.</w:t><w:tab/>") && document.contains(">2.</w:t><w:tab/>"))
        #expect(!document.contains(">1</w:t><w:tab/>"))
        #expect(document.contains(">\u{2022}</w:t><w:tab/>"))
    }

    @Test func theSystemReaderSeesTheSameTextAndTheTable() throws {
        let (_, data) = try Self.write()
        let original = try RichText.attributed(fromFragment: Self.fragment)
        let read = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
        func lines(_ s: String) -> [String] { s.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) } }
        // The writer gives ordered markers their dot ("1", not "1.").
        let dotted = lines(original.string).map { $0.replacingOccurrences(of: #"^(\d+)\t"#, with: "$1.\t", options: .regularExpression) }
        #expect(lines(read.string) == dotted)
        // Apple's reader keeps no hyperlink targets from any DOCX (also not from pandoc's), so the link
        // is checked in the XML (test above) and with pandoc (evidence file), not here.
        var tables = Set<ObjectIdentifier>()
        read.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: read.length)) { value, _, _ in
            if let table = ((value as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock)?.table { tables.insert(ObjectIdentifier(table)) }
        }
        #expect(tables.count == 1)
    }

    @Test func spansAndControlCharactersStayValid() throws {
        let (url, _) = try Self.write("""
            <table><tr><td colspan="2">wide</td></tr><tr><td rowspan="2">tall</td><td>x</td></tr><tr><td>y</td></tr></table>
            <p>a\u{1}b</p>
            """)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try Self.part("word/document.xml", of: url)
        #expect((try? XMLDocument(xmlString: document, options: [])) != nil)
        #expect(document.contains("<w:gridSpan w:val=\"2\"/>") && document.contains("<w:vMerge w:val=\"restart\"/>") && document.contains("<w:vMerge/>"))
        #expect(!document.contains("\u{1}"))
    }
}
