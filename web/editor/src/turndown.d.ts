// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

// The slice of turndown 7.2.4's API the editor uses (the package ships no types).
declare module "turndown" {
  type Filter = string | string[] | ((node: HTMLElement, options: TurndownOptions) => boolean);

  interface TurndownOptions {
    headingStyle?: "setext" | "atx";
    hr?: string;
    bulletListMarker?: "-" | "+" | "*";
    codeBlockStyle?: "indented" | "fenced";
    fence?: string;
    emDelimiter?: "_" | "*";
    strongDelimiter?: "__" | "**";
    linkStyle?: "inlined" | "referenced";
    br?: string;
  }

  interface Rule {
    filter: Filter;
    replacement: (content: string, node: HTMLElement, options: TurndownOptions) => string;
  }

  export default class TurndownService {
    constructor(options?: TurndownOptions);
    addRule(key: string, rule: Rule): this;
    remove(filter: Filter): this;
    keep(filter: Filter): this;
    escape(text: string): string;
    turndown(html: string | Node): string;
  }
}
