// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import SwiftUI

/// The editor column: the focused note, or "No Note Selected". The web view stays in the
/// hierarchy (hidden) so switching notes never reloads the editor bundle. The column is opaque
/// content in the theme's background colour, behind the web view and the empty state.
struct EditorPane: View {
    let state: MainWindowState
    @Environment(\.shellPalette) private var palette
    @State private var confirmDiscardBrowserText = false
    @State private var browserDiscardToken: EditorBridgeController.BrowserDiscardToken?
    @AppStorage(FormattingBar.shownKey) private var showsFormattingBar = true

    private var hasNote: Bool { state.model.focusedNoteID != nil }
    /// A locked note while the vault is locked: the lock view stands in for the editor.
    private var lockedNoteId: String? { state.editor.status.lockedNoteId }

    var body: some View {
        let showsEditor = hasNote && lockedNoteId == nil
        EditorWebView(controller: state.editor)
            .opacity(showsEditor ? 1 : 0)
            .allowsHitTesting(showsEditor)
            .accessibilityHidden(!showsEditor)
            .overlay {
                if let lockedNoteId {
                    LockedNotePane(environment: state.model.environment, noteId: lockedNoteId)
                        .id(lockedNoteId)
                } else if !hasNote {
                    Text("No Note Selected")
                        .font(.title3)
                        .foregroundStyle(palette.secondaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .formattingBar(state, isShown: hasNote && showsFormattingBar)
            .background(palette.background)
            .overlay(alignment: .top) {
                if let message = state.editor.status.recoveryError {
                    VStack {
                        Text(message).font(.callout)
                        HStack {
                            Button("Retry") { state.editor.retryBrowserRecovery() }
                            Button("Discard Unsaved Text…") {
                                browserDiscardToken = state.editor.browserDiscardToken
                                confirmDiscardBrowserText = browserDiscardToken != nil
                            }
                        }
                    }.padding().background(palette.background)
                }
            }
            .alert("Discard unsaved text?", isPresented: $confirmDiscardBrowserText) {
                Button("Discard Unsaved Text", role: .destructive) {
                    if let token = browserDiscardToken {
                        state.editor.discardBrowserTextAfterConfirmation(token)
                        state.showFocusedNote()
                    }
                    browserDiscardToken = nil
                }
                Button("Keep Note Open", role: .cancel) {}
            } message: { Text("The unsaved text could not be saved. If you discard it, that text will be lost.") }
            .onChange(of: state.model.focusedNoteID, initial: true) { state.showFocusedNote() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) { NoteTypeToolbarMenu(model: state.model) }
                ToolbarItem(placement: .primaryAction) { InfoToolbarButton(info: state.info) }
            }
    }
}
