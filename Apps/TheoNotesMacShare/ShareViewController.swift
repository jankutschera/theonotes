// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import UniformTypeIdentifiers

/// The share sheet of Theo Notes. It never opens the library: it puts the
/// shared text and files into the App Group inbox (`CaptureInbox`) and the app files them the next time it
/// runs. Buttons: Save, Append to Note… (only while the app offers notes) and Cancel. What the sheet knows
/// lives in `ShareSheetModel`; this class draws it and reads the shared items.
final class ShareViewController: NSViewController, NSTextViewDelegate {
    private let textView = NSTextView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let appendButton = NSButton(title: "Append to Note…", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    private var model = ShareSheetModel(container: nil)
    private var staging: StagingArea?

    // MARK: - View

    override func loadView() {
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.delegate = self
        textView.setAccessibilityLabel("Note text")
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        appendButton.target = self
        appendButton.action = #selector(chooseNote)
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"

        let buttons = NSStackView(views: [cancelButton, appendButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let column = NSStackView(views: [scroll, status, buttons])
        column.orientation = .vertical
        column.alignment = .trailing
        column.spacing = 10
        column.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        column.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -28).isActive = true
        status.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -28).isActive = true

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 300))
        root.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            column.topAnchor.constraint(equalTo: root.topAnchor),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
        ])
        view = root
        preferredContentSize = NSSize(width: 440, height: 300)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        model = ShareSheetModel(container: Self.probedContainer())
        model.onChange = { [weak self] in self?.render() }
        model.startWatching()
        render()
        guard model.phase == .collecting else { return }
        Task { await collect() }
    }

    deinit { MainActor.assumeIsolated { model.stopWatching() } }

    /// The App Group folder, probed like the app does: an invalid group still gives a plausible URL.
    private static func probedContainer() -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ShareRequestBuilder.groupIdentifier),
            SharedContainerFiles.validate(container: container)
        else { return nil }
        return container
    }

    private func render() {
        textView.isEditable = model.canEdit
        if textView.string != model.text { textView.string = model.text }
        status.stringValue = model.status
        saveButton.isEnabled = model.canSave
        appendButton.isEnabled = model.canAppend
        appendButton.isHidden = model.recentNotes.isEmpty
    }

    // MARK: - Reading what is shared

    private func collect() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
        staging = try? StagingArea(directory: directory)
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let texts = items.compactMap { $0.attributedContentText?.string }
        let providers = items.flatMap { $0.attachments ?? [] }
        let loads: [@MainActor (StagingArea) async -> SharedPart] = providers.map { provider in
            { staging in await Self.load(provider, staging: staging) }
        }
        await model.collect(texts: texts, loads: loads, staging: staging)
        view.window?.makeFirstResponder(textView)
    }

    /// One shared item: a file from Finder, a web address, plain text, or other data such as an image.
    private static func load(_ provider: NSItemProvider, staging: StagingArea) async -> SharedPart {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            guard let url = await loadURL(provider, type: .fileURL), url.isFileURL,
                  let staged = try? staging.stage(url, suggestedName: nil)
            else { return .failed }
            return .file(staged)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            guard let url = await loadURL(provider, type: .url) else { return .failed }
            return .text(url.absoluteString)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            guard let text = await loadText(provider) else { return .failed }
            return .text(text)
        }
        let dataTypes = provider.registeredContentTypes.filter {
            $0.conforms(to: .data) && !$0.conforms(to: .text) && !$0.conforms(to: .url)
        }
        guard let type = dataTypes.first, let copy = await loadFile(provider, type: type, into: staging.directory) else {
            return .failed
        }
        let name = (provider.suggestedName ?? "Shared file") + (type.preferredFilenameExtension.map { "." + $0 } ?? "")
        let target = staging.target(for: name)
        do {
            try FileManager.default.moveItem(at: copy, to: target)
            return .file(target)
        } catch {
            try? FileManager.default.removeItem(at: copy)
            return .failed
        }
    }

    private static func loadURL(_ provider: NSItemProvider, type: UTType) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
                switch item {
                case let url as URL: continuation.resume(returning: url)
                case let data as Data: continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                default: continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func loadText(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                switch item {
                case let text as String: continuation.resume(returning: text)
                case let text as NSAttributedString: continuation.resume(returning: text.string)
                case let data as Data: continuation.resume(returning: String(data: data, encoding: .utf8))
                default: continuation.resume(returning: nil)
                }
            }
        }
    }

    /// The provider's file is only valid inside the callback, so it is copied to a hidden name there.
    private static func loadFile(_ provider: NSItemProvider, type: UTType, into directory: URL) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { return continuation.resume(returning: nil) }
                let copy = directory.appendingPathComponent(".loading-\(UUID().uuidString)")
                do {
                    try FileManager.default.copyItem(at: url, to: copy)
                    continuation.resume(returning: copy)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Buttons

    func textDidChange(_ notification: Notification) { model.userEdited(textView.string) }

    @objc private func save() { submit(target: nil) }

    @objc private func chooseNote() {
        model.refreshRecentNotes()
        let menu = NSMenu()
        for entry in model.recentNotes {
            let item = NSMenuItem(title: entry.title, action: #selector(appendToChosenNote(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.id
            menu.addItem(item)
        }
        guard !menu.items.isEmpty else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: appendButton.bounds.height), in: appendButton)
    }

    @objc private func appendToChosenNote(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        submit(target: id)
    }

    @objc private func cancel() {
        model.stopWatching()
        staging?.remove()
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }

    private func submit(target: String?) {
        Task {
            guard await model.submit(target: target) else { return }
            model.stopWatching()
            staging?.remove()
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }
}
