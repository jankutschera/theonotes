// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import type { Locator } from "@playwright/test";

/** The text a reader sees: textContent without the collapsed (hidden) markup spans. */
export const visibleText = (locator: Locator) =>
  locator.evaluate((el) => {
    const clone = el.cloneNode(true) as Element;
    for (const hidden of clone.querySelectorAll(".cm-bc-hidden")) hidden.remove();
    return clone.textContent ?? "";
  });
