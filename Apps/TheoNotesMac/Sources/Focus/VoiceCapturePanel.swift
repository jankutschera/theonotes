// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import TheoNotesVoice
import Combine
import SwiftUI

/// File ▸ Capture Voice Note and Edit ▸ Insert Voice Note: the titles, and when each command is off.
enum VoiceMenu {
    static let captureTitle = "Capture Voice Note"
    static let insertTitle = "Insert Voice Note"
    static let panelTitle = "Voice Note"

    /// Off without an app, while App Lock is engaged and while another voice note is being made.
    @MainActor
    static func isCaptureDisabled(app: AppModel?) -> Bool {
        guard let app else { return true }
        return app.isLocked || app.isMakingVoiceNote
    }

    /// Insert also needs an editable note with the keyboard focus in its editor, and the insert switch on.
    @MainActor
    static func isInsertDisabled(app: AppModel?, editorEnabled: Bool) -> Bool {
        isCaptureDisabled(app: app) || !editorEnabled || !VoiceCapture.isInsertModeEnabled
    }
}

extension AppModel {
    /// File ▸ Capture Voice Note.
    func captureVoiceNote() {
        guard !isLocked, !voice.isBusy else { return }
        Task { await voice.beginNewNote() }
    }

    /// Edit ▸ Insert Voice Note: into the note the focused editor shows, at its caret.
    func insertVoiceNote(main: MainWindowState?, noteWindow: NoteWindowState?) {
        guard !isLocked, !voice.isBusy else { return }
        let editor = main?.editor ?? noteWindow?.editor
        guard let editor, let session = editor.session else { return }
        let offset = editor.status.selection?.head ?? session.text.utf16.count
        let noteId = session.noteId
        Task { await voice.beginInsert(noteId: noteId, utf16Offset: offset) }
    }
}

/// The File menu's Capture Voice Note item.
struct CaptureVoiceNoteButton: View {
    let app: AppModel?

    var body: some View {
        Button(VoiceMenu.captureTitle) { app?.captureVoiceNote() }
            .disabled(VoiceMenu.isCaptureDisabled(app: app))
    }
}

/// The Edit menu's Insert Voice Note item.
struct InsertVoiceNoteButton: View {
    let app: AppModel?
    let main: MainWindowState?
    let noteWindow: NoteWindowState?
    let editorEnabled: Bool

    var body: some View {
        Button(VoiceMenu.insertTitle) { app?.insertVoiceNote(main: main, noteWindow: noteWindow) }
            .disabled(VoiceMenu.isInsertDisabled(app: app, editorEnabled: editorEnabled))
    }
}

/// The small window of a voice note: the model question, the live text with Stop and Cancel, the
/// stop notice and the messages. It opens when the model has something to show and closes when it has not.
struct VoiceCapturePanel: View {
    @ObservedObject var model: VoiceCaptureModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.state {
            case .idle, .done:
                EmptyView()
            case .askingForModel(let locale):
                if model.isDownloading {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Downloading the speech model…")
                    }
                    HStack {
                        Spacer()
                        Button("Cancel", role: .cancel) { Task { await model.cancel() } }
                            .keyboardShortcut(.cancelAction)
                    }
                } else {
                    Text(VoiceCaptureModel.modelQuestion(for: locale))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("Not Now") { model.answerModelQuestion(download: false) }
                            .keyboardShortcut(.cancelAction)
                        Button("Download") { model.answerModelQuestion(download: true) }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            case .listening(let heard):
                Label("Listening…", systemImage: "mic.fill")
                    .foregroundStyle(.red)
                    .accessibilityAddTraits(.updatesFrequently)
                ScrollView {
                    Text(heard)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 60, maxHeight: 160)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { Task { await model.cancel() } }
                        .keyboardShortcut(.cancelAction)
                    Button("Stop") { Task { await model.stop() } }
                        .keyboardShortcut(.defaultAction)
                }
            case .stoppedByInput:
                Text(VoiceCaptureModel.stopNotice)
                    .fixedSize(horizontal: false, vertical: true)
                dismissButton
            case .unavailable(let message):
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                dismissButton
            }
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }

    private var dismissButton: some View {
        HStack {
            Spacer()
            Button("OK") { model.dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// Keeps one floating panel in step with the model's state. Closing the panel with its close button
/// is Cancel while recording and OK otherwise.
@MainActor
final class VoicePanelController: NSObject, NSWindowDelegate {
    private let model: VoiceCaptureModel
    private var panel: NSPanel?
    private var subscription: AnyCancellable?

    init(model: VoiceCaptureModel) {
        self.model = model
        super.init()
        subscription = model.$state.sink { [weak self] _ in
            // `@Published` fires before the value is stored; look at the model on the next turn.
            Task { @MainActor in self?.update() }
        }
    }

    var isShown: Bool { panel?.isVisible == true }
    /// How often the panel was brought to the front (once per time it opens).
    private(set) var frontCount = 0

    func update() {
        if model.isShowingPanel { show() } else { hide() }
    }

    private func show() {
        // Only the first time: later state changes must not pull the panel in front of what the user is doing.
        if panel != nil { return }
        let host = NSHostingController(rootView: VoiceCapturePanel(model: model))
        let panel = NSPanel(contentViewController: host)
        panel.styleMask = [.titled, .closable, .utilityWindow]
        panel.title = VoiceMenu.panelTitle
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.center()
        self.panel = panel
        frontCount += 1
        panel.makeKeyAndOrderFront(nil)
    }

    private func hide() {
        guard let panel else { return }
        self.panel = nil
        panel.delegate = nil
        panel.close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        switch model.state {
        case .listening, .askingForModel: Task { await model.cancel() }
        default: model.dismiss()
        }
        return false
    }
}
