// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { describe, expect, test, vi } from "vitest";
import { type BlockRenderers, escapeHTML, type RenderInput, renderBody, safeHref } from "../src/export/render";
import { highlightCode } from "../src/export/highlight";
import { wikiLinksInDocument } from "../src/editor/conformance";
import { MAX_TEX } from "../src/editor/features/math-render";
import { MAX_GRID_ROWS } from "../src/editor/features/tables";

async function body(text: string, extra: Partial<RenderInput> = {}, renderers?: BlockRenderers): Promise<string> {
  return (await renderBody({ text, mode: "document", attachmentSources: {}, wikiLinks: [], ...extra }, renderers)).body;
}

describe("escapeHTML and safeHref", () => {
  test("escapeHTML escapes the five HTML metacharacters", () => {
    expect(escapeHTML(`<a href="x" title='y'>&</a>`)).toBe("&lt;a href=&quot;x&quot; title=&#39;y&#39;&gt;&amp;&lt;/a&gt;");
  });

  test("safeHref allows http, https, mailto, baerchen and bear only", () => {
    expect(safeHref(" https://example.com/a?b=1 ")).toBe("https://example.com/a?b=1");
    expect(safeHref("HTTP://example.com")).toBe("HTTP://example.com");
    expect(safeHref("mailto:a@b.c")).toBe("mailto:a@b.c");
    expect(safeHref("theonotes://x-callback-url/open-note?id=1")).toBe("theonotes://x-callback-url/open-note?id=1");
    expect(safeHref("baerchen://x-callback-url/open-note?id=1")).toBe("baerchen://x-callback-url/open-note?id=1");
    expect(safeHref("bear://x-callback-url/open-note?id=1")).toBe("bear://x-callback-url/open-note?id=1");
    for (const bad of ["javascript:alert(1)", " JavaScript:alert(1)", "file:///etc/passwd", "data:text/html,<b>", "vbscript:x", "relative/path.png", "#h-1", "", "java\tscript:alert(1)", "https://a\u0000b", "https://a\u007fb", "https://a\nb"]) {
      expect(safeHref(bad), bad).toBeNull();
    }
  });
});

