// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

// Menu targets: where a native menu (heading, table cell, callout) was opened.
//
// The editor remembers a position under a `menuId`, posts it with the menu message, and the host
// answers with `applyCommand {..., menuId}`. The position is mapped through every edit made while
// the menu is open (an external change, a keystroke) and dies with the text it pointed into, so a
// command never lands on a different line than the one the user clicked.

import { type EditorState, MapMode, StateEffect, StateField, Transaction, type TransactionSpec } from "@codemirror/state";
import type { EditorView } from "@codemirror/view";
import type { CaretRect } from "../../bridge/protocol";

/** `column`: the grid column a table cell menu was opened on (a padding cell of a ragged row has no
 * text of its own, so `pos` is the row's last real cell, final review I2). */
type MenuTarget = { id: string; pos: number; column?: number };

/** Only the latest menus can still be answered. */
const MAX_TARGETS = 8;

/** Remembers a target (`rememberMenuTarget` dispatches it; tests apply it to a bare state). */
export const menuTargetEffect = StateEffect.define<MenuTarget>();

export const menuTargets = StateField.define<readonly MenuTarget[]>({
  create: () => [],
  update(targets, tr) {
    let next = targets;
    if (tr.docChanged && next.length) {
      // assoc 1: text typed at the target pushes it along, so a line start stays on its line.
      // TrackAfter: a change that deletes or replaces the text from the target on (a line start
      // included, which TrackDel would keep) drops it.
      next = next.flatMap((target) => {
        const pos = tr.changes.mapPos(target.pos, 1, MapMode.TrackAfter);
        return pos === null ? [] : [{ ...target, pos }];
      });
    }
    for (const effect of tr.effects) {
      if (!effect.is(menuTargetEffect)) continue;
      const { pos } = effect.value;
      if (pos < 0 || pos > tr.newDoc.length) continue;
      next = [...next, effect.value].slice(-MAX_TARGETS);
    }
    return next;
  },
});

let sequence = 0;
const prefix = Math.random().toString(36).slice(2, 6);

/** The part of an EditorView `rememberMenuTarget` needs. */
export type MenuTargetView = { readonly state: EditorState; dispatch(spec: TransactionSpec): void };

/**
 * Remembers `pos` and returns the `menuId` to send with the menu message. Not an edit: no
 * document change, no undo step, and it works in read-only notes.
 */
export function rememberMenuTarget(view: MenuTargetView, pos: number, column?: number): string {
  const id = `menu-${prefix}-${++sequence}`;
  const target: MenuTarget = column === undefined ? { id, pos } : { id, pos, column };
  view.dispatch({ effects: menuTargetEffect.of(target), annotations: Transaction.addToHistory.of(false) });
  return id;
}

/** Viewport rect of `pos`, to anchor a native menu (zeros when it is not laid out). */
export function menuAnchorRect(view: Pick<EditorView, "coordsAtPos">, pos: number): CaretRect {
  const c = view.coordsAtPos(pos, 1) ?? view.coordsAtPos(pos, -1);
  if (!c) return { x: 0, y: 0, width: 0, height: 0 };
  return { x: c.left, y: c.top, width: Math.max(1, c.right - c.left), height: c.bottom - c.top };
}

/** Where the menu `menuId` was opened, or null once that text is gone (or the id is unknown). */
export function menuTargetPos(state: EditorState, menuId: string): number | null {
  return targetOf(state, menuId)?.pos ?? null;
}

function targetOf(state: EditorState, menuId: string): MenuTarget | undefined {
  return state.field(menuTargets, false)?.find((target) => target.id === menuId);
}

/**
 * Where a command with the optional `menuId` argument acts (bridge `CommandArgs`):
 * `selection`: no `menuId`, act at the main selection; `target`: the position the menu was opened
 * at; `dead`: a `menuId` that no longer resolves (its text is gone, or it is unknown or not a
 * string), so the command must do nothing, never fall back to the selection.
 */
export type MenuTargetResolution = { kind: "selection" } | { kind: "target"; pos: number; column?: number } | { kind: "dead" };

export function resolveMenuTarget(state: EditorState, args: Record<string, unknown> | undefined): MenuTargetResolution {
  if (args === undefined || !("menuId" in args) || args.menuId === undefined) return { kind: "selection" };
  const target = typeof args.menuId === "string" && args.menuId ? targetOf(state, args.menuId) : undefined;
  if (!target) return { kind: "dead" };
  return target.column === undefined ? { kind: "target", pos: target.pos } : { kind: "target", pos: target.pos, column: target.column };
}
