// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { afterComposition } from "../composition";
// Typewriter mode (⌃⌘T, M6 Task 14): the caret line stays at the vertical centre of the editor
// while the user types or moves the caret with the keyboard. The setting itself is the
// `typewriterMode` setting in settings.ts (bridge `setSettings`, app-wide).
//
// What scrolls: transactions that ask for the caret to be scrolled into view (`scrollIntoView`)
// and carry the user event `input.*`, `delete.*`, `move.*`, `select.*`, `undo` or `redo`, except
// `select.pointer` (a click or drag keeps the line where the pointer is) and composition
// (`input.type.compose`: the centre catches up on `compositionend`). A todo checkbox click
// (`input.todo`) and an image resize (`input.attachment`) do not ask for the scroll, so they
// stay put. What does not scroll either: the user's own scrolling (no transaction), a note
// opening (`loadNote` replaces the state), the host's changes (no user event), Find Next and
// the note-list search highlight (they scroll the match, not the caret).
// The scroll is instant, so there is no animation for the system's Reduce Motion to turn off.
//
// While the mode is on the text column starts at the vertical centre (padding-top 50vh); the
// over-scroll below the last line is typography.ts's (50vh), so the last line centres too.

import { type StateEffect, EditorState, type Extension, type Transaction } from "@codemirror/state";
import { EditorView, ViewPlugin, type ViewUpdate } from "@codemirror/view";
import { typewriterModeSetting } from "./settings";

export { typewriterModeSetting as typewriterMode };

/**
 * Marks our centre scrolls: CodeMirror keeps `yMargin` untouched through `map` and `clip`, and
 * the margin has no effect on a "center" scroll, so the scroll handler below can tell our scrolls
 * from Find Next's and the search highlight's (default margin 5).
 */
const OUR_MARGIN = 6;

const scrollToCentre = (pos: number) => EditorView.scrollIntoView(pos, { y: "center", yMargin: OUR_MARGIN });

const CENTRING_EVENTS = ["input", "delete", "move", "select", "undo", "redo"];

/** The centre-scroll effect for `tr`, or null when typewriter mode is off or `tr` is not keyboard-driven. */
export function typewriterScroll(tr: Transaction): StateEffect<unknown> | null {
  if (!tr.startState.facet(typewriterModeSetting) || !tr.scrollIntoView) return null;
  if (tr.isUserEvent("input.type.compose") || tr.isUserEvent("select.pointer")) return null;
  if (!CENTRING_EVENTS.some((event) => tr.isUserEvent(event))) return null;
  return scrollToCentre(tr.newSelection.main.head);
}

const centreAfterTyping = EditorState.transactionExtender.of((tr) => {
  const effect = typewriterScroll(tr);
  return effect ? { effects: effect } : null;
});

/**
 * CodeMirror clips a scroll effect against the document from before the transaction, so a caret
 * past the old end (Enter or a paste at the end of the note) is clamped to the old end and its
 * "center" scroll lands one line short. Right after our scroll (a microtask runs before the next
 * paint) the line of the real caret is moved to the exact centre.
 */
const exactCentre = EditorView.scrollHandler.of((view, _range, options) => {
  if (options.y === "center" && options.yMargin === OUR_MARGIN && view.state.facet(typewriterModeSetting)) {
    queueMicrotask(() => {
      if (!view.dom.isConnected) return;
      const rect = view.coordsAtPos(view.state.selection.main.head, 1);
      if (!rect) return;
      const { scrollDOM } = view;
      const delta = (rect.top + rect.bottom) / 2 - (scrollDOM.getBoundingClientRect().top + scrollDOM.clientHeight / 2);
      if (Math.abs(delta) > 0.5) scrollDOM.scrollTop += delta;
    });
  }
  return false;
});

const contentPaddingTop = (view: EditorView) => parseFloat(getComputedStyle(view.contentDOM).paddingTop) || 0;

/**
 * After the update that turned the mode on or ended a composition (cannot dispatch inside an
 * update) it centres once; switching the mode off keeps the caret line where it was on screen.
 */
const modeChanges = ViewPlugin.fromClass(
  class {
    private timer: ReturnType<typeof setTimeout> | undefined;

    constructor(readonly view: EditorView) {}

    update(update: ViewUpdate) {
      const was = update.startState.facet(typewriterModeSetting);
      const now = update.state.facet(typewriterModeSetting);
      if (!was && now) this.centre(0);
      if (was && !now) {
        // The class is not removed yet: this is the padding the text sat under.
        const before = contentPaddingTop(this.view);
        this.view.requestMeasure({
          read: (view) => before - contentPaddingTop(view),
          write: (shrunk, view) => {
            if (shrunk > 0.5) view.scrollDOM.scrollTop -= shrunk;
          },
        });
      }
    }

    centre(delay: number) {
      clearTimeout(this.timer);
      this.timer = setTimeout(() => {
        const { view } = this;
        if (!view.dom.isConnected || view.composing || !view.state.facet(typewriterModeSetting)) return;
        view.dispatch({ effects: scrollToCentre(view.state.selection.main.head) });
      }, delay);
    }

    destroy() {
      clearTimeout(this.timer);
    }
  },
  {
    eventHandlers: {
      // CodeMirror reads the composed text shortly after the event.
      compositionend() {
        if (this.view.state.facet(typewriterModeSetting)) afterComposition(() => this.centre(60));
      },
    },
  },
);

const padding = EditorView.editorAttributes.compute([typewriterModeSetting], (state): Record<string, string> =>
  state.facet(typewriterModeSetting) ? { class: "cm-bc-typewriter" } : {},
);

const theme = EditorView.baseTheme({
  "&.cm-bc-typewriter .cm-content": { paddingTop: "50vh" },
});

export const typewriter: Extension = [centreAfterTyping, exactCentre, modeChanges, padding, theme];