describe("renderBody (document mode)", () => {
  test("headings get h-n ids in document order and skip empty ones", async () => {
    const result = await renderBody({
      text: "# One\n#\n## Two **b**\n> # Quoted\n### #tag\n#### Four",
      mode: "document",
      attachmentSources: {},
      wikiLinks: [],
    });
    expect(result.body).toBe(
      '<h1 id="h-1">One</h1>\n' +
        '<h2 id="h-2">Two <strong>b</strong></h2>\n' +
        "<blockquote>\n<h1>Quoted</h1>\n</blockquote>\n" +
        '<h3><span class="bc-tag">#tag</span></h3>\n' +
        '<h4 id="h-3">Four</h4>\n',
    );
    expect(result.headings).toEqual([
      { level: 1, text: "One", anchor: "h-1" },
      { level: 2, text: "Two b", anchor: "h-2" },
      { level: 4, text: "Four", anchor: "h-3" },
    ]);
  });

  test("inline styles: bold, italic, underline, strike, code, five highlight colours", async () => {
    expect(await body("**b** *i* ~u~ ~~s~~ `c<` ==h== ==🟢g== ==🔴r== ==🔵b== ==🟡y== ==🟣p== a\\*b")).toBe(
      "<p><strong>b</strong> <em>i</em> <u>u</u> <s>s</s> <code>c&lt;</code> " +
        '<mark class="bc-hl">h</mark> <mark class="bc-hl bc-hl-green">g</mark> <mark class="bc-hl bc-hl-red">r</mark> ' +
        '<mark class="bc-hl bc-hl-blue">b</mark> <mark class="bc-hl bc-hl-yellow">y</mark> <mark class="bc-hl bc-hl-purple">p</mark> a*b</p>\n',
    );
    expect(await body("line one\nline two")).toBe("<p>line one<br>\nline two</p>\n");
    expect(await body("[site](https://example.com) <https://a.b> https://bare.example")).toBe(
      '<p><a href="https://example.com">site</a> <a href="https://a.b">https://a.b</a> <a href="https://bare.example">https://bare.example</a></p>\n',
    );
  });

  test("tags render as spans and keep their text", async () => {
    expect(await body("#tag and #multi word# here #a/b")).toBe(
      '<p><span class="bc-tag">#tag</span> and <span class="bc-tag">#multi word#</span> here <span class="bc-tag">#a/b</span></p>\n',
    );
  });

  test("wiki links use the given href or render as text", async () => {
    const text = "`[[code]]` [[One]] [[Two|Alias]] [[Three/Head]] [[Four]]";
    // `wikiLinks[i]` is the i-th entry of wikiLinksInDocument (the code span holds none).
    expect(wikiLinksInDocument(text).map((w) => w.target)).toEqual(["One", "Two", "Three", "Four"]);
    expect(
      await body(text, { wikiLinks: [{ href: "One.html" }, null, { href: "javascript:alert(1)" }, { href: "Four%20note.html#h-2" }] }),
    ).toBe(
      '<p><code>[[code]]</code> <a class="bc-wikilink" href="One.html">One</a> <span class="bc-wikilink">Alias</span> ' +
        '<span class="bc-wikilink">Three/Head</span> <a class="bc-wikilink" href="Four%20note.html#h-2">Four</a></p>\n',
    );
  });

  test("todos render disabled checkboxes, checked for [x] and [X]", async () => {
    expect(await body("- [ ] open\n- [x] done\n- [X] Done\n- plain\n\n1. first\n3. third")).toBe(
      "<ul>\n" +
        '<li class="bc-todo"><input type="checkbox" disabled> open</li>\n' +
        '<li class="bc-todo"><input type="checkbox" disabled checked> done</li>\n' +
        '<li class="bc-todo"><input type="checkbox" disabled checked> Done</li>\n' +
        "<li>plain</li>\n" +
        "</ul>\n" +
        "<ol>\n<li>first</li>\n<li>third</li>\n</ol>\n",
    );
    expect(await body("3. a\n4. b\n   - nested")).toBe("<ol start=\"3\">\n<li>a</li>\n<li>b\n<ul>\n<li>nested</li>\n</ul>\n</li>\n</ol>\n");
  });

  test("callouts: five types, custom title, unknown type renders as note", async () => {
    const text = [
      "> [!NOTE]\n> n",
      "> [!TIP] My *tip*",
      "> [!IMPORTANT]",
      "> [!WARNING]\n> w",
      "> [!caution]\n> c",
      "> [!FOO]\n> f",
      "> plain",
    ].join("\n\n");
    const aside = (type: string, title: string, inner = "") =>
      `<aside class="bc-callout bc-callout-${type}">\n<p class="bc-callout-title">${title}</p>\n${inner}</aside>\n`;
    expect(await body(text)).toBe(
      aside("note", "Note", "<p>n</p>\n") +
        aside("tip", "My <em>tip</em>") +
        aside("important", "Important") +
        aside("warning", "Warning", "<p>w</p>\n") +
        aside("caution", "Caution", "<p>c</p>\n") +
        aside("note", "Note", "<p>f</p>\n") +
        "<blockquote>\n<p>plain</p>\n</blockquote>\n",
    );
  });

  test("tables keep alignment and inline markup in cells", async () => {
    const text = "| a | **b** | c | d |\n|:-|:-:|--:|---|\n| *x* | 2<br>3 | | [l](https://e.x) |";
    expect(await body(text)).toBe(
      "<table>\n<thead>\n" +
        '<tr><th style="text-align:left">a</th><th style="text-align:center"><strong>b</strong></th><th style="text-align:right">c</th><th>d</th></tr>\n' +
        "</thead>\n<tbody>\n" +
        '<tr><td style="text-align:left"><em>x</em></td><td style="text-align:center">2<br>3</td><td style="text-align:right"></td><td><a href="https://e.x">l</a></td></tr>\n' +
        "</tbody>\n</table>\n",
    );
  });

  test("footnotes: refs, definitions section, back links", async () => {
    const text = "Text[^1] and[^n], again[^1].\n\n[^1]: First *one*\n[^n]: Named";
    expect(await body(text)).toBe(
      '<p>Text<sup class="bc-fn-ref"><a href="#fn-1" id="fnref-1">1</a></sup> and' +
        '<sup class="bc-fn-ref"><a href="#fn-n" id="fnref-n">n</a></sup>, again' +
        '<sup class="bc-fn-ref"><a href="#fn-1" id="fnref-1-2">1</a></sup>.</p>\n' +
        '<section class="bc-footnotes">\n<ol>\n' +
        '<li id="fn-1" value="1">First <em>one</em> <a class="bc-fn-back" href="#fnref-1">↩</a></li>\n' +
        '<li id="fn-n">Named <a class="bc-fn-back" href="#fnref-n">↩</a></li>\n' +
        "</ol>\n</section>\n",
    );
  });

  test("fenced code is highlighted for a known language and plain otherwise", async () => {
    const text = '```js\nlet a = "<";\n```\n\n```nope\n<b>\n```\n\n```\nplain\n```';
    expect(await body(text)).toBe(
      '<pre class="bc-code"><code><span class="tok-keyword">let</span> <span class="tok-variableName tok-definition">a</span> ' +
        '<span class="tok-operator">=</span> <span class="tok-string">&quot;&lt;&quot;</span><span class="tok-punctuation">;</span></code></pre>\n' +
        '<pre class="bc-code"><code>&lt;b&gt;</code></pre>\n' +
        '<pre class="bc-code"><code>plain</code></pre>\n',
    );
  });

  test("math and mermaid fall back to source without renderers", async () => {
    const text = "Inline $x^2$ here\n\n$$\n\\frac{a}{b}\n$$\n\n```mermaid\ngraph TD; A-->B\n```";
    expect(await body(text)).toBe(
      '<p>Inline <code class="bc-math-source">$x^2$</code> here</p>\n' +
        '<pre class="bc-math-source"><code>$$\n\\frac{a}{b}\n$$</code></pre>\n' +
        '<pre class="bc-mermaid-source"><code>graph TD; A--&gt;B</code></pre>\n',
    );
  });

  test("math and mermaid use the renderers, and show the source with an error line when one fails", async () => {
    const text = "Inline $x^2$ and $bad$\n\n$$\n\\frac{a}{b}\n$$\n\n```mermaid\ngraph TD; A-->B\n```\n\n```mermaid\nbroken\n```";
    const renderers: BlockRenderers = {
      math: async (tex, display) => (tex === "bad" ? null : `<svg data-tex="${tex.length}" data-display="${display}"></svg>`),
      mermaid: async (source) => (source === "broken" ? null : '<svg viewBox="0 0 1 1"></svg>'),
    };
    expect(await body(text, {}, renderers)).toBe(
      '<p>Inline <span class="bc-math"><svg data-tex="3" data-display="false"></svg></span> and ' +
        '<code class="bc-math-source">$bad$</code><span class="bc-render-error">The formula could not be rendered</span></p>\n' +
        '<div class="bc-math bc-math-display"><svg data-tex="11" data-display="true"></svg></div>\n' +
        `<figure class="bc-mermaid"><img alt="" src="data:image/svg+xml;charset=utf-8,${encodeURIComponent('<svg viewBox="0 0 1 1"></svg>')}"></figure>\n` +
        '<pre class="bc-mermaid-source"><code>broken</code></pre>\n<p class="bc-render-error">The diagram could not be rendered</p>\n',
    );
  });

  test("images honour width metadata; PDFs and files render as cards; missing files are marked", async () => {
    const text = [
      '![](photo%201.png)<!-- {"width":"200"} -->',
      "![](gone.png)",
      '[doc.pdf](doc.pdf)<!-- {"preview":"true","embed":"true"} -->',
      '[a.zip](a.zip)<!-- {"embed":"true"} -->',
      "![remote](http://example.com/x.png)",
    ].join("\n");
    const attachmentSources = { "photo 1.png": "Note/photo%201.png", "doc.pdf": "Note/doc.pdf", "a.zip": "Note/a.zip" };
    expect(await body(text, { attachmentSources })).toBe(
      '<p><img src="Note/photo%201.png" alt="photo 1.png" width="200"><br>\n' +
        '<a class="bc-file bc-missing"><span class="bc-file-name">gone.png</span><span class="bc-file-kind">PNG</span></a><br>\n' +
        '<a class="bc-file bc-file-pdf" href="Note/doc.pdf"><span class="bc-file-name">doc.pdf</span><span class="bc-file-kind">PDF</span></a><br>\n' +
        '<a class="bc-file" href="Note/a.zip"><span class="bc-file-name">a.zip</span><span class="bc-file-kind">ZIP</span></a><br>\n' +
        '<a href="http://example.com/x.png">remote</a></p>\n',
    );
  });

  test("file cards show name and size when the size is known", async () => {
    const text = '[doc.pdf](doc.pdf)<!-- {"embed":"true"} -->\n[a.zip](a.zip)<!-- {"embed":"true"} -->\n[gone.txt](gone.txt)<!-- {"embed":"true"} -->\n[n.bin](n.bin)<!-- {"embed":"true"} -->';
    const attachmentSources = { "doc.pdf": "Note/doc.pdf", "a.zip": "Note/a.zip", "n.bin": "Note/n.bin" };
    const attachmentSizes = { "doc.pdf": 1_258_291, "a.zip": 512, "gone.txt": 2048, "n.bin": Number.NaN };
    expect(await body(text, { attachmentSources, attachmentSizes })).toBe(
      '<p><a class="bc-file bc-file-pdf" href="Note/doc.pdf"><span class="bc-file-name">doc.pdf</span><span class="bc-file-kind">PDF</span><span class="bc-file-size">1.2 MB</span></a><br>\n' +
        '<a class="bc-file" href="Note/a.zip"><span class="bc-file-name">a.zip</span><span class="bc-file-kind">ZIP</span><span class="bc-file-size">512 bytes</span></a><br>\n' +
        '<a class="bc-file bc-missing"><span class="bc-file-name">gone.txt</span><span class="bc-file-kind">TXT</span><span class="bc-file-size">2 KB</span></a><br>\n' +
        '<a class="bc-file" href="Note/n.bin"><span class="bc-file-name">n.bin</span><span class="bc-file-kind">BIN</span></a></p>\n',
    );
  });

  test("front matter and comments are omitted", async () => {
    const text = "---\ntitle: x\n---\nA <!-- c --> B\n\n<!--\nhidden\n-->\nafter\n\n<!--\ngone\n--> tail\n\n***";
    expect(await body(text)).toBe("<p>A  B</p>\n<p>after</p>\n<p>tail</p>\n<hr>\n");
  });
});

