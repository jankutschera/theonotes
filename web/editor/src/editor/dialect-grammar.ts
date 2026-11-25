// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

// 1:1 ports of the Swift dialect scanners (Packages/TheoNotesCore/Sources/TheoNotesCore/Parse:
// Chars, InlineScanner, TagScanner, WikiLinkParser, LinkDestination, NoteParser.Fence/LineShape)
// and Text/CanonicalKey. Swift works on Unicode scalars, these work on UTF-16 code units and
// take character classes from the full code point where non-ASCII matters. Keep both in sync:
// Fixtures/dialect/*.json is the shared truth.

const WHITE_SPACE = /\p{White_Space}/u;
const PUNCTUATION = /\p{P}/u;
const ALNUM = /[\p{Alphabetic}\p{N}]/u;

/** The code point starting at `i` (a lone surrogate is returned as is). */
export function codePointAt(s: string, i: number): number {
  const c = s.charCodeAt(i);
  if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length) {
    const d = s.charCodeAt(i + 1);
    if (d >= 0xdc00 && d <= 0xdfff) return (c - 0xd800) * 0x400 + (d - 0xdc00) + 0x10000;
  }
  return c;
}

// MARK: Chars

export function isSpace(c: number): boolean {
  if (c < 128) return c === 32 || (c >= 9 && c <= 13);
  return WHITE_SPACE.test(String.fromCodePoint(c));
}
export const isBlank = (c: number) => c === 32 || c === 9;
export const isDigit = (c: number) => c >= 48 && c <= 57;
export const isASCIILetter = (c: number) => (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
export function isAlnum(c: number): boolean {
  if (c < 128) return isASCIILetter(c) || isDigit(c);
  return ALNUM.test(String.fromCodePoint(c));
}
export const isASCIIPunct = (c: number) =>
  (c >= 0x21 && c <= 0x2f) || (c >= 0x3a && c <= 0x40) || (c >= 0x5b && c <= 0x60) || (c >= 0x7b && c <= 0x7e);
export const isSchemeChar = (c: number) => isASCIILetter(c) || isDigit(c) || c === 43 || c === 46 || c === 45;
export const isNonASCIIPunct = (c: number) => c >= 128 && PUNCTUATION.test(String.fromCodePoint(c));
const spaceAt = (s: string, i: number) => isSpace(codePointAt(s, i));

/** Collapses whitespace runs to one space and trims. */
export function collapse(s: string): string {
  return s.replace(/\p{White_Space}+/gu, " ").replace(/^ | $/g, "");
}

export function trimmedEnd(s: string): number {
  let end = s.length;
  while (end > 0 && isSpace(s.charCodeAt(end - 1))) end--;
  return end;
}

/** Whole line equals `value` after trimming whitespace. */
export function trimmedEquals(line: string, value: string): boolean {
  let lo = 0;
  let hi = line.length;
  while (lo < hi && isSpace(line.charCodeAt(lo))) lo++;
  while (hi > lo && isSpace(line.charCodeAt(hi - 1))) hi--;
  return line.slice(lo, hi) === value;
}

export const isMathFence = (line: string) => trimmedEquals(line, "$$");

/** `NFC(fold(NFC(s)))` with full Unicode case folding (CanonicalKey.swift). */
export function canonicalKey(s: string): string {
  return s.normalize("NFC").toUpperCase().toLowerCase().normalize("NFC");
}

// MARK: InlineScanner

export type InlineSpanKind =
  | "escape"
  | "code"
  | "math"
  | "comment"
  | "autolink"
  | "url"
  | "wikiLink"
  | "linkOpen"
  | "linkClose";

export interface InlineSpan {
  from: number;
  to: number;
  kind: InlineSpanKind;
  /** code / math / autolink content. */
  contentFrom?: number;
  contentTo?: number;
  /** linkOpen of images and attachments: the whole link is hidden from text. */
  dropUntil?: number;
  wiki?: WikiLink;
}

/**
 * An image or file attachment link (InlineScanner.swift `attachments`): a relative destination,
 * and for a non-image link a `<!-- {…} -->` metadata comment after it (blanks allowed).
 */
export interface AttachmentSpan {
  /** `!` or `[` … the end of the metadata comment (or of the link without one). */
  from: number;
  to: number;
  /** End of `(…)`. */
  linkEnd: number;
  /** Percent-decoded destination. */
  filename: string;
  isImage: boolean;
  /** The comment's values, stringified (`{}` without a readable comment). */
  metadata: Record<string, string>;
}

export interface InlineScan {
  /** Sorted by start. */
  spans: InlineSpan[];
  /** Attachment links, in order. */
  attachments: AttachmentSpan[];
  /** 1 where tags and emphasis must not be recognized. */
  mask: Uint8Array;
  /** The line ends inside an unclosed `<!--` that continues on a later line. */
  endsInComment: boolean;
}

class BacktickRuns {
  private readonly startsByLength = new Map<number, number[]>();
  private readonly cursor = new Map<number, number>();

  constructor(s: string) {
    let i = 0;
    while (i < s.length) {
      if (s.charCodeAt(i) !== 96) {
        i++;
        continue;
      }
      let j = i;
      while (j < s.length && s.charCodeAt(j) === 96) j++;
      const list = this.startsByLength.get(j - i);
      if (list) list.push(i);
      else this.startsByLength.set(j - i, [i]);
      i = j;
    }
  }

  closer(length: number, from: number): number | null {
    const starts = this.startsByLength.get(length);
    if (!starts) return null;
    let k = this.cursor.get(length) ?? 0;
    while (k < starts.length && starts[k]! < from) k++;
    this.cursor.set(length, k);
    return k < starts.length ? starts[k]! : null;
  }
}

/** `? ! . , : * _ ~`: trailing punctuation that ends a sentence, not the URL (GFM autolinks). */
const URL_TRAILING = new Set([63, 33, 46, 44, 58, 42, 95, 126]);

/**
 * Where a bare URL running from `bodyFrom` (after `://`) to `to` really ends (M6-R43, GFM's
 * extended autolink rule): trailing `? ! . , : * _ ~` are dropped, and a trailing `)` only while
 * the URL has more `)` than `(`. Never before `bodyFrom`.
 */
export function urlEnd(s: string, bodyFrom: number, to: number): number {
  let open = 0;
  let close = 0;
  for (let i = bodyFrom; i < to; i++) {
    const c = s.charCodeAt(i);
    if (c === 40) open++;
    else if (c === 41) close++;
  }
  let end = to;
  while (end > bodyFrom) {
    const c = s.charCodeAt(end - 1);
    if (URL_TRAILING.has(c)) end--;
    else if (c === 41 && close > open) {
      end--;
      close--;
    } else break;
  }
  return end;
}

/**
 * Inline pass over one prose line: escapes, code spans, math, HTML comments, autolinks, bare
 * URLs, wiki links and links/images, left to right. Linear in the line length.
 */
export function scanInline(s: string, startsInComment = false, commentMayContinue = false): InlineScan {
  const n = s.length;
  const spans: InlineSpan[] = [];
  const attachments: AttachmentSpan[] = [];
  let endsInComment = false;
  let p = 0;
  let floor = 0;
  const brackets: { pos: number; isImage: boolean }[] = [];
  const ticks = new BacktickRuns(s);
  let noSingleDollarCloser = false;
  let noDoubleDollarCloser = false;
  let noCommentCloseInLine = false;
  const ch = (i: number) => s.charCodeAt(i);

  const add = (span: InlineSpan) => {
    spans.push(span);
    floor = Math.max(floor, span.to);
  };

  const escape = () => {
    if (p + 1 < n && isASCIIPunct(ch(p + 1))) {
      add({ from: p, to: p + 2, kind: "escape" });
      p += 2;
    } else p += 1;
  };

  const codeSpan = () => {
    let len = 0;
    while (p + len < n && ch(p + len) === 96) len++;
    const close = ticks.closer(len, p + len);
    if (close !== null) {
      add({ from: p, to: close + len, kind: "code", contentFrom: p + len, contentTo: close });
      p = close + len;
    } else p += len;
  };

  const math = () => {
    if (p + 1 < n && ch(p + 1) === 36) {
      const close = noDoubleDollarCloser ? -1 : s.indexOf("$$", p + 2);
      if (close > p + 2) {
        add({ from: p, to: close + 2, kind: "math", contentFrom: p + 2, contentTo: close });
        p = close + 2;
      } else {
        noDoubleDollarCloser = true;
        p += 2;
      }
      return;
    }
    if (!(p + 1 < n) || spaceAt(s, p + 1) || noSingleDollarCloser) {
      p += 1;
      return;
    }
    for (let q = p + 2; q < n; q++) {
      if (
        ch(q) === 36 &&
        !isSpace(ch(q - 1)) &&
        ch(q - 1) !== 92 &&
        (q + 1 === n || (!isDigit(ch(q + 1)) && ch(q + 1) !== 36))
      ) {
        add({ from: p, to: q + 1, kind: "math", contentFrom: p + 1, contentTo: q });
        p = q + 1;
        return;
      }
    }
    noSingleDollarCloser = true;
    p += 1;
  };

  const angle = () => {
    if (p + 3 < n && ch(p + 1) === 33 && ch(p + 2) === 45 && ch(p + 3) === 45) {
      const close = noCommentCloseInLine ? -1 : s.indexOf("-->", p + 4);
      if (close >= 0) {
        add({ from: p, to: close + 3, kind: "comment" });
        p = close + 3;
        return;
      }
      noCommentCloseInLine = true;
      if (commentMayContinue) {
        add({ from: p, to: n, kind: "comment" });
        endsInComment = true;
        p = n;
      } else p += 1;
      return;
    }
    // Autolink `<scheme:…>`.
    let q = p + 1;
    while (q < n && isSchemeChar(ch(q))) q++;
    const schemeLength = q - p - 1;
    if (!(schemeLength >= 2 && schemeLength <= 32 && isASCIILetter(ch(p + 1)) && q < n && ch(q) === 58)) {
      p += 1;
      return;
    }
    while (q < n && ch(q) !== 62 && ch(q) !== 60 && !spaceAt(s, q)) q++;
    if (!(q < n && ch(q) === 62)) {
      p += 1;
      return;
    }
    add({ from: p, to: q + 1, kind: "autolink", contentFrom: p + 1, contentTo: q });
    p = q + 1;
  };

  /** A bare `scheme://…` token (ends at whitespace, `<`, `>`, `"` or `]`). */
  const bareURL = () => {
    if (!(p + 2 < n && ch(p + 1) === 47 && ch(p + 2) === 47 && p > floor && isSchemeChar(ch(p - 1)))) {
      p += 1;
      return;
    }
    let start = p;
    while (start > floor && isSchemeChar(ch(start - 1))) start--;
    while (start < p && !isASCIILetter(ch(start))) start++;
    if (!(start < p)) {
      p += 1;
      return;
    }
    let q = p + 3;
    while (q < n) {
      const c = ch(q);
      if (spaceAt(s, q) || c === 60 || c === 62 || c === 34 || c === 93) break;
      q++;
    }
    q = urlEnd(s, p + 3, q);
    add({ from: start, to: q, kind: "url" });
    p = q;
  };

  const bang = () => {
    if (p + 1 < n && ch(p + 1) === 91 && !(p + 2 < n && ch(p + 2) === 91)) {
      brackets.push({ pos: p, isImage: true });
      p += 2;
    } else p += 1;
  };

  const openBracket = () => {
    const link = p + 1 < n && ch(p + 1) === 91 ? parseWikiLink(s, p) : null;
    if (link) {
      add({ from: p, to: link.end, kind: "wikiLink", wiki: link });
      p = link.end;
    } else {
      brackets.push({ pos: p, isImage: false });
      p += 1;
    }
  };

  const closeBracket = () => {
    const opener = brackets.pop();
    const dest = opener && p + 1 < n && ch(p + 1) === 40 ? parseLinkDestination(s, p + 2) : null;
    if (!opener || !dest) {
      p += 1;
      return;
    }
    const metadataStart = metadataCommentStart(s, dest.end);
    const isAttachment = isRelativeDestination(dest.text) && (opener.isImage || metadataStart !== null);
    const drop = opener.isImage || isAttachment;
    add({
      from: opener.pos,
      to: opener.pos + (opener.isImage ? 2 : 1),
      kind: "linkOpen",
      ...(drop && { dropUntil: dest.end }),
    });
    add({ from: p, to: dest.end, kind: "linkClose" });
    if (isAttachment) attachments.push(attachmentSpan(s, opener.pos, dest.end, dest.text, opener.isImage, metadataStart));
    if (!opener.isImage) {
      for (let i = brackets.length - 1; i >= 0; i--) if (!brackets[i]!.isImage) brackets.splice(i, 1);
    }
    p = dest.end;
  };

  run: {
    if (startsInComment) {
      const close = s.indexOf("-->");
      if (close >= 0) {
        add({ from: 0, to: close + 3, kind: "comment" });
        p = close + 3;
      } else {
        add({ from: 0, to: n, kind: "comment" });
        endsInComment = true;
        break run;
      }
    }
    while (p < n) {
      switch (ch(p)) {
        case 92: escape(); break;
        case 96: codeSpan(); break;
        case 36: math(); break;
        case 60: angle(); break;
        case 58: bareURL(); break;
        case 33: bang(); break;
        case 91: openBracket(); break;
        case 93: closeBracket(); break;
        default: p += 1;
      }
    }
  }

  spans.sort((a, b) => a.from - b.from);
  const mask = new Uint8Array(n);
  for (const span of spans) {
    const to = span.kind === "linkOpen" ? (span.dropUntil ?? span.to) : span.to;
    mask.fill(1, span.from, Math.min(to, n));
  }
  return { spans, mask, endsInComment, attachments };
}

function decodeDestination(dest: string): string {
  try {
    return decodeURIComponent(dest);
  } catch {
    return dest;
  }
}

function attachmentSpan(
  s: string, from: number, linkEnd: number, dest: string, isImage: boolean, commentStart: number | null,
): AttachmentSpan {
  let to = linkEnd;
  let metadata: Record<string, string> = {};
  const close = commentStart === null ? -1 : s.indexOf("-->", commentStart + 4);
  if (commentStart !== null && close >= 0) {
    to = close + 3;
    metadata = parseMetadata(s.slice(commentStart + 4, close));
  }
  return { from, to, linkEnd, filename: decodeDestination(dest), isImage, metadata };
}

/** `{"width":"320"}` → values stringified like LinkDestination.metadata (Swift). */
export function parseMetadata(json: string): Record<string, string> {
  let value: unknown;
  try {
    value = JSON.parse(json);
  } catch {
    return {};
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) return {};
  const out: Record<string, string> = {};
  for (const [key, v] of Object.entries(value)) {
    if (typeof v === "string") out[key] = v;
    else if (typeof v === "boolean") out[key] = v ? "true" : "false";
    else if (typeof v === "number" && Number.isFinite(v)) out[key] = Number.isInteger(v) ? String(v) : String(v);
  }
  return out;
}

// MARK: WikiLinkParser

export interface WikiLink {
  end: number;
  target: string;
  heading: string | null;
  alias: string | null;
  display: string;
  /** Raw ranges (line offsets) of the parts, before trimming. */
  targetFrom: number;
  targetTo: number;
  headingFrom: number | null;
  /** End of target + heading (before the alias separator or `]]`). */
  targetEnd: number;
  aliasFrom: number | null;
  aliasTo: number;
}

/**
 * `[[target/heading|alias]]` at `p`. `\/` keeps a slash in the target; `\|` (tables) and `|`
 * both separate the alias. The first unescaped `/` separates the heading.
 */
export function parseWikiLink(s: string, p: number): WikiLink | null {
  let q = p + 2;
  while (q < s.length && s.charCodeAt(q) !== 93 && s.charCodeAt(q) !== 91) q++;
  if (!(q + 1 < s.length && s.charCodeAt(q) === 93 && s.charCodeAt(q + 1) === 93)) return null;
  const bodyStart = p + 2;
  let targetEnd = q;
  let aliasStart: number | null = null;
  for (let i = bodyStart; i < q; i++) {
    if (s.charCodeAt(i) === 124) {
      targetEnd = i > bodyStart && s.charCodeAt(i - 1) === 92 ? i - 1 : i;
      aliasStart = i + 1;
      break;
    }
  }
  let target = "";
  let heading: string | null = null;
  let headingFrom: number | null = null;
  let i = bodyStart;
  while (i < targetEnd) {
    const c = s[i]!;
    if (c === "\\" && i + 1 < targetEnd && s[i + 1] === "/") {
      if (heading !== null) heading += "/";
      else target += "/";
      i += 2;
      continue;
    }
    if (c === "/" && heading === null) {
      heading = "";
      headingFrom = i + 1;
    } else if (heading !== null) heading += c;
    else target += c;
    i++;
  }
  const targetText = collapse(target);
  const headingText = heading === null ? null : collapse(heading) || null;
  const aliasText = aliasStart === null ? null : collapse(s.slice(aliasStart, q)) || null;
  if (targetText === "" && headingText === null) return null;
  const display =
    aliasText ?? (headingText !== null ? (targetText === "" ? headingText : `${targetText}/${headingText}`) : targetText);
  return {
    end: q + 2,
    target: targetText,
    heading: headingText,
    alias: aliasText,
    display,
    targetFrom: bodyStart,
    targetTo: headingFrom !== null ? headingFrom - 1 : targetEnd,
    headingFrom: headingText !== null ? headingFrom : null,
    targetEnd,
    aliasFrom: aliasText !== null ? aliasStart : null,
    aliasTo: q,
  };
}

// MARK: LinkDestination

/** Parses `destination "title")` starting right after `(`. */
function parseLinkDestination(s: string, start: number): { text: string; end: number } | null {
  const n = s.length;
  let q = start;
  while (q < n && isBlank(s.charCodeAt(q))) q++;
  let text: string;
  if (q < n && s.charCodeAt(q) === 60) {
    let r = q + 1;
    while (r < n && s.charCodeAt(r) !== 62 && s.charCodeAt(r) !== 60) r++;
    if (!(r < n && s.charCodeAt(r) === 62)) return null;
    text = s.slice(q + 1, r);
    q = r + 1;
  } else {
    const destStart = q;
    let depth = 0;
    while (q < n) {
      const c = s.charCodeAt(q);
      if (c === 92 && q + 1 < n) {
        q += 2;
        continue;
      }
      if (spaceAt(s, q)) break;
      if (c === 40) depth++;
      else if (c === 41) {
        if (depth === 0) break;
        depth--;
      }
      q++;
    }
    if (depth !== 0) return null;
    text = s.slice(destStart, Math.min(q, n));
  }
  const beforeTitle = q;
  while (q < n && isBlank(s.charCodeAt(q))) q++;
  const open = s.charCodeAt(q);
  if (q < n && q > beforeTitle && (open === 34 || open === 39 || open === 40)) {
    const close = open === 40 ? 41 : open;
    let r = q + 1;
    while (r < n && s.charCodeAt(r) !== close) r += s.charCodeAt(r) === 92 && r + 1 < n ? 2 : 1;
    if (!(r < n)) return null;
    q = r + 1;
    while (q < n && isBlank(s.charCodeAt(q))) q++;
  }
  if (!(q < n && s.charCodeAt(q) === 41)) return null;
  return { text, end: q + 1 };
}

/** Relative destination: not empty, no `scheme:`, not `#…`, `/…` or `?…`. */
function isRelativeDestination(dest: string): boolean {
  const first = dest.charCodeAt(0);
  if (dest.length === 0 || first === 35 || first === 47 || first === 63) return false;
  if (!isASCIILetter(first)) return true;
  for (let i = 1; i < dest.length; i++) {
    const c = dest.charCodeAt(i);
    if (c === 58) return false;
    if (!isSchemeChar(c)) return true;
  }
  return true;
}

/** Offset of a `<!-- {` comment right after the link (blanks allowed), if any. */
function metadataCommentStart(s: string, end: number): number | null {
  let q = end;
  while (q < s.length && isBlank(s.charCodeAt(q))) q++;
  if (!(q + 3 < s.length && s.startsWith("<!--", q))) return null;
  let r = q + 4;
  while (r < s.length && spaceAt(s, r)) r++;
  return r < s.length && s.charCodeAt(r) === 123 ? q : null;
}

// MARK: TagScanner

export interface TagMatch {
  /** The opening `#` through the end of the tag (closing `#` included). */
  from: number;
  to: number;
  name: string;
  closed: boolean;
}

/** Tags in a single line of prose, in order (not deduped), given the line's inline mask. */
export function findTags(s: string, mask: Uint8Array): TagMatch[] {
  const matches: TagMatch[] = [];
  const n = s.length;
  let p = 0;
  while (p < n) {
    if (!opensTag(s, mask, p)) {
      p++;
      continue;
    }
    const close = multiWordCloser(s, mask, p);
    if (close !== null) {
      const name = normalizeTag(s.slice(p + 1, close));
      if (name) matches.push({ from: p, to: close + 1, name, closed: true });
      p = close + 1;
      continue;
    }
    let end = p + 1;
    while (end < n && !mask[end] && !endsSingleWord(codePointAt(s, end))) end++;
    while (end > p + 1 && isTrailingTrim(s.charCodeAt(end - 1))) end--;
    const name = normalizeTag(s.slice(p + 1, end));
    if (name && !needsClosedForm(name)) matches.push({ from: p, to: end, name, closed: false });
    p = Math.max(end, p + 1);
  }
  return matches;
}

/**
 * `#` at line start or after whitespace, `(` or `|`, followed by a character that is not
 * whitespace, `#`, or a keycap/variation selector (`#️⃣`).
 */
export function opensTag(s: string, mask: Uint8Array, p: number): boolean {
  if (s.charCodeAt(p) !== 35 || mask[p] || !(p + 1 < s.length) || mask[p + 1]) return false;
  if (p > 0) {
    const before = s.charCodeAt(p - 1);
    if (!(isSpace(before) || before === 40 || before === 124)) return false;
  }
  const next = codePointAt(s, p + 1);
  return !isSpace(next) && next !== 35 && next !== 0xfe0f && next !== 0x20e3;
}

/**
 * Closing `#` of `#words with spaces#` on the same line: preceded by a non-space and followed by
 * end/whitespace/punctuation. Gives up at a masked span or at a `#` that opens another tag.
 */
function multiWordCloser(s: string, mask: Uint8Array, p: number): number | null {
  for (let j = p + 1; j < s.length && !mask[j]; j++) {
    if (s.charCodeAt(j) === 35) {
      if (closesMultiWord(s, j)) return j;
      if (opensTag(s, mask, j)) return null;
    }
  }
  return null;
}

function closesMultiWord(s: string, j: number): boolean {
  if (isSpace(s.charCodeAt(j - 1))) return false;
  if (j + 1 === s.length) return true;
  const next = codePointAt(s, j + 1);
  return endsSingleWord(next) || isTrailingTrim(next);
}

/**
 * `:`, `+` and `|` may appear inside a single-word tag but are dropped from its end (Bear oracle:
 * `#a|b|` → `a|b`). In a table row an unmasked `|` separates cells, so it never reaches a tag.
 */
const isTrailingTrim = (c: number) => c === 58 || c === 43 || c === 124;

const SINGLE_WORD_ENDS = new Set(Array.from(".,;!?\"'()[]{}<>#*~=`\\", (c) => c.charCodeAt(0)));

/** Characters that end a single-word tag. */
export function endsSingleWord(c: number): boolean {
  if (isSpace(c)) return true;
  if (c < 128) return SINGLE_WORD_ENDS.has(c);
  return isNonASCIIPunct(c);
}

/** Path components trimmed, inner whitespace collapsed, empty components dropped. */
function normalizeTag(raw: string): string {
  const components: string[] = [];
  let current = "";
  let pendingSpace = false;
  for (const c of raw) {
    if (c === "/") {
      if (current) components.push(current);
      current = "";
      pendingSpace = false;
    } else if (isSpace(c.codePointAt(0)!)) {
      pendingSpace = current.length > 0;
    } else {
      if (pendingSpace) {
        current += " ";
        pendingSpace = false;
      }
      current += c;
    }
  }
  if (current) components.push(current);
  return components.join("/");
}

/** Numbers, slash dates and times and bare separators are tags only in the closed `#…#` form. */
function needsClosedForm(name: string): boolean {
  return /^[0-9/.:]+$/.test(name) || /^[-/.]+$/.test(name);
}

/** The tag name of a `#…` / `#…#` source slice (as matched by `findTags`). */
export function tagName(source: string): string {
  const closed = source.length > 2 && source.endsWith("#");
  return normalizeTag(source.slice(1, closed ? -1 : undefined));
}

// MARK: NoteParser.Fence / LineShape

export interface Fence {
  marker: number;
  length: number;
  quoteDepth: number;
  /** Columns from the end of the quote markers to the fence marker, when opened in a list item. */
  listColumn: number | null;
}

export type FenceLineKind = "close" | "content" | "ended" | "endedByIndent";

function bulletEnd(s: string, p: number, end: number): number | null {
  const c = s.charCodeAt(p);
  if (!(p < end && (c === 45 || c === 42 || c === 43))) return null;
  if (!(p + 1 === end || isBlank(s.charCodeAt(p + 1)))) return null;
  let q = p + 1;
  while (q < end && isBlank(s.charCodeAt(q))) q++;
  return q;
}

function orderedMarkerEnd(s: string, p: number, end: number): number | null {
  let q = p;
  while (q < end && isDigit(s.charCodeAt(q)) && q - p < 9) q++;
  if (!(q > p && q < end && (s.charCodeAt(q) === 46 || s.charCodeAt(q) === 41))) return null;
  q++;
  if (!(q === end || isBlank(s.charCodeAt(q)))) return null;
  while (q < end && isBlank(s.charCodeAt(q))) q++;
  return q;
}

function todoBoxEnd(s: string, p: number, end: number): number | null {
  if (!(p + 2 < end && s.charCodeAt(p) === 91 && s.charCodeAt(p + 2) === 93)) return null;
  const mark = s[p + 1];
  if (mark !== " " && mark !== "x" && mark !== "X") return null;
  if (!(p + 3 === end || isBlank(s.charCodeAt(p + 3)))) return null;
  let q = p + 3;
  while (q < end && isBlank(s.charCodeAt(q))) q++;
  return q;
}

function quotePrefix(line: string): { depth: number; end: number } {
  let depth = 0;
  let end = 0;
  for (;;) {
    let p = end;
    while (p < line.length && isBlank(line.charCodeAt(p))) p++;
    if (!(p < line.length && line.charCodeAt(p) === 62)) return { depth, end };
    p++;
    if (p < line.length && isBlank(line.charCodeAt(p))) p++;
    depth++;
    end = p;
  }
}

function stripQuotes(depth: number, line: string): number | null {
  let p = 0;
  for (let i = 0; i < depth; i++) {
    while (p < line.length && isBlank(line.charCodeAt(p))) p++;
    if (!(p < line.length && line.charCodeAt(p) === 62)) return null;
    p++;
    if (p < line.length && isBlank(line.charCodeAt(p))) p++;
  }
  return p;
}

const columns = (s: string) => Array.from(s).reduce((sum, c) => sum + (c === "\t" ? 4 : 1), 0);

/** A fence opener line (after optional quotes, indentation, a list marker and a task box). */
export function openFence(line: string): Fence | null {
  const quotes = quotePrefix(line);
  const end = trimmedEnd(line);
  let p = quotes.end;
  while (p < end && isBlank(line.charCodeAt(p))) p++;
  let listColumn: number | null = null;
  const afterBullet = bulletEnd(line, p, end);
  if (afterBullet !== null) {
    listColumn = columns(line.slice(quotes.end, afterBullet));
    p = todoBoxEnd(line, afterBullet, end) ?? afterBullet;
  } else {
    const afterNumber = orderedMarkerEnd(line, p, end);
    if (afterNumber !== null) {
      listColumn = columns(line.slice(quotes.end, afterNumber));
      p = afterNumber;
    }
  }
  const marker = line.charCodeAt(p);
  if (!(p < end && (marker === 96 || marker === 126))) return null;
  let q = p;
  while (q < line.length && line.charCodeAt(q) === marker) q++;
  if (q - p < 3) return null;
  if (marker === 96 && line.indexOf("`", q) >= 0) return null;
  return { marker, length: q - p, quoteDepth: quotes.depth, listColumn };
}

/** How a line after the opener relates to an open fence (no lazy continuation). */
export function classifyFenceLine(fence: Fence, line: string): FenceLineKind {
  const start = stripQuotes(fence.quoteDepth, line);
  if (start === null) return "ended";
  let p = start;
  let indent = 0;
  while (p < line.length && isBlank(line.charCodeAt(p))) {
    indent += line.charCodeAt(p) === 9 ? 4 : 1;
    p++;
  }
  const blank = trimmedEnd(line) <= p;
  if (isBareCloser(line, p, fence.marker, fence.length)) return "close";
  if (fence.listColumn !== null && !blank && indent < fence.listColumn) return "endedByIndent";
  return "content";
}

/** Blanks, then at least `length` of `marker`, then only whitespace. */
export function isBareCloser(line: string, start: number, marker: number, length: number): boolean {
  let p = start;
  while (p < line.length && isBlank(line.charCodeAt(p))) p++;
  let q = p;
  while (q < line.length && line.charCodeAt(q) === marker) q++;
  return q - p >= length && trimmedEnd(line) <= q;
}

// MARK: TableScanner

/** A line that can be a table row: `|` … `|` after optional quotes, blanks and a list marker. */
export interface TableRowShape {
  quoteDepth: number;
  /** Columns from the end of the quote markers to the leading `|`. */
  column: number;
  hasListMarker: boolean;
  /** Offset of the leading `|`. */
  from: number;
  /** Trimmed end (after the trailing `|`). */
  to: number;
}

/** The row shape of a line whose trimmed content starts and ends with `|` (TableScanner.rowShape). */
export function tableRowShape(line: string): TableRowShape | null {
  const to = trimmedEnd(line);
  if (to < 2 || line.charCodeAt(to - 1) !== 124) return null;
  const quotes = quotePrefix(line);
  let p = quotes.end;
  while (p < to && isBlank(line.charCodeAt(p))) p++;
  const afterMarker = bulletEnd(line, p, to) ?? orderedMarkerEnd(line, p, to);
  if (afterMarker !== null) p = afterMarker;
  if (line.charCodeAt(p) !== 124 || to - 1 <= p) return null;
  return {
    quoteDepth: quotes.depth,
    column: columns(line.slice(quotes.end, p)),
    hasListMarker: afterMarker !== null,
    from: p,
    to,
  };
}

/**
 * Offsets of the cell separators of a row: every `|` outside escapes, code spans, math, wiki
 * links, links' destinations, URLs and comments of the line. Null when the row's first or last
 * `|` is not one (`… \|`).
 */
export function tableSeparators(line: string, shape: TableRowShape): number[] | null {
  const mask = scanInline(line).mask;
  const out: number[] = [];
  for (let i = shape.from; i < shape.to; i++) if (line.charCodeAt(i) === 124 && !mask[i]) out.push(i);
  return out[0] === shape.from && out[out.length - 1] === shape.to - 1 ? out : null;
}

const DELIMITER_ROW = /^\|(?:[ \t]*:?-+:?[ \t]*\|)+$/;

/** Cell count of a delimiter row (`|---|:-:|`), or -1 when the row is not one. */
function delimiterCells(line: string, shape: TableRowShape): number {
  const content = line.slice(shape.from, shape.to);
  if (!DELIMITER_ROW.test(content)) return -1;
  let pipes = 0;
  for (let i = 0; i < content.length; i++) if (content.charCodeAt(i) === 124) pipes++;
  return pipes - 1;
}

/** Whether `row` is in the table that `header` starts: same quotes, no list marker, not outdented. */
const inTable = (header: TableRowShape, row: TableRowShape) =>
  row.quoteDepth === header.quoteDepth && !row.hasListMarker && row.column >= header.column;

/** `line` as a body row (or the delimiter row) of the table that `header` starts, or null. */
export function tableRowOf(header: TableRowShape, line: string): { shape: TableRowShape; separators: number[] } | null {
  const shape = tableRowShape(line);
  const separators = shape && inTable(header, shape) ? tableSeparators(line, shape) : null;
  return separators ? { shape: shape!, separators } : null;
}

/** Whether `line` is a delimiter row with the same cell count as the header row `headerLine`. */
export function isTableDelimiterFor(header: TableRowShape, headerLine: string, line: string): boolean {
  const row = tableRowShape(line);
  if (!row || !inTable(header, row)) return false;
  const cells = delimiterCells(line, row);
  if (cells < 1) return false;
  const separators = tableSeparators(headerLine, header);
  return separators !== null && separators.length - 1 === cells;
}

/** The header shape when `line` followed by `next` starts a table. */
export function tableHeader(line: string, next: string | null): TableRowShape | null {
  if (next === null) return null;
  const header = tableRowShape(line);
  return header && isTableDelimiterFor(header, line, next) ? header : null;
}
