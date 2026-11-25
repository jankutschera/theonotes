// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

/// M8 Task 2: the text rewrites of an export (M8-R1, M8-R4) and plain text (M8-R14).
@Suite struct ExportTextTests {
    private func slice(_ text: String, _ range: Range<Int>) -> String {
        String(decoding: Array(text.utf8)[range], as: UTF8.self)
    }

    @Test func attachmentLinkTargetsCoverEncodedDestinations() {
        let text = "![](photo%202.jpg)<!-- {\"width\":\"320\"} -->\n[a.pdf](a.pdf)<!-- {\"embed\":\"true\"} -->"
        let targets = NoteParser.attachmentLinkTargets(in: text)
        #expect(targets.map { slice(text, $0.bytes) } == ["photo%202.jpg", "a.pdf"])
        #expect(targets.map(\.filename) == ["photo 2.jpg", "a.pdf"])
    }

    @Test func attachmentLinkTargetsHandleAnglesBomAndMultibyteText() {
        let text = "\u{FEFF}Üñí 日本 ![alt](<my pic.png> \"title\") and ![](ü%C3%BC.png)\n"
        let targets = NoteParser.attachmentLinkTargets(in: text)
        #expect(targets.map { slice(text, $0.bytes) } == ["my pic.png", "ü%C3%BC.png"])
        // Links in code and web images are not attachments.
        let none = "`![](a.png)`\n```\n![](b.png)\n```\n![](https://x.com/c.png)\n"
        #expect(NoteParser.attachmentLinkTargets(in: none).isEmpty)
    }

    @Test func prefixingKeepsEverythingElseByteForByte() {
        let text = "# Üñí\n\n![](photo%202.jpg)<!-- {\"width\":\"320\"} -->\n[a.pdf](a.pdf)<!-- {\"embed\":\"true\"} -->\n"
            + "[web](https://x.com) `![](code.png)`\n"
        let out = ExportText.prefixingAttachmentLinks(text, with: "My%20Note/")
        #expect(out == "# Üñí\n\n![](My%20Note/photo%202.jpg)<!-- {\"width\":\"320\"} -->\n"
            + "[a.pdf](My%20Note/a.pdf)<!-- {\"embed\":\"true\"} -->\n[web](https://x.com) `![](code.png)`\n")
        #expect(ExportText.prefixingAttachmentLinks("no links\n", with: "x/") == "no links\n")
        // The prefix goes inside the angle brackets.
        #expect(ExportText.prefixingAttachmentLinks("![](<a b.png>)", with: "assets/") == "![](<assets/a b.png>)")
    }

    @Test func removingTagsDropsTagOnlyLinesAndInlineTags() {
        #expect(ExportText.removingTags("# T\nsee #a here\n\n#b #c/d#\n") == "# T\nsee here\n\n")
        #expect(ExportText.removingTags("#a text\n") == "text\n")
        #expect(ExportText.removingTags("text #a\nnext #b #c\n") == "text\nnext\n")
        #expect(ExportText.removingTags("x\n#a") == "x")
        #expect(ExportText.removingTags("x\r\n#a") == "x")
        #expect(ExportText.removingTags("x\r\n#a\r\n#b") == "x")
        #expect(ExportText.removingTags("# T\n\n#a\n#b\n") == "# T\n\n")
        #expect(ExportText.removingTags("call (#a) now") == "call () now")
        #expect(ExportText.removingTags("no tags here\n") == "no tags here\n")
        #expect(ExportText.removingTags("Üñí #日本 ok\r\n#a\r\nend") == "Üñí ok\r\nend")
    }

    @Test func removingTagsLeavesCodeAndLinks() {
        let text = "`#code` and https://x.com/#frag and [t](https://x.com/#a)\n```\n#fence\n```\n---\ntags: [#fm]\n---\n"
        #expect(ExportText.removingTags(text) == text)
        let mixed = "a `#code` #real b\n"
        #expect(ExportText.removingTags(mixed) == "a `#code` b\n")
    }

    @Test func plainTextRules() {
        // Heading marker.
        #expect(PlainTextExport.text("## Head *x*") == "Head x")
        #expect(PlainTextExport.text("> ## Quoted head") == "> Quoted head")
        // Fence lines go, code stays verbatim.
        #expect(PlainTextExport.text("a\n```swift\nlet a = *b* # c\n```\nz") == "a\nlet a = *b* # c\nz")
        #expect(PlainTextExport.text("~~~\n  indented\n~~~") == "  indented")
        // Front matter.
        #expect(PlainTextExport.text("---\ntags: [x]\n---\n# T\nbody") == "T\nbody")
        // Table: delimiter row gone, pipes become tabs.
        #expect(PlainTextExport.text("| a | b |\n|---|:-:|\n| 1 | **2** |\nafter") == "a\tb\n1\t2\nafter")
        // Wiki alias, link text, image.
        #expect(PlainTextExport.text("[[Target|Alias]] and [[Plain]]") == "Alias and Plain")
        #expect(PlainTextExport.text("[text](https://x.com) ![img](a.png)x") == "text x")
        // Todo, list and quote markers stay as typed.
        #expect(PlainTextExport.text("- [ ] task *a*\n- [x] done\n1. one\n> quote **q**") == "- [ ] task a\n- [x] done\n1. one\n> quote q")
        // Attachment metadata comment gone, file link text kept.
        #expect(PlainTextExport.text("[a.pdf](a.pdf)<!-- {\"embed\":\"true\"} -->") == "a.pdf")
        #expect(PlainTextExport.text("![](p.png)<!-- {\"width\":\"3\"} -->") == "")
        // Tags verbatim, highlights lose their delimiters.
        #expect(PlainTextExport.text("see #a/b and ==hi== ==🔴red==") == "see #a/b and hi red")
        // Math blocks and trailing newline survive.
        #expect(PlainTextExport.text("$$\nx_1 = *y*\n$$\nend\n") == "$$\nx_1 = *y*\n$$\nend\n")
    }
}