describe("renderBody (rich text mode)", () => {
  test("rich text mode: no theme classes, ☐/☑, TeX as code, images as [filename]", async () => {
    const text = [
      "# Head",
      "- [ ] a\n- [x] b",
      "==hi== ==🔴r== #tag $x^2$ ![](p.png) [[W]] `c`",
      "> [!TIP]\n> t",
      "$$\nx\n$$",
      "```js\nlet a\n```",
      "```mermaid\ngraph TD\n```",
      "| a |\n|---|\n| b |",
      "x[^1]\n\n[^1]: d",
    ].join("\n\n");
    const result = await renderBody({ text, mode: "richText", attachmentSources: { "p.png": "data:image/png;base64,AA==" }, wikiLinks: [null] });
    const html = result.body;
    expect(html).not.toContain("class=");
    expect(html).not.toContain("<input");
    expect(html).not.toContain("<img");
    expect(html).not.toContain("<svg");
    expect(html).toContain("<h1>Head</h1>");
    expect(html).toContain("<li>☐ a</li>");
    expect(html).toContain("<li>☑ b</li>");
    expect(html).toContain('<span style="background-color:#ffeaa0">hi</span>');
    expect(html).toContain('<span style="background-color:#ffddda">r</span>');
    expect(html).toContain("#tag");
    expect(html).toContain("<code>$x^2$</code>");
    expect(html).toContain("[p.png]");
    expect(html).toContain("<pre><code>$$\nx\n$$</code></pre>");
    expect(html).toContain("<pre><code>let a</code></pre>");
    expect(html).toContain("<pre><code>graph TD</code></pre>");
    expect(html).toContain("<blockquote>\n<p><strong>Tip</strong></p>\n<p>t</p>\n</blockquote>");
    expect(html).toContain("<sup>1</sup>");
  });
});

