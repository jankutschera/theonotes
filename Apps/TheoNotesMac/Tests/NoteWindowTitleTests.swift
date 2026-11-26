// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import SwiftUI
import Testing
@testable import TheoNotes

/// A note window (the capture window above all) draws its title in the shell's primary
/// text colour. The system title of a window that is not frontmost is drawn dim, which on the dark
/// canvas made "Untitled" hard to read.
@MainActor
@Suite struct NoteWindowTitleTests {
    private func palette(_ id: String) throws -> ShellPalette {
        let theme = try #require(ThemeCatalog.theme(id: id))
        return ShellPalette.resolve(
            ResolvedAppearance(theme: theme, reduceMotion: false, reduceTransparency: false, increaseContrast: false))
    }

    private func source(_ file: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/\(file)"), encoding: .utf8)
    }

    @Test func theTitleIsDrawnInThePrimaryTextColour() throws {
        for id in ["baerchen-red", "baerchen-dark"] {
            let palette = try palette(id)
            #expect(palette.text != palette.secondaryText, "\(id): the check must tell the two colours apart")
            #expect(NoteWindowTitle.color(for: palette) == palette.text, "\(id)")
        }
    }

    @Test func theWindowDrawsItsOwnTitleInsteadOfTheSystemOne() throws {
        let window = try source("Windows/NoteWindow.swift")
        #expect(window.contains(".toolbar(removing: .title)"), "the dim system title is removed")
        #expect(window.contains("NoteWindowTitle(title: state.title"), "and replaced by the themed one")
    }
}
