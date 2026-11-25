// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Observation
import SwiftUI

/// What an editor column shows for a note: the editor, the lock view (a locked note while the
/// vault is locked) or nothing.
enum EditorPaneContent: Equatable {
    case editor(noteId: String)
    case locked(noteId: String)
    case empty

    static func `for`(note: Note?, vaultUnlocked: Bool) -> EditorPaneContent {
        guard let note else { return .empty }
        return note.isLocked && !vaultUnlocked ? .locked(noteId: note.id) : .editor(noteId: note.id)
    }
}

/// The state behind the lock view. It holds the note's id and title (a locked note's title is
/// visible in the list too) and what the user typed; never any of the note's content.
@MainActor
@Observable
final class LockedNoteModel {
    static let message = "This note is locked."
    static let passwordTitle = "Note Password"
    static let unlockTitle = "Unlock"
    static let touchIDTitle = "Use Touch ID"
    static let wrongPasswordMessage = "That password is not right."
    static let unlockFailedMessage = "The notes could not be unlocked."
    static let touchIDExpiredMessage = "Touch ID no longer matches. Enter your password."
    static let touchIDUnavailableMessage = "Enter your password to unlock."

    let noteId: String
    let title: String
    var password = ""
    private(set) var errorMessage: String?
    private(set) var isWorking = false

    @ObservationIgnored private let vault: NoteVault
    @ObservationIgnored private var scopeIsOpen = false

    init(vault: NoteVault, noteId: String, title: String) {
        self.vault = vault
        self.noteId = noteId
        self.title = title
    }

    isolated deinit {
        endAuthenticationScope()
    }

    var displayTitle: String { title.isEmpty ? "Untitled" : title }

    /// Touch ID is offered only when the vault can use it: a password exists, biometry is on and
    /// enabled, and a key is cached for this library.
    var canUseTouchID: Bool { vault.canUnlockWithBiometrics }

    /// Everything the view renders or announces.
    var visibleStrings: [String] {
        var strings = [displayTitle, Self.message, Self.passwordTitle, Self.unlockTitle]
        if canUseTouchID { strings.append(Self.touchIDTitle) }
        if let errorMessage { strings.append(errorMessage) }
        return strings
    }

    /// While the lock view is up, a resign does not count as leaving the app (it nests, and is
    /// safe to call twice).
    func beginAuthenticationScope() {
        guard !scopeIsOpen else { return }
        scopeIsOpen = true
        vault.beginAuthentication()
    }

    func endAuthenticationScope() {
        guard scopeIsOpen else { return }
        scopeIsOpen = false
        vault.endAuthentication()
    }

    func unlock() async {
        guard !isWorking, !password.isEmpty else { return }
        isWorking = true
        errorMessage = nil
        let entered = password
        defer { isWorking = false }
        do {
            try await vault.unlock(password: entered)
            password = ""
        } catch CryptoError.wrongPassword {
            password = ""
            errorMessage = Self.wrongPasswordMessage
        } catch {
            password = ""
            errorMessage = Self.unlockFailedMessage
        }
    }

    func unlockWithTouchID() async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            switch try await vault.unlockWithBiometrics() {
            case .unlocked, .cancelled: break
            case .unavailable, .noCachedKey, .temporarilyUnavailable: errorMessage = Self.touchIDUnavailableMessage
            case .staleCacheRemoved: errorMessage = Self.touchIDExpiredMessage
            }
        } catch {
            errorMessage = Self.unlockFailedMessage
        }
    }
}

/// The placeholder in place of a locked note's editor while the vault is locked: a lock, the
/// title, a password field and Unlock (and Touch ID when the vault can use it). It holds no body,
/// no preview and no attachment.
struct LockedNoteView: View {
    @Bindable var model: LockedNoteModel
    @Environment(\.shellPalette) private var palette

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 34))
                .foregroundStyle(palette.secondaryText)
                .accessibilityHidden(true)
            Text(model.displayTitle)
                .font(.title2.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(LockedNoteModel.message)
                .foregroundStyle(palette.secondaryText)
            PasswordTextField(
                label: LockedNoteModel.passwordTitle, text: $model.password, focusOnAppear: true,
                isEnabled: !model.isWorking, onSubmit: { Task { await model.unlock() } })
                .frame(width: 240, height: 22)
            if let error = model.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            HStack(spacing: 10) {
                Button(LockedNoteModel.unlockTitle) { Task { await model.unlock() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.password.isEmpty || model.isWorking)
                if model.canUseTouchID {
                    Button(LockedNoteModel.touchIDTitle) { Task { await model.unlockWithTouchID() } }
                        .disabled(model.isWorking)
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Locked note")
        .onAppear {
            model.beginAuthenticationScope()
        }
        .onDisappear { model.endAuthenticationScope() }
    }
}

/// Keeps one `LockedNoteModel` per shown locked note (the typed password survives re-renders).
struct LockedNotePane: View {
    @State private var model: LockedNoteModel

    init(environment: AppEnvironment, noteId: String) {
        let title = ((try? environment.store.note(id: noteId)) ?? nil)?.title ?? ""
        _model = State(initialValue: LockedNoteModel(vault: environment.vault, noteId: noteId, title: title))
    }

    var body: some View { LockedNoteView(model: model) }
}