describe("renderBody security and limits", () => {
  test("raw HTML, unsafe links and style breakouts stay inert", async () => {
    const text = [
      "<script>alert(1)</script>",
      "<img src=x onerror=alert(1)>",
      "[a](javascript:alert(1)) [b](file:///etc/passwd) <javascript:alert(2)> file:///etc/hosts",
      '![x](javascript:alert(3)) [[W]] [c](<https://ok.example/" onclick="x>)',
      "```css\n</style><script>alert(4)</script>\n```",
      "`</style>` &lt;script&gt;",
      "| <script>x</script> |\n|---|\n| </style> |",
      "> [!NOTE] <img src=x onerror=alert(5)>",
      "x[^<b>]\n\n[^<b>]: <script>y</script>",
      "$$\n</style><script>z</script>\n$$",
    ].join("\n\n");
    for (const mode of ["document", "richText"] as const) {
      const { body: html } = await renderBody({ text, mode, attachmentSources: {}, wikiLinks: [{ href: "javascript:alert(6)" }] });
      expect(html).not.toMatch(/<script/i);
      expect(html).not.toMatch(/<img/i);
      // The brief's literal "no `onerror=`" cannot hold: escaped raw HTML keeps that text, inert.
      // So: no element carries an event handler (attribute values blanked first: escaped text
      // inside an href is inert).
      for (const tag of html.match(/<[a-z][^>]*>/gi) ?? []) expect(tag.replace(/"[^"]*"/g, '""'), tag).not.toMatch(/\son[a-z]+\s*=/i);
      expect(html).not.toMatch(/href="javascript:/i);
      expect(html).not.toMatch(/href="file:/i);
      expect(html).not.toMatch(/<\/style>/i);
      expect(html).toContain("&lt;script&gt;alert(1)&lt;/script&gt;");
      expect(html).toContain("&amp;lt;script&amp;gt;");
    }
  });

  test("limits: a 1,001-row table renders as a table without grid extras; TeX over MAX_TEX shows the source with an error line", async () => {
    const rows = Array.from({ length: MAX_GRID_ROWS }, (_, i) => `| **b${i}** | [l](https://e.x) |`);
    const big = await body(["| h | i |", "|---|---|", ...rows].join("\n"));
    expect(big.startsWith("<table>\n<thead>\n")).toBe(true);
    expect(big.match(/<tr>/g)?.length).toBe(MAX_GRID_ROWS + 1);
    expect(big).toContain("<tr><td>b0</td><td>l</td></tr>");
    expect(big).not.toContain("<strong>");
    expect(big).not.toContain("<a ");
    const small = await body(["| h | i |", "|---|---|", ...rows.slice(0, MAX_GRID_ROWS - 1)].join("\n"));
    expect(small).toContain('<tr><td><strong>b0</strong></td><td><a href="https://e.x">l</a></td></tr>');

    const tex = "x".repeat(MAX_TEX + 1);
    const math = vi.fn(async () => "<svg></svg>");
    for (const renderers of [undefined, { math }]) {
      expect(await body(`$$\n${tex}\n$$\n\nInline $${tex}$`, {}, renderers)).toBe(
        `<pre class="bc-math-source"><code>$$\n${tex}\n$$</code></pre>\n` +
          `<p class="bc-render-error">Formula too long (${MAX_TEX + 1} characters, at most ${MAX_TEX})</p>\n` +
          `<p>Inline <code class="bc-math-source">$${tex}$</code><span class="bc-render-error">Formula too long (${MAX_TEX + 1} characters, at most ${MAX_TEX})</span></p>\n`,
      );
    }
    expect(math).not.toHaveBeenCalled();
  });

  test("limits: comments in the cells of a table over the cap are omitted", async () => {
    const rows = Array.from({ length: MAX_GRID_ROWS }, (_, i) => `| a${i}<!--secret--> | <!-- {"x":"y"} -->b |`);
    const big = await body(["| h<!--hidden--> | i |", "|---|---|", ...rows].join("\n"));
    expect(big.match(/<tr>/g)?.length).toBe(MAX_GRID_ROWS + 1);
    expect(big).toContain("<tr><th>h</th><th>i</th></tr>");
    expect(big).toContain("<tr><td>a0</td><td>b</td></tr>");
    expect(big).not.toContain("secret");
    expect(big).not.toContain("hidden");
    expect(big).not.toContain("--");
  });

  test("attachment sources outside the allowlist render as placeholder cards", async () => {
    const text = "![](a.png)\n![](b.png)\n[c.pdf](c.pdf)<!-- {\"embed\":\"true\"} -->\n![](d.png)\n![](e.png)\n![](f.svg)\n![](g.png)\n![](h.png)\n![](i.png)\n![](j.png)";
    const attachmentSources = {
      "a.png": "https://attacker.example/pixel",
      "b.png": "javascript:alert(1)",
      "c.pdf": "//attacker.example/c.pdf",
      "d.png": "/etc/d.png",
      "e.png": "data:image/png;base64,iVBORw0KGgo=",
      "f.svg": "data:image/svg+xml;base64,PHN2Zz4=",
      "g.png": "baerchen-asset://attachment/n/g.png",
      "h.png": "Note/h%20x.png",
      "i.png": "data:text/html;base64,PGI+",
      // A URL parser strips leading blanks: " https://…" would load.
      "j.png": " https://attacker.example/blank",
    };
    for (const mode of ["document", "richText"] as const) {
      const { body: html } = await renderBody({ text, mode, attachmentSources, wikiLinks: [] });
      expect(html).not.toContain("attacker");
      expect(html).not.toContain("javascript:");
      expect(html).not.toContain("/etc/");
      expect(html).not.toContain("svg+xml");
      expect(html).not.toContain("text/html");
    }
    const html = await body(text, { attachmentSources });
    const missing = (name: string, kind: string) =>
      `<a class="bc-file bc-missing"><span class="bc-file-name">${name}</span><span class="bc-file-kind">${kind}</span></a>`;
    expect(html).toBe(
      `<p>${missing("a.png", "PNG")}<br>\n${missing("b.png", "PNG")}<br>\n` +
        '<a class="bc-file bc-file-pdf bc-missing"><span class="bc-file-name">c.pdf</span><span class="bc-file-kind">PDF</span></a><br>\n' +
        `${missing("d.png", "PNG")}<br>\n` +
        '<img src="data:image/png;base64,iVBORw0KGgo=" alt="e.png"><br>\n' +
        `${missing("f.svg", "SVG")}<br>\n` +
        '<img src="baerchen-asset://attachment/n/g.png" alt="g.png"><br>\n' +
        '<img src="Note/h%20x.png" alt="h.png"><br>\n' +
        `${missing("i.png", "PNG")}<br>\n${missing("j.png", "PNG")}</p>\n`,
    );
  });

  test("network-path URLs (//host) are not links", async () => {
    expect(await body("[a](//evil.example/x) [[W]] [[V]]", { wikiLinks: [{ href: "//evil.example/w" }, { href: "\\\\evil.example\\v" }] })).toBe(
      '<p>a <span class="bc-wikilink">W</span> <span class="bc-wikilink">V</span></p>\n',
    );
  });

  test("highlightCode: escaped tokens for a known language, escaped text otherwise", async () => {
    expect(await highlightCode("a</style>", "nope")).toBe("a&lt;/style&gt;");
    expect(await highlightCode("<b>", "text")).toBe("&lt;b&gt;");
    expect(await highlightCode('"</style>"', "js")).toBe('<span class="tok-string">&quot;&lt;/style&gt;&quot;</span>');
    expect(await highlightCode("let a".repeat(10_000), "js")).toBe("let a".repeat(10_000));
  });

  test("perf: 500k-character note renders under 3 s", async () => {
    const unit = [
      "# Heading **bold** #tag",
      "Some *text* with ==highlight== and [[Link]] and [a](https://e.x) and `code` and $x$.[^1]",
      "- [ ] todo item",
      "- [x] done item",
      "> [!TIP] Title",
      "> body line",
      "| a | b |",
      "|---|:-:|",
      "| *x* | y |",
      "```js",
      "const x = 1;",
      "```",
      "[^1]: Footnote",
      "",
    ].join("\n");
    const text = unit.repeat(Math.ceil(500_000 / unit.length));
    expect(text.length).toBeGreaterThanOrEqual(500_000);
    const start = performance.now();
    const result = await renderBody({ text, mode: "document", attachmentSources: {}, wikiLinks: [] });
    const elapsed = performance.now() - start;
    expect(result.headings.length).toBe(Math.ceil(500_000 / unit.length));
    expect(elapsed).toBeLessThan(3000);
  });
});
