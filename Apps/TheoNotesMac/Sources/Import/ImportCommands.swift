// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Menu entries: File ▸ Import Notes… (⇧⌘O) takes plain files; the importers for other apps sit in
/// the File ▸ Import From submenu (Bear…, Apple Notes…, Apple Notes Export…, Evernote…, Notion…),
/// next to Pull from Bear (⌥⇧⌘B). Apple Notes Export…, Evernote… and Notion… open a panel for that export and then
/// the same options sheet and report as Import Notes.
struct ImportCommands: Commands {
    @FocusedValue(\.mainWindow) private var window

    private var unavailable: Bool {
        ImportCommandAvailability.isUnavailable(
            hasWindow: window != nil, importRunning: window?.importer.isRunning == true,
            libraryOperationBusy: window?.model.environment.operations.isBusy == true,
            appLocked: window?.model.environment.appLock.isLocked == true)
    }

    private func choose(_ source: ImportPanel.Source) {
        guard !unavailable, let importer = window?.importer else { return }
        ImportPanel.choose(source) { importer.showFileImport($0, mode: source == .appleNotesExport ? .appleNotesExport : .files) }
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            Button("Import Notes…") { choose(.notes) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(unavailable)
            Menu("Import From") {
                Button("Bear…") { window?.importer.showBearImport() }
                    .disabled(unavailable)
                Button("Apple Notes…") { window?.importer.showAppleNotesImport() }
                    .disabled(unavailable)
                Button("Apple Notes Export…") { choose(.appleNotesExport) }
                    .disabled(unavailable)
                Button("Evernote…") { choose(.evernote) }
                    .disabled(unavailable)
                Button("Notion…") { choose(.notion) }
                    .disabled(unavailable)
                Divider()
                // After the first import: only what changed in Bear, local edits kept.
                Button("Pull from Bear") { window?.importer.pullFromBear() }
                    .keyboardShortcut("b", modifiers: [.command, .option, .shift])
                    .disabled(unavailable)
            }
        }
    }
}

/// When the Import items are off: no window, an import runs, a backup, restore or another
/// library-wide operation is busy, or the app is locked (the open panel is never shown then).
enum ImportCommandAvailability {
    static func isUnavailable(
        hasWindow: Bool, importRunning: Bool, libraryOperationBusy: Bool, appLocked: Bool = false
    ) -> Bool {
        !hasWindow || importRunning || libraryOperationBusy || appLocked
    }
}

/// The open panels of the Import items: files and folders, several at once.
@MainActor
enum ImportPanel {
    /// What a panel offers.
    enum Source: Equatable, Sendable {
        /// File ▸ Import Notes…
        case notes
        /// File ▸ Import From ▸ Evernote…: `.enex` files.
        case evernote
        /// File ▸ Import From ▸ Notion…: the export's zip, or the folder it was unpacked into.
        case notion
        /// File ▸ Import From ▸ Apple Notes Export…: the folder (or its zip) Notes wrote with
        /// File ▸ Export as ▸ Markdown, or single Markdown files.
        case appleNotesExport
    }

    /// `FileImporter` also takes `.zip` (Notion-style exports), `.enex` (Evernote), single HTML
    /// and RTF documents (`.rtfd` is a package), and Bear / Panda notes, which are zipped
    /// TextBundles.
    static let fileExtensions = [
        "md", "markdown", "txt", "textpack", "bear2bk", "zip", "html", "htm", "rtf", "bear", "bearnote", "panda", "enex",
    ]
    /// Extensions of packages (folders the Finder shows as one file).
    static let packageExtensions = ["textbundle", "rtfd"]

    /// TextBundles and RTFDs are packages; a plain `UTType(filenameExtension:)` would make a
    /// dynamic data type that greys them out in the panel.
    static var allowedTypes: [UTType] { allowedTypes(for: .notes) }

    static func allowedTypes(for source: Source) -> [UTType] {
        switch source {
        case .notes:
            fileExtensions.compactMap { UTType(filenameExtension: $0) }
                + packageExtensions.compactMap { UTType(filenameExtension: $0, conformingTo: .package) }
                + [UTType.folder]
        case .evernote:
            ["enex"].compactMap { UTType(filenameExtension: $0) }
        case .notion:
            ["zip"].compactMap { UTType(filenameExtension: $0) } + [UTType.folder]
        case .appleNotesExport:
            ["zip", "md", "markdown"].compactMap { UTType(filenameExtension: $0) } + [UTType.folder]
        }
    }

    static func title(for source: Source) -> String {
        switch source {
        case .notes: "Import Notes"
        case .evernote: "Import From Evernote"
        case .notion: "Import From Notion"
        case .appleNotesExport: "Import From Apple Notes Export"
        }
    }

    static func message(for source: Source) -> String {
        switch source {
        case .notes:
            "Choose Markdown, text, HTML or RTF files, TextBundles, TextPacks, Bear notes and backups, "
                + "Evernote export files (.enex), Notion exports, or folders."
        case .evernote:
            "Choose the export files (.enex) that Evernote wrote. A notebook, or the notes you "
                + "selected, make one file each."
        case .notion:
            "Choose the zip file Notion made when you exported your workspace, or the folder you unpacked it into."
        case .appleNotesExport:
            "Choose the folder (or its zip) that holds the Markdown files you exported from Apple Notes with "
                + "File ▸ Export as ▸ Markdown. Files the notes link, such as PDFs and images, come along."
        }
    }

    static func makePanel(for source: Source) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = title(for: source)
        panel.prompt = "Choose"
        panel.message = message(for: source)
        panel.canChooseFiles = true
        panel.canChooseDirectories = source != .evernote
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = allowedTypes(for: source)
        return panel
    }

    static func choose(_ source: Source = .notes, _ completion: @escaping @MainActor ([URL]) -> Void) {
        let panel = makePanel(for: source)
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            let urls = panel.urls
            MainActor.assumeIsolated { completion(urls) }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }
}
