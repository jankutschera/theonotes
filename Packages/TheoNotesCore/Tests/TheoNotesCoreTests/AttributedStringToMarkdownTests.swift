// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

#if canImport(AppKit)
import AppKit
import Foundation
import Testing
@testable import TheoNotesCore

/// Attributed strings built in code → Bear Markdown (M8 Task 7, M8-R56).
@Suite struct AttributedStringToMarkdownTests {
    private static let size: CGFloat = 13

    private static var plain: NSFont { NSFont.systemFont(ofSize: size) }
    private static var bold: NSFont { NSFontManager.shared.convert(plain, toHaveTrait: .boldFontMask) }
    private static var italic: NSFont { NSFontManager.shared.convert(plain, toHaveTrait: .italicFontMask) }
    private static var boldItalic: NSFont { NSFontManager.shared.convert(bold, toHaveTrait: .italicFontMask) }
    private static var mono: NSFont { NSFont(name: "Menlo-Regular", size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) }

    private func build(_ pieces: [(String, [NSAttributedString.Key: Any])]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (text, attributes) in pieces {
            var attributes = attributes
            if attributes[.font] == nil { attributes[.font] = Self.plain }
            out.append(NSAttributedString(string: text, attributes: attributes))
        }
        return out
    }

    private func listStyle(_ formats: [NSTextList.MarkerFormat]) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.textLists = formats.map { NSTextList(markerFormat: $0, options: 0) }
        return style
    }

    private let png: Data = {
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }()

    @Test func boldItalicUnderlineStrike() {
        let text = build([
            ("plain ", [:]), ("bold", [.font: Self.bold]), (" ", [:]), ("it", [.font: Self.italic]), (" ", [:]),
            ("both", [.font: Self.boldItalic]), (" ", [:]),
            ("under", [.underlineStyle: NSUnderlineStyle.single.rawValue]), (" ", [:]),
            ("gone", [.strikethroughStyle: NSUnderlineStyle.single.rawValue]),
            (" tail\nsecond **star** ~tilde~ 1 < 2\n", [:]),
        ])
        let result = AttributedStringToMarkdown.convert(text)
        #expect(result.markdown == "plain **bold** *it* ***both*** ~under~ ~~gone~~ tail\nsecond \\*\\*star\\*\\* \\~tilde\\~ 1 < 2")
        #expect(result.images.isEmpty)
        #expect(result.warnings.isEmpty)
    }

    @Test func adjacentRunsWithTheSameStyleMergeAndTildesNeverTouch() {
        let bold = [NSAttributedString.Key.font: Self.bold]
        let under: [NSAttributedString.Key: Any] = [.underlineStyle: NSUnderlineStyle.single.rawValue]
        let strike: [NSAttributedString.Key: Any] = [.strikethroughStyle: NSUnderlineStyle.single.rawValue]
        #expect(AttributedStringToMarkdown.convert(build([("a", bold), ("b", bold), (" c", [:])])).markdown == "**ab** c")
        // Strike wins where an underline marker would touch it (as for HTML).
        #expect(AttributedStringToMarkdown.convert(build([("a", under), ("b", strike)])).markdown == "a~~b~~")
        #expect(AttributedStringToMarkdown.convert(build([("a", strike), ("b", under)])).markdown == "~~a~~b")
    }

    @Test func nestedListsUseTabs() {
        let bullets = listStyle([.disc])
        let nested = listStyle([.disc, .circle])
        let numbers = listStyle([.decimal])
        let text = build([
            ("intro\n", [:]),
            ("one\n", [.paragraphStyle: bullets]), ("two\n", [.paragraphStyle: bullets]),
            ("deep\n", [.paragraphStyle: nested]), ("deeper still\n", [.paragraphStyle: nested]),
            ("three\n", [.paragraphStyle: bullets]),
            ("between\n", [:]),
            ("first\n", [.paragraphStyle: numbers]), ("second\n", [.paragraphStyle: numbers]),
            ("# not a heading\n", [:]),
        ])
        #expect(AttributedStringToMarkdown.convert(text).markdown == """
            intro
            - one
            - two
            \t- deep
            \t- deeper still
            - three
            between
            1. first
            2. second
            \\# not a heading
            """)
    }

    @Test func listMarkerTextTheReaderLeavesInTheStringIsStripped() {
        let bullets = listStyle([.disc])
        let numbers = listStyle([.decimal])
        let text = build([
            ("\t\u{2022}\tapple\n", [.paragraphStyle: bullets]),
            ("\t1.\tone\n", [.paragraphStyle: numbers]), ("\t2.\ttwo\n", [.paragraphStyle: numbers]),
        ])
        #expect(AttributedStringToMarkdown.convert(text).markdown == "- apple\n1. one\n2. two")
    }

    @Test func linksOnlyForWebAndMail() {
        func linked(_ text: String, _ link: Any) -> NSAttributedString { build([(text, [.link: link])]) }
        #expect(AttributedStringToMarkdown.convert(linked("site", URL(string: "https://example.com/a b?x=(1)")!)).markdown
            == "[site](https://example.com/a%20b?x=%281%29)")
        #expect(AttributedStringToMarkdown.convert(linked("web", "http://example.com")).markdown == "[web](http://example.com)")
        #expect(AttributedStringToMarkdown.convert(linked("mail me", URL(string: "mailto:a@example.com")!)).markdown
            == "[mail me](mailto:a@example.com)")
        #expect(AttributedStringToMarkdown.convert(linked("https://example.com", URL(string: "https://example.com")!)).markdown
            == "https://example.com")
        for hostile in ["javascript:alert(1)", "file:///etc/passwd", "ftp://example.com", "data:text/html,x", "baerchen://note/1", "relative/path"] {
            #expect(AttributedStringToMarkdown.convert(linked("label", hostile)).markdown == "label", "\(hostile)")
        }
    }

    @Test func monospaceParagraphBecomesAFence() {
        let code = [NSAttributedString.Key.font: Self.mono]
        let text = build([
            ("Intro\n", [:]),
            ("let a = 1\n", code), ("\n", code), ("let `b` = 2\n", code),
            ("After with ", [:]), ("inline", code), (" code\n", [:]),
        ])
        #expect(AttributedStringToMarkdown.convert(text).markdown == "Intro\n```\nlet a = 1\n\nlet `b` = 2\n```\nAfter with `inline` code")
    }

    @Test func imageAttachmentBecomesAnAttachment() throws {
        func attachment(_ data: Data, type: String = "public.png") -> NSAttributedString {
            NSAttributedString(attachment: NSTextAttachment(data: data, ofType: type))
        }
        let named = NSTextAttachment(fileWrapper: {
            let wrapper = FileWrapper(regularFileWithContents: png)
            wrapper.preferredFilename = "my pic (1).png"
            return wrapper
        }())
        let text = NSMutableAttributedString(string: "before ")
        text.append(attachment(png))
        text.append(NSAttributedString(string: " middle "))
        text.append(attachment(png + Data([0])))
        text.append(NSAttributedString(string: "\n"))
        text.append(NSAttributedString(attachment: named))
        text.append(NSAttributedString(string: "\n"))
        text.append(attachment(Data("not an image".utf8), type: "public.plain-text"))
        text.append(NSAttributedString(string: "\nend"))
        let result = AttributedStringToMarkdown.convert(text)
        #expect(result.markdown == "before ![](image.png) middle ![](image%202.png)\n![](my%20pic%20%281%29.png)\n\nend")
        #expect(result.images.map(\.filename) == ["image.png", "image 2.png", "my pic (1).png"])
        #expect(result.images[0].data == png)
        #expect(result.warnings == ["1 attachment(s) that are not images were skipped"])
        let linked = NoteParser.metadata(for: result.markdown).attachments.map(\.filename)
        #expect(Set(linked) == ["image.png", "image 2.png", "my pic (1).png"])
    }

    @Test func noTitleLineIsAddedAndBlankParagraphsStay() {
        #expect(AttributedStringToMarkdown.convert(build([("First\n\nThird\n", [:])])).markdown == "First\n\nThird")
        #expect(AttributedStringToMarkdown.convert(NSAttributedString(string: "")).markdown == "")
        // U+2028 is a line break inside a paragraph.
        #expect(AttributedStringToMarkdown.convert(build([("a\u{2028}b\n", [:])])).markdown == "a\nb")
    }
}
#endif
