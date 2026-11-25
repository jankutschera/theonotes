// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import SwiftUI

/// The recovery words: the 24 words, a copy button, the three-word check, and (during first setup only) the way to skip with the
/// risk sentence ticked (CK-R7, CK-J1). The file keeps the name the plan gave it; the words on screen are "recovery words".
struct CloudRecoveryKeySheet: View {
    let controller: CloudSyncController

    @Environment(\.scenePhase) private var scenePhase
    @State private var typed: [Int: String] = [:]
    @State private var acknowledged = false
    @State private var copied = false
    @State private var showsWords = true
    @FocusState private var focus: Int?

    var body: some View {
        if let offer = controller.recoveryOffer, let purpose = controller.recoveryPurpose {
            sheet(offer: offer, purpose: purpose)
        }
    }

    private func sheet(offer: RecoveryKeyOffer, purpose: CloudRecoverySheetPurpose) -> some View {
        let words = offer.words.split(separator: " ").map(String.init)
        return VStack(alignment: .leading, spacing: 14) {
            Label(CloudSyncStrings.sheetTitle, systemImage: "key").font(.headline)
            Text(purpose == .firstSetup ? CloudSyncStrings.sheetSetupIntro : CloudSyncStrings.sheetLaterIntro)
                .fixedSize(horizontal: false, vertical: true)
            wordGrid(words)
            HStack {
                Button(CloudSyncStrings.sheetCopy) { copy(offer.words) }
                Button(showsWords ? CloudSyncStrings.sheetHideWords : CloudSyncStrings.sheetShowWords) { showsWords.toggle() }
                if copied { Text(CloudSyncStrings.sheetCopied).font(.footnote).foregroundStyle(.secondary) }
            }
            Divider()
            checkFields(offer.checkPositions)
            if let error = controller.recoverySheetError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    .accessibilityIdentifier("cloud-recovery-error")
            }
            if purpose == .firstSetup { skipBlock }
            HStack {
                Button(purpose == .firstSetup ? CloudSyncStrings.sheetCancelSetup : CloudSyncStrings.sheetCancel, role: .cancel) {
                    Task { await controller.cancelRecoverySheet() }
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button(CloudSyncStrings.sheetSave) { Task { await controller.confirmRecoveryWords(typed: typed) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!offer.checkPositions.allSatisfy { !(typed[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty } || controller.isWorking)
                    .accessibilityIdentifier("cloud-recovery-save")
            }
        }
        .padding(20)
        .frame(width: 460)
        .onDisappear { typed = [:]; acknowledged = false }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            typed = [:]
        }
    }

    private func wordGrid(_ words: [String]) -> some View {
        Group {
            if showsWords && scenePhase == .active {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), spacing: 8) {
                    ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                        Text("\(index + 1). \(word)")
                            .font(.system(.body, design: .monospaced))
                            .accessibilityLabel(CloudSyncStrings.sheetWordAccessibility(position: index + 1, word: word))
                    }
                }
                .privacySensitive()
                .textSelection(.disabled)
            } else {
                Text(scenePhase == .active ? "" : CloudSyncStrings.sheetWordsHidden).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("cloud-recovery-words")
    }

    private func checkFields(_ positions: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(CloudSyncStrings.sheetCheckTitle).font(.subheadline.weight(.semibold))
            Text(CloudSyncStrings.sheetCheckIntro).font(.footnote).foregroundStyle(.secondary)
            ForEach(positions, id: \.self) { position in
                LabeledContent(CloudSyncStrings.sheetCheckPrompt(position: position + 1)) {
                    TextField("", text: Binding(get: { typed[position] ?? "" }, set: { typed[position] = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .focused($focus, equals: position)
                        .accessibilityLabel(CloudSyncStrings.sheetCheckPrompt(position: position + 1))
                }
            }
        }
    }

    private var skipBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text(CloudSyncStrings.sheetSkipHeader).font(.subheadline.weight(.semibold))
            Toggle(CloudSyncStrings.sheetRiskSentence, isOn: $acknowledged)
                .accessibilityIdentifier("cloud-recovery-risk")
            Button(CloudSyncStrings.sheetSkip) { Task { await controller.skipRecoveryWords(acknowledged: acknowledged) } }
                .disabled(!acknowledged || controller.isWorking)
                .accessibilityIdentifier("cloud-recovery-skip")
        }
    }

    /// The words go to the clipboard for a minute, then the clipboard is cleared if nothing else replaced them.
    private func copy(_ words: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(words, forType: .string)
        let count = board.changeCount
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(60))
            if NSPasteboard.general.changeCount == count { NSPasteboard.general.clearContents() }
        }
    }
}
