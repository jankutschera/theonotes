// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { describe, expect, it } from "vitest";
import { renderNote } from "../src/export/note-export";

describe("portable rendered note exports", () => {
  it("renders the full source with Bear inline typography and exact code", () => {
    const result = renderNote("# Heading\n\n**Bold** *italic* ~under~ ~~strike~~ ==highlight== `a < b`\n\n```js\nconst x = '<script>';\n```\n\nlast line");
    expect(result.html).toContain('<h1 id="h-line-1">Heading</h1>');
    for (const tag of ["strong", "em", "u", "s", "mark", "code", "pre"]) expect(result.html).toContain(`<${tag}>`);
    expect(result.html).toContain("&lt;script&gt;");
    expect(result.text).toContain("Bold italic under strike highlight a < b");
    expect(result.text).toContain("const x = '<script>';");
    expect(result.text).toContain("last line");
  });
  it("preserves empty table cells and task state", () => {
    const result = renderNote("| A | B |\n| --- | --- |\n| x | |\n\n- [x] Done\n- [ ] Next");
    expect(result.html).toContain("<th>A</th><th>B</th>");
    expect(result.html).toContain("<td>x</td><td></td>");
    expect(result.html).toContain("Completed");
    expect(result.text).toContain("[x] Done");
    expect(result.text).toContain("[ ] Next");
  });
  it("omits comments, optionally strips tags and resolves wiki aliases", () => {
    const result = renderNote("#project [[Title|Alias]] <!-- hidden --> `#literal`", { keepTags: false, wikiLinks: { Title: "Title.html" } });
    expect(result.text).not.toContain("#project");
    expect(result.text).not.toContain("hidden");
    expect(result.text).toContain("#literal");
    expect(result.html).toContain('<a href="Title.html">Alias</a>');
  });
  it("escapes active HTML, refuses unsafe links and never loads remote images", () => {
    const result = renderNote('<script>alert(1)</script>\n\n[bad](javascript:alert) ![remote](https://example.com/pixel.png) [good](https://example.com)');
    expect(result.html).not.toContain("<script>");
    expect(result.html).not.toContain('href="javascript:');
    expect(result.html).not.toContain('<img');
    expect(result.html).toContain('<a href="https://example.com">good</a>');
    const embedded = renderNote('![local](photo%20one.png)', { attachments: { "photo one.png": "data:image/png;base64,YQ==" } });
    expect(embedded.html).toContain('<img src="data:image/png;base64,YQ==" alt="local">');
  });
  it("renders callout titles and footnote links without changing code", () => {
    const result = renderNote("> [!WARNING] Be careful\n> **body**\n\nA reference[^x] and `[^x]`.\n\n[^x]: Details with **bold**.");
    expect(result.html).toContain('class="callout callout-warning"');
    expect(result.html).not.toContain("[!WARNING]");
    expect(result.html).toContain('<strong>body</strong>');
    expect(result.html).toContain('href="#fn-x"');
    expect(result.html).toContain('id="fn-x"');
    expect(result.html).toContain('<code>[^x]</code>');
    expect(result.html).toContain('<strong>bold</strong>');
    expect(result.html).toContain('aria-label="Back to reference"');
    expect(renderNote("> [!Unknown]\n> body").html).toContain('<strong>Note</strong>');
  });

  it("gives headings source-line anchors and preserves per-heading manifest targets", () => {
    const result = renderNote("# Title\n\n## Section\n\n[[Other]] [[Other/Section]] [[/Section]]", {
      wikiLinks: { Other: "../Other.html", "Other/Section": "../Other.html#h-line-3", "/Section": "#h-line-3" },
    });
    expect(result.html).toContain('<h2 id="h-line-3">Section</h2>');
    expect(result.html).toContain('href="../Other.html">Other</a>');
    expect(result.html).toContain('href="../Other.html#h-line-3">Other/Section</a>');
    expect(result.html).toContain('href="#h-line-3">/Section</a>');
  });

  it("allows parent paths only in the supplied export manifest", () => {
    expect(renderNote("[[Target]]", { wikiLinks: { Target: "../Other/Target.html" } }).html).toContain('href="../Other/Target.html"');
    expect(renderNote("[outside](../Other/Target.html)").html).not.toContain('href=');
    for (const path of ["../javascript:alert", "..//evil.example", "../%2e%2e/private", "../a\\b"]) {
      expect(renderNote("[[Target]]", { wikiLinks: { Target: path } }).html).not.toContain('href=');
    }
  });

});
