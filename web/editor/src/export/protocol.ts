// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

// The export page's request/result (M8 Task 10). One TypeScript definition; the Swift mirror is
// `Packages/TheoNotesCore/Sources/TheoNotesCore/Bridge/RenderProtocol.swift`, and both are checked
// against `Fixtures/bridge/render-request.json`. The host builds a request with
// `RenderRequestBuilder`; the page checks it again here, with the same rules the editor applies
// to `setSettings`: theme variables only from the schema (hex colour values), fonts the editor
// would accept, nothing else.

import type { EditorAppearance, EditorTypography } from "../bridge/protocol";
import { isEditorAppearance, isEditorTypography, isThemeTokens } from "../bridge/protocol";
import type { RenderMode } from "./render";

export const RENDER_VERSION = 1;

export type RenderRequest = {
  v: 1;
  noteId: string;
  title: string;
  text: string;
  mode: RenderMode;
  /** `--bc-<schema editor token>` → `#rrggbb[aa]`, over the default theme. */
  theme: Record<string, string>;
  appearance: EditorAppearance;
  typography: EditorTypography;
  /** Where each attachment file (by filename as written in the note) loads from; see `renderBody`. */
  attachmentSources: Record<string, string>;
  /** Byte sizes by filename, for the file cards (optional). */
  attachmentSizes?: Record<string, number>;
  /** One entry per wiki link occurrence, in text order: the `href` the host gives it, else null. */
  wikiLinks: ({ href: string } | null)[];
};

export type RenderResult = { html: string; headings: { level: number; text: string; anchor: string }[] };

const KEYS = ["v", "noteId", "title", "text", "mode", "theme", "appearance", "typography", "attachmentSources", "attachmentSizes", "wikiLinks"];

const isObject = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);

function isStringMap(v: unknown): v is Record<string, string> {
  return isObject(v) && Object.values(v).every((value) => typeof value === "string");
}

function isSizeMap(v: unknown): v is Record<string, number> {
  return isObject(v) && Object.values(v).every((n) => Number.isSafeInteger(n) && (n as number) >= 0);
}

function isWikiLink(v: unknown): v is { href: string } | null {
  if (v === null) return true;
  return isObject(v) && Object.keys(v).length === 1 && typeof v.href === "string";
}

/** The request when `value` is one this page version understands, else null. */
export function parseRenderRequest(value: unknown): RenderRequest | null {
  if (!isObject(value) || value.v !== RENDER_VERSION) return null;
  if (!Object.keys(value).every((key) => KEYS.includes(key))) return null;
  if (typeof value.noteId !== "string" || typeof value.title !== "string" || typeof value.text !== "string") return null;
  if (value.mode !== "document" && value.mode !== "richText") return null;
  if (!isThemeTokens(value.theme) || !isEditorAppearance(value.appearance) || !isEditorTypography(value.typography)) return null;
  if (!isStringMap(value.attachmentSources)) return null;
  if (value.attachmentSizes !== undefined && !isSizeMap(value.attachmentSizes)) return null;
  if (!Array.isArray(value.wikiLinks) || !value.wikiLinks.every(isWikiLink)) return null;
  return value as RenderRequest;
}
