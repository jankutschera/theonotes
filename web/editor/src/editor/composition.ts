// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

/**
 * iOS/WebKit can delete the marked text before compositionend while CodeMirror deliberately
 * postpones reading that DOM mutation until an animation frame. A zero-delay presentation or
 * settings transaction can redraw the old document first and resurrect the canceled preedit.
 * Run deferred composition work in a task after the frame's DOM flushes have completed.
 */
export function afterComposition(callback: () => void, delay = 0): void {
  if (typeof requestAnimationFrame === "function") {
    requestAnimationFrame(() => setTimeout(callback, delay));
  } else {
    // Non-DOM command test targets have no animation frames or pending browser mutations.
    setTimeout(callback, delay);
  }
}
