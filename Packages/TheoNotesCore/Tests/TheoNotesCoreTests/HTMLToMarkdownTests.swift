// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

/// Synthetic Apple Notes bodies (structure as returned by Notes' JXA `body()`) → Bear Markdown.
@Suite struct HTMLToMarkdownTests {
    struct Fixture: CustomTestStringConvertible, Sendable {
        var name: String
        var html: String
        var markdown: String
        var testDescription: String { name }
    }

    static let png1 = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]).base64EncodedString()
    static let png2 = Data([0x89, 0x50, 0x4E, 0x47, 4, 5, 6]).base64EncodedString()

    static let fixtures: [Fixture] = [
        Fixture(name: "h1 title and lines", html: "<div><h1>Groceries</h1></div>\n<div>Milk</div>\n<div>Bread</div>\n",
                markdown: "# Groceries\nMilk\nBread"),
        Fixture(name: "plain first line becomes the title", html: "<div>Plain title</div><div>body</div>",
                markdown: "# Plain title\nbody"),
        Fixture(name: "bold first line becomes the title without markers",
                html: "<div><b><span style=\"font-size: 24px\">Old title</span></b></div><div>x</div>",
                markdown: "# Old title\nx"),
        Fixture(name: "empty divs are empty lines", html: "<div><h1>T</h1></div><div><br></div><div>a</div><div><br></div><div><br></div><div>b</div><div><br></div>",
                markdown: "# T\n\na\n\n\nb"),
        Fixture(name: "inline styles", html: "<div><h1>T</h1></div><div><b>bold</b> <i>it</i> <u>under</u> <strike>gone</strike></div>",
                markdown: "# T\n**bold** *it* ~under~ ~~gone~~"),
        Fixture(name: "emphasis hugs text", html: "<div><h1>T</h1></div><div>a<b> bold </b>b<i></i></div>",
                markdown: "# T\na **bold** b"),
        Fixture(name: "nested same style is not doubled", html: "<div><h1>T</h1></div><div><b>a <b>b</b> c</b></div>",
                markdown: "# T\n**a b c**"),
        Fixture(name: "bold and italic combined", html: "<div><h1>T</h1></div><div><b><i>both</i></b></div>",
                markdown: "# T\n***both***"),
        Fixture(name: "headings h2 and h3, bold inside a heading dropped",
                html: "<div><h1>T</h1></div><div><h2>Heading</h2></div><div><h3><b>Sub</b>heading</h3></div>",
                markdown: "# T\n## Heading\n### Subheading"),
        Fixture(name: "dash list", html: "<div><h1>T</h1></div><ul class=\"Apple-dash-list\">\n<li>one</li>\n<li>two</li>\n</ul>",
                markdown: "# T\n- one\n- two"),
        Fixture(name: "nested list as a sibling of li", html: "<div><h1>T</h1></div><ul><li>a</li><ul><li>a1</li><ul><li>a1x</li></ul></ul><li>b</li></ul>",
                markdown: "# T\n- a\n\t- a1\n\t\t- a1x\n- b"),
        Fixture(name: "nested list inside li", html: "<div><h1>T</h1></div><ul><li>a<ul><li>inner</li></ul></li></ul>",
                markdown: "# T\n- a\n\t- inner"),
        Fixture(name: "ordered list numbering", html: "<div><h1>T</h1></div><ol><li>first</li><li>second</li><ol><li>sub</li></ol><li>third</li></ol>",
                markdown: "# T\n1. first\n2. second\n\t1. sub\n3. third"),
        Fixture(name: "checklist classes", html: "<div><h1>T</h1></div><ul class=\"checklist\"><li>open</li><li class=\"checked\">done</li></ul>",
                markdown: "# T\n- [ ] open\n- [x] done"),
        Fixture(name: "checkbox inputs", html: "<div><h1>T</h1></div><ul><li><input type=\"checkbox\">open</li><li><input type=\"checkbox\" checked>done</li></ul>",
                markdown: "# T\n- [ ] open\n- [x] done"),
        Fixture(name: "link with text", html: "<div><h1>T</h1></div><div>See <a href=\"https://example.com/a b\">the docs</a>.</div>",
                markdown: "# T\nSee [the docs](https://example.com/a%20b)."),
        Fixture(name: "link whose text is the URL stays bare", html: "<div><h1>T</h1></div><div><a href=\"https://example.com/x_y\">https://example.com/x_y</a></div>",
                markdown: "# T\nhttps://example.com/x_y"),
        Fixture(name: "empty link around br is an empty line", html: "<div><h1>T</h1></div><div><a href=\"https://e.com\"><br></a></div><div>x</div>",
                markdown: "# T\n\nx"),
        Fixture(name: "inline monospace", html: "<div><h1>T</h1></div><div>run <tt>ls -la</tt> now</div>",
                markdown: "# T\nrun `ls -la` now"),
        Fixture(name: "monostyled lines become a fenced block",
                html: "<div><h1>T</h1></div><div><tt>let a = 1</tt></div><div><br></div><div><tt>let b = 2</tt></div><div>after</div>",
                markdown: "# T\n```\nlet a = 1\n\nlet b = 2\n```\nafter"),
        Fixture(name: "code with backticks gets a longer fence", html: "<div><h1>T</h1></div><div><tt>a ``` b</tt></div>",
                markdown: "# T\n````\na ``` b\n````"),
        Fixture(name: "table to GFM", html: """
                <div><h1>T</h1></div><div><object><table cellspacing="0" cellpadding="0"><tbody>\
                <tr><td valign="top"><div>Name</div></td><td valign="top"><div><b>Qty</b></div></td></tr>\
                <tr><td valign="top"><div>a|b</div></td><td valign="top"><div>2</div></td></tr>\
                </tbody></table></object></div><div>after</div>
                """,
                markdown: "# T\n\n| Name | **Qty** |\n| --- | --- |\n| a\\|b | 2 |\n\nafter"),
        Fixture(name: "uneven table rows are padded", html: "<div><h1>T</h1></div><table><tr><td>a</td><td>b</td></tr><tr><td>c</td></tr></table>",
                markdown: "# T\n\n| a | b |\n| --- | --- |\n| c |  |"),
        Fixture(name: "data images become attachments", html: """
                <div><h1>T</h1></div><div><img style="max-width: 100%; max-height: 100%;" src="data:image/png;base64,\(png1)"/></div>\
                <div><img src="data:image/png;base64,\(png2)"/></div><div><img src="data:image/png;base64,\(png1)"/></div>
                """,
                markdown: "# T\n![](image.png)\n![](image%202.png)\n![](image.png)"),
        Fixture(name: "heic image keeps its type", html: "<div><h1>T</h1></div><div><img src=\"data:image/heic;base64,\(png1)\"></div>",
                markdown: "# T\n![](image.heic)"),
        Fixture(name: "remote image stays a link", html: "<div><h1>T</h1></div><div><img src=\"https://e.com/p.png\"></div>",
                markdown: "# T\n![](https://e.com/p.png)"),
        Fixture(name: "markdown characters are escaped", html: "<div><h1>T</h1></div><div>2*3 = 6_x [y] costs $5 ~ok~ `c` ==hi==</div>",
                markdown: "# T\n2\\*3 = 6_x \\[y\\] costs \\$5 \\~ok\\~ \\`c\\` \\=\\=hi\\=\\="),
        Fixture(name: "line starts that would be syntax are escaped",
                html: "<div><h1>T</h1></div><div># not heading</div><div>- not list</div><div>1. not ordered</div><div>&gt; not quote</div><div>---</div>",
                markdown: "# T\n\\# not heading\n\\- not list\n1\\. not ordered\n\\> not quote\n\\---"),
        Fixture(name: "entities", html: "<div><h1>T</h1></div><div>a &amp; b &lt;c&gt; d&nbsp;e &#x1F43B; &#8212; &unknown;</div>",
                markdown: "# T\na & b <c> d e 🐻 — &unknown;"),
        Fixture(name: "hashtags stay tags", html: "<div><h1>T</h1></div><div>tagged #work and #home/kitchen</div>",
                markdown: "# T\ntagged #work and #home/kitchen"),
        Fixture(name: "blockquote", html: "<div><h1>T</h1></div><blockquote><div>quoted</div><div><br></div><div>more</div></blockquote>",
                markdown: "# T\n> quoted\n>\n> more"),
        Fixture(name: "br inside a div splits lines, trailing br ends it", html: "<div><h1>T</h1></div><div>one<br>two<br></div>",
                markdown: "# T\none\ntwo"),
        Fixture(name: "styles on spans", html: """
                <div><h1>T</h1></div><div><span style="font-weight: bold">b</span> <span style="font-style: italic">i</span> \
                <span style="text-decoration: line-through">s</span> <span style="text-decoration: underline">u</span> \
                <span style="font-family: Menlo">m</span></div>
                """,
                markdown: "# T\n**b** *i* ~~s~~ ~u~ `m`"),
        Fixture(name: "unknown tags are transparent, script/style/comments dropped",
                html: "<html><head><style>div{}</style></head><body><div><h1>T</h1></div><!-- c --><div><font color=\"red\">red</font><script>x()</script></div></body></html>",
                markdown: "# T\nred"),
        Fixture(name: "URLs in text keep underscores", html: "<div><h1>T</h1></div><div>go to https://e.com/a_b_c, then snake_case</div>",
                markdown: "# T\ngo to https://e.com/a_b_c, then snake_case"),
        Fixture(name: "unclosed and stray tags are tolerated", html: "<div><h1>T</h1></div><p>one<p>two</span></div><div>three",
                markdown: "# T\none\ntwo\nthree"),
        Fixture(name: "legacy body without divs", html: "Title line<br>second line<br><br>third",
                markdown: "# Title line\nsecond line\n\nthird"),
        Fixture(name: "horizontal rule", html: "<div><h1>T</h1></div><div>a</div><hr><div>b</div>",
                markdown: "# T\na\n---\nb"),
        Fixture(name: "first line image is not a title", html: "<div><img src=\"data:image/png;base64,\(png1)\"></div><div>caption</div>",
                markdown: "![](image.png)\ncaption"),
        Fixture(name: "empty body", html: "", markdown: ""),
        Fixture(name: "underline around strike emits strike only", html: "<div><h1>T</h1></div><div><u><strike>x</strike></u></div>",
                markdown: "# T\n~~x~~"),
        Fixture(name: "strike around underline emits strike only", html: "<div><h1>T</h1></div><div><strike><u>x</u> y</strike></div>",
                markdown: "# T\n~~x y~~"),
        Fixture(name: "underline and line-through in one style", html: "<div><h1>T</h1></div><div><span style=\"text-decoration: underline line-through\">x</span></div>",
                markdown: "# T\n~~x~~"),
        Fixture(name: "underline around partly struck text", html: "<div><h1>T</h1></div><div><u><s>a</s> b</u></div>",
                markdown: "# T\n~~a~~ b"),
        Fixture(name: "adjacent underline then strike", html: "<div><h1>T</h1></div><div><u>a</u><strike>b</strike></div>",
                markdown: "# T\na~~b~~"),
        Fixture(name: "adjacent strike then underline", html: "<div><h1>T</h1></div><div><strike>a</strike><u>b</u></div>",
                markdown: "# T\n~~a~~b"),
        Fixture(name: "adjacent strikes merge", html: "<div><h1>T</h1></div><div><strike>a</strike><s>b</s></div>",
                markdown: "# T\n~~ab~~"),
        Fixture(name: "underline+strike at a list item start", html: "<div><h1>T</h1></div><ul><li><u><strike>x</strike></u> rest</li></ul><div>after #tag</div>",
                markdown: "# T\n- ~~x~~ rest\nafter #tag"),
        Fixture(name: "lone tildes and dollars and intraword underscores stay", html: "<div><h1>T</h1></div><div>a ~ b $ c snake_case 5_000</div>",
                markdown: "# T\na ~ b $ c snake_case 5_000"),
        Fixture(name: "markup-capable tildes, dollars, underscores are escaped",
                html: "<div><h1>T</h1></div><div>~a a~ $x$ _lead trail_ a_ _b</div>",
                markdown: "# T\n\\~a a\\~ \\$x\\$ \\_lead trail\\_ a\\_ \\_b"),
        Fixture(name: "whitespace between blocks is ignored", html: "\n  <div><h1>T</h1></div>\n\n  <div>  spaced   out  </div>\n",
                markdown: "# T\nspaced out"),
    ]

    @Test(arguments: fixtures) func testFixture(_ fixture: Fixture) {
        #expect(HTMLToMarkdown.convert(fixture.html).markdown == fixture.markdown)
    }

    /// Literal text must come back literally from the parser (nothing read as markup, no
    /// backslash left visible): the converted first line is the note title.
    static let literals = [
        "a ~ b ~ c", "~x~ and ~~y~~", "$5 and $10", "$x$", "snake_case _a_ __b__", "*not* **bold**",
        "[link](x) and `code`", "==hi== =", "1_000_000", "C:\\path\\to", "<!-- c -->", "a~~~b", "~~~",
        "x_ y _z", "price: 5 $", "under_score_", "end~",
    ]

    @Test(arguments: literals) func testLiteralTextSurvivesParsing(_ text: String) {
        let html = "<div>" + text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") + "</div>"
        let markdown = HTMLToMarkdown.convert(html).markdown
        #expect(NoteParser.metadata(for: markdown).title == text, "\(markdown)")
    }

    /// Three or more tildes not started by a backslash escape (`\~` is a literal tilde).
    static func hasUnescapedTildeRun(_ markdown: String) -> Bool {
        var run = 0
        var escaped = false
        for c in markdown {
            if escaped { escaped = false; run = 0; continue }
            if c == "\\" { escaped = true; run = 0; continue }
            run = c == "~" ? run + 1 : 0
            if run >= 3 { return true }
        }
        return false
    }

    @Test func testTildeRunCheck() {
        #expect(Self.hasUnescapedTildeRun("~~~ x"))
        #expect(Self.hasUnescapedTildeRun("a ~~~"))
        #expect(!Self.hasUnescapedTildeRun("~~\\~~~"))
        #expect(!Self.hasUnescapedTildeRun("~a~ ~~b~~"))
    }

    /// No styling combination may put three tildes in a row (a tilde fence at a line start).
    @Test func testNoTripleTildes() {
        let wrappers = ["<u>%</u>", "<strike>%</strike>", "<s>%</s>", "<span style=\"text-decoration: underline\">%</span>",
                        "<span style=\"text-decoration: line-through underline\">%</span>", "<b>%</b>"]
        var htmls: [String] = []
        for a in wrappers {
            for b in wrappers {
                htmls.append(a.replacingOccurrences(of: "%", with: b.replacingOccurrences(of: "%", with: "x")))
                htmls.append(a.replacingOccurrences(of: "%", with: "x") + b.replacingOccurrences(of: "%", with: "y"))
                for c in wrappers {
                    htmls.append(a.replacingOccurrences(of: "%", with: "x") + b.replacingOccurrences(of: "%", with: "y")
                                 + c.replacingOccurrences(of: "%", with: "z"))
                }
            }
        }
        // Tildes at text-node edges: wrap() moves edge whitespace outside the markers.
        for fill in [" ~ x", "x ~ ", " ~ ", "~", " ~~ ", "x ~"] {
            for wrapper in wrappers {
                htmls.append(wrapper.replacingOccurrences(of: "%", with: fill))
                htmls.append("a<br>" + wrapper.replacingOccurrences(of: "%", with: fill))
                htmls.append(wrapper.replacingOccurrences(of: "%", with: fill) + "<s>y</s>")
                htmls.append("<u>x ~ </u>" + wrapper.replacingOccurrences(of: "%", with: fill))
            }
        }
        for html in htmls {
            for container in ["<div>%</div>", "<ul><li>%</li></ul>"] {
                let markdown = HTMLToMarkdown.convert(
                    "<div><h1>T</h1></div>" + container.replacingOccurrences(of: "%", with: html) + "<div>end #tag</div>").markdown
                #expect(!Self.hasUnescapedTildeRun(markdown), "\(html) → \(markdown)")
                #expect(NoteParser.metadata(for: markdown).tags == ["tag"], "\(html) → \(markdown)")
            }
        }
    }

    /// Review cases (round 2): visible text must parse back literally; no math, highlight or fence.
    static let crossNodeCases: [(html: String, title: String)] = [
        ("<strike> ~ x</strike>", "~ x"),
        ("<s> ~ </s>", "~"),
        ("<strike>x ~ </strike>", "x ~"),
        ("<u>x ~ </u><s>y</s>", "x ~ y"),
        ("<i>x $ </i>and<i> $ y</i>", "x $ and $ y"),
        ("a=<font color=\"red\">=hi=</font>=", "a==hi=="),
        ("a<b>=</b>=b", "a==b"),
        ("<b>x</b> ~ <b>y</b>", "x ~ y"),
    ]

    @Test func testCrossNodeMarkupIsNotFormed() {
        for (html, title) in Self.crossNodeCases {
            let markdown = HTMLToMarkdown.convert("<div>\(html)</div><div>after #tag</div>").markdown
            let metadata = NoteParser.metadata(for: markdown)
            #expect(metadata.title == title, "\(html) → \(markdown)")
            #expect(metadata.tags == ["tag"], "\(html) → \(markdown)")
            #expect(!Self.hasUnescapedTildeRun(markdown), "\(html) → \(markdown)")
        }
    }

    @Test func testThereAreEnoughFixtures() {
        #expect(Self.fixtures.count >= 25)
    }

    @Test func testImagesAreNamedAndDeduplicated() {
        let html = Self.fixtures.first { $0.name == "data images become attachments" }!.html
        let result = HTMLToMarkdown.convert(html)
        #expect(result.images.map(\.filename) == ["image.png", "image 2.png"])
        #expect(result.images[0].data == Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]))
        #expect(result.images[1].data == Data([0x89, 0x50, 0x4E, 0x47, 4, 5, 6]))
        let linked = NoteParser.metadata(for: result.markdown).attachments.map(\.filename)
        #expect(Set(linked) == ["image.png", "image 2.png"])
    }

    /// A base URL resolves relative image sources as text (nothing is fetched); only http(s)
    /// results are kept (final review M7).
    @Test func testRelativeImagesResolveAgainstTheBaseURL() throws {
        let html = #"<p>x</p><img src="img/p.png"><img src="/abs one.png"><img src="//cdn.example/q.png">"#
            + #"<img src="../up.png"><img src="https://other.example/k.png"><img src="file:///etc/x.png">"#
        let base = try #require(URL(string: "https://example.com/a/b/page.html"))
        let r = HTMLToMarkdown.convert(html, baseURL: base)
        let images = r.markdown.matches(of: /!\[\]\([^)]*\)/).map { String($0.output) }
        #expect(images == [
            "![](https://example.com/a/b/img/p.png)", "![](https://example.com/abs%20one.png)",
            "![](https://cdn.example/q.png)", "![](https://example.com/a/up.png)", "![](https://other.example/k.png)",
        ])
        #expect(r.warnings == ["1 image(s) without embedded data skipped"])
        // Without a base, or with a base that is not http(s), relative sources are still dropped.
        #expect(!HTMLToMarkdown.convert(#"<img src="img/p.png">"#).markdown.contains("!["))
        let fileBase = try #require(URL(string: "file:///Users/me/page.html"))
        #expect(!HTMLToMarkdown.convert(#"<img src="img/p.png">"#, baseURL: fileBase).markdown.contains("!["))
    }

    @Test func testUndecodableAndUnsupportedImagesAreReported() {
        let result = HTMLToMarkdown.convert(
            "<div><h1>T</h1></div><div><img src=\"data:image/png;base64,\"></div><div><img src=\"cid:abc\"></div>")
        #expect(result.markdown == "# T")
        #expect(result.images.isEmpty)
        #expect(result.warnings == [
            "1 embedded image(s) could not be decoded", "1 image(s) without embedded data skipped",
        ])
    }

    @Test func testParsedMetadataMatchesNotesStructure() {
        let html = "<div><h1>Trip</h1></div><div>Packing #travel</div><ul class=\"checklist\"><li class=\"checked\">passport</li><li>charger</li></ul>"
        let metadata = NoteParser.metadata(for: HTMLToMarkdown.convert(html).markdown)
        #expect(metadata.title == "Trip")
        #expect(metadata.tags == ["travel"])
    }

    // MARK: - Generic HTML (M8 Task 7, M8-R55)

    private func generic(_ html: String) -> String {
        HTMLToMarkdown.convert(html, makesTitle: false, keepsRelativeImages: true).markdown
    }

    @Test func scriptAndStyleContentIsDropped() {
        let html = "<html><head><title>T</title><style>p{color:red}</style><script>alert(1)</script></head>"
            + "<body><p>kept</p><script>var x = '<p>no</p>'</script><style>b{}</style></body></html>"
        #expect(generic(html) == "kept")
    }

    @Test func makesTitleFalseKeepsTheFirstLine() {
        #expect(HTMLToMarkdown.convert("<div>First</div><div>second</div>", makesTitle: false).markdown == "First\nsecond")
        #expect(HTMLToMarkdown.convert("<div>First</div><div>second</div>").markdown == "# First\nsecond")
    }

    @Test func relativeImagesBecomeMarkdownImages() {
        let html = #"<p>a</p><img src="rel/p.png" alt="A [pic]"><img src="my pic (1).png"><img src="//cdn.example/q.png">"#
            + #"<img src="https://e.com/w.png"><img src="file:///etc/x.png"><img src="cid:abc">"#
        let r = HTMLToMarkdown.convert(html, makesTitle: false, keepsRelativeImages: true)
        #expect(r.markdown == "a\n\n![A \\[pic\\]](rel/p.png)![](my%20pic%20%281%29.png)![](https://e.com/w.png)")
        #expect(r.warnings == ["3 image(s) without embedded data skipped"])
        // Off by default.
        #expect(!HTMLToMarkdown.convert(#"<img src="rel/p.png">"#).markdown.contains("!["))
    }

    @Test func dataImageNamesAvoidLinkedFileNames() {
        let html = #"<img src="a/image.png"><img src="data:image/png;base64,"# + Self.png1 + #"">"#
        let r = HTMLToMarkdown.convert(html, makesTitle: false, keepsRelativeImages: true)
        #expect(r.images.map(\.filename) == ["image 2.png"])
        #expect(r.markdown == "![](a/image.png)![](image%202.png)")
    }

    @Test func appleNotesFixturesUnchanged() {
        for fixture in Self.fixtures {
            let r = HTMLToMarkdown.convert(fixture.html, makesTitle: true, keepsRelativeImages: false)
            #expect(r.markdown == fixture.markdown, "\(fixture.name)")
        }
    }

    @Test func paragraphsAreSeparatedByEmptyLines() {
        #expect(generic("<p>one</p><p>two<br>three</p><h2>H</h2><p>four</p>") == "one\n\ntwo\nthree\n\n## H\nfour")
    }

    @Test func inlineElements() {
        #expect(generic("<p><strong>b</strong> <b>b2</b> <em>i</em> <i>i2</i> <u>u</u> <s>s</s> <del>d</del> <strike>k</strike></p>")
            == "**b** **b2** *i* *i2* ~u~ ~~s~~ ~~d~~ ~~k~~")
        #expect(generic("<p>a <mark>hot</mark> b <code>x = 1</code></p>") == "a ==hot== b `x = 1`")
        #expect(generic(#"<p>see <a href="https://e.com/a b">the page</a></p>"#) == "see [the page](https://e.com/a%20b)")
    }

    @Test func headingsQuotesAndRules() {
        #expect(generic("<h1>One</h1><h3>Three</h3><h6>Six</h6>") == "# One\n### Three\n###### Six")
        #expect(generic("<blockquote><p>quoted</p><p>more</p></blockquote><hr><p>after</p>") == "> quoted\n>\n> more\n---\nafter")
    }

    @Test func preBecomesAFenceWithItsLanguage() {
        #expect(generic(#"<pre><code class="language-swift">let a = 1"# + "\nlet b = 2\n" + #"</code></pre><p>after</p>"#)
            == "```swift\nlet a = 1\nlet b = 2\n```\nafter")
        #expect(generic("<pre>plain &lt;b&gt;\n\nlines</pre>") == "```\nplain <b>\n\nlines\n```")
        // Two blocks stay two fences.
        #expect(generic(#"<pre class="lang-js">a</pre><pre>b</pre>"#) == "```js\na\n```\n```\nb\n```")
        // The info string only takes safe characters.
        #expect(generic(#"<pre><code class="language-a`b">x</code></pre>"#) == "```\nx\n```")
    }

    // MARK: Fix round 1 (M8-R55 extended)

    @Test(arguments: [true, false])
    func deeplyNestedElementsAreFlattenedNotCrashed(generic: Bool) {
        let depth = 100_000
        let html = String(repeating: "<div>", count: depth) + "deep text" + String(repeating: "</div>", count: depth) + "<div>after</div>"
        let r = generic
            ? HTMLToMarkdown.convert(html, makesTitle: false, keepsRelativeImages: true)
            : HTMLToMarkdown.convert(html)
        #expect(r.markdown.contains("deep text"))
        #expect(r.markdown.contains("after"))
        #expect(r.warnings == ["nesting deeper than \(HTMLToMarkdown.maxNesting) levels was flattened"])
        // Ordinary nesting records nothing.
        #expect(HTMLToMarkdown.convert("<div><div><b>x</b></div></div>").warnings.isEmpty)
    }

    @Test func rawTextElementsEndOnlyAtARealCloseTag() {
        #expect(generic("<script>hidden</scriptx>LEAK</script><p>kept</p>") == "kept")
        #expect(generic("<style>a{}</styled>LEAK</style ><p>kept</p>") == "kept")
        #expect(generic("<script>x</script\n><p>kept</p>") == "kept")
        #expect(generic("<script>x</script/><p>kept</p>") == "kept")
        #expect(generic("<script>x</SCRIPT><p>kept</p>") == "kept")
    }

    @Test func genericLinksKeepOnlyWebAndMailTargets() {
        func link(_ href: String) -> String { generic("<p><a href=\"\(href)\">label</a></p>") }
        #expect(link("https://example.com/a") == "[label](https://example.com/a)")
        #expect(link("  HTTP://Example.com ") == "[label](HTTP://Example.com)")
        #expect(link("mailto:a@example.com") == "[label](mailto:a@example.com)")
        for hostile in ["javascript:alert(1)", " JavaScript:x", "file:///etc/passwd", "data:text/html,x", "ftp://example.com",
                        "baerchen://note/1", "bear://x-callback-url/open-note", "../secret.txt", "doc.pdf", "#top", "//cdn.example/x", "http://", "vbscript:x"] {
            #expect(link(hostile) == "label", "\(hostile)")
        }
        // Apple Notes keeps its older behaviour.
        #expect(HTMLToMarkdown.convert("<div><h1>T</h1></div><div><a href=\"doc.pdf\">label</a></div>").markdown == "# T\n[label](doc.pdf)")
    }

    @Test func relativeImagesNeedAnImageExtension() {
        let r = HTMLToMarkdown.convert(
            #"<img src="notes.txt"><img src="a/b.PNG"><img src="noext"><img src="x.png?raw=1"><img src="id_rsa">"#,
            makesTitle: false, keepsRelativeImages: true)
        #expect(r.markdown == "![](a/b.PNG)![](x.png?raw=1)")
        #expect(r.warnings == ["3 image(s) without embedded data skipped"])
    }

    @Test func listsStillWork() {
        #expect(generic("<ul><li>a<ul><li>b</li></ul></li></ul><ol><li>x</li></ol>") == "- a\n\t- b\n1. x")
    }

    /// Escaping must stay linear in a text node's length (security review R17).
    @Test(.tags(.perf)) func testPerfLargeTextNode() {
        let chunk = "a ~ b $ c = d _e_ f~ $g "
        let text = String(repeating: chunk, count: 200_000 / chunk.utf8.count)
        #expect(text.utf8.count > 190_000)
        let clock = ContinuousClock()
        var markdown = ""
        // Best of three: robust against scheduler noise on a loaded machine; a quadratic scan
        // would take seconds here.
        let elapsed = (0..<3).map { _ in
            clock.measure { markdown = HTMLToMarkdown.convert("<div>\(text)</div>").markdown }
        }.min()!
        #expect(elapsed < PerfGate.bound(.milliseconds(200), sanity: .seconds(2)), "\(elapsed)")
        #expect(markdown.hasPrefix("# a ~ b $ c = d \\_e\\_ f\\~ \\$g a ~ b"))
    }

    @Test(.tags(.perf)) func testPerfLargeEmbeddedImage() {
        let big = Data(repeating: 0xAB, count: 4_000_000).base64EncodedString()
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            let result = HTMLToMarkdown.convert("<div><h1>T</h1></div><div><img src=\"data:image/jpeg;base64,\(big)\"/></div>")
            #expect(result.images.first?.data.count == 4_000_000)
            #expect(result.markdown == "# T\n![](image.jpg)")
        }
        #expect(elapsed < PerfGate.bound(.seconds(5), sanity: .seconds(30)))
    }
}
