// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import UIKit
import TheoNotesCore
import UniformTypeIdentifiers

/// Only the inbox is shared with the app; this process never opens its database.
@MainActor
final class ShareViewController: UIViewController, UITextViewDelegate {
    private let heading = UILabel()
    private let buttons = UIStackView()
    private let editor = UITextView()
    private let status = UILabel()
    private let save = UIButton(type: .system)
    private let append = UIButton(type: .system)
    private(set) var model = ShareSheetModel(container: nil)
    var resolveContainer: () -> URL? = { ShareViewController.container() }
    var announce: (String) -> Void = { message in
        if UIAccessibility.isVoiceOverRunning { UIAccessibility.post(notification: .announcement, argument: message) }
    }
    private var appeared = false
    private var lastAnnouncedStatus: String?
    private var staging: StagingArea?
    private var collection: Task<Void, Never>?
    private var finished = false
    private weak var notePicker: UIAlertController?
    private var offeredNotes: [RecentNotesFile.Entry] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Share to Theo Notes"
        heading.text = title
        heading.font = .preferredFont(forTextStyle: .headline)
        heading.adjustsFontForContentSizeCategory = true
        heading.numberOfLines = 0
        heading.accessibilityTraits.insert(.header)
        editor.font = .preferredFont(forTextStyle: .body)
        editor.adjustsFontForContentSizeCategory = true
        editor.accessibilityLabel = "Note text"
        editor.delegate = self
        status.numberOfLines = 0
        status.font = .preferredFont(forTextStyle: .footnote)
        status.adjustsFontForContentSizeCategory = true
        status.textColor = .secondaryLabel
        let cancel = UIButton(type: .system)
        cancel.setTitle("Cancel", for: .normal)
        cancel.addTarget(self, action: #selector(cancelShare), for: .touchUpInside)
        save.setTitle("Save", for: .normal)
        save.addTarget(self, action: #selector(saveShare), for: .touchUpInside)
        append.setTitle("Append to Note…", for: .normal)
        append.addTarget(self, action: #selector(chooseNote), for: .touchUpInside)
        for button in [cancel, append, save] {
            button.titleLabel?.font = .preferredFont(forTextStyle: .body)
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.titleLabel?.numberOfLines = 0
            button.titleLabel?.textAlignment = .center
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            buttons.addArrangedSubview(button)
        }
        buttons.spacing = 12
        layoutButtons()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (controller: ShareViewController, _: UITraitCollection) in
            controller.layoutButtons()
        }
        let stack = UIStackView(arrangedSubviews: [heading, editor, status, buttons])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.keyboardDismissMode = .interactive
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -12),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -32),
            stack.heightAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.heightAnchor, constant: -24),
            editor.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
        preferredContentSize = CGSize(width: 440, height: 380)
        model = ShareSheetModel(container: resolveContainer())
        model.onChange = { [weak self] in self?.render() }
        model.startWatching()
        render()
        if model.phase == .collecting { collection = Task { await collect() } }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        appeared = true
        UIAccessibility.post(notification: .screenChanged, argument: heading)
        announceStatus()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        appeared = false
    }

    private func layoutButtons() {
        let large = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        buttons.axis = large ? .vertical : .horizontal
        buttons.distribution = large ? .fill : .equalSpacing
    }

    private func announceStatus() {
        guard appeared, status.text != lastAnnouncedStatus else { return }
        lastAnnouncedStatus = status.text
        if let message = status.text, !message.isEmpty { announce(message) }
    }

    private static func container() -> URL? {
        guard let group = ShareRequestBuilder.groupIdentifier,
              let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group),
              SharedContainerFiles.validate(container: url) else { return nil }
        return url
    }

    private func render() {
        if let notePicker, offeredNotes != model.recentNotes {
            notePicker.dismiss(animated: false)
            self.notePicker = nil
        }
        editor.isEditable = model.canEdit
        if editor.text != model.text { editor.text = model.text }
        status.text = model.phase == .collecting ? "Reading shared content…" : model.status
        announceStatus()
        save.isEnabled = model.canSave
        append.isEnabled = model.canAppend
        append.isHidden = model.recentNotes.isEmpty
    }

    func textViewDidChange(_ textView: UITextView) { model.userEdited(textView.text) }

    private func collect() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)")
        staging = try? StagingArea(directory: directory)
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        // Reject oversized batches as a whole rather than silently saving a truncated selection.
        guard providers.count <= 20 else {
            await model.collect(texts: [], loads: [{ _ in .failed }], staging: staging)
            return
        }
        let loads: [@MainActor (StagingArea) async -> SharedPart] = providers.map { provider in
            { staging in
                guard !Task.isCancelled else { return .failed }
                return await Self.load(provider, staging: staging)
            }
        }
        await model.collect(texts: items.compactMap { $0.attributedContentText?.string }, loads: loads, staging: staging)
        if finished { staging?.remove() }
    }

    static func load(_ provider: NSItemProvider, staging: StagingArea) async -> SharedPart {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            guard let copy = await loadFileURL(provider, directory: staging.directory) else { return .failed }
            defer { try? FileManager.default.removeItem(at: copy.url) }
            guard let staged = try? staging.stage(copy.url, suggestedName: provider.suggestedName ?? copy.name) else { return .failed }
            return .file(staged)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            guard let url = await loadURL(provider, type: .url),
                  !url.isFileURL, url.absoluteString.utf8.count <= 2 * 1024 * 1024 else { return .failed }
            return .text(url.absoluteString)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            guard let text = await loadText(provider), text.utf8.count <= 2 * 1024 * 1024 else { return .failed }
            return .text(text)
        }
        guard let type = provider.registeredContentTypes.first(where: { $0.conforms(to: .data) }),
              let copy = await loadFile(provider, type: type, directory: staging.directory) else { return .failed }
        defer { try? FileManager.default.removeItem(at: copy) }
        var name = provider.suggestedName ?? "Shared file"
        if (name as NSString).pathExtension.isEmpty, let ext = type.preferredFilenameExtension { name += "." + ext }
        guard let staged = try? staging.stage(copy, suggestedName: name) else { return .failed }
        return .file(staged)
    }

    // Provider URLs expire when this callback returns; copy them here, before resuming.
    private static func loadFile(_ provider: NSItemProvider, type: UTType, directory: URL) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                guard error == nil, let url else { continuation.resume(returning: nil); return }
                var taken = Set<String>()
                let copy = try? ShareRequestBuilder.stage(url, suggestedName: ".provider-\(UUID().uuidString)", into: directory, taken: &taken)
                continuation.resume(returning: copy)
            }
        }
    }

    private static func loadFileURL(_ provider: NSItemProvider, directory: URL) async -> (url: URL, name: String)? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                guard error == nil else { continuation.resume(returning: nil); return }
                let source: URL?
                switch item {
                case let url as URL: source = url
                case let data as Data where data.count <= 2 * 1024 * 1024:
                    source = URL(dataRepresentation: data, relativeTo: nil)
                default: source = nil
                }
                guard let source, source.isFileURL else { continuation.resume(returning: nil); return }
                var taken = Set<String>()
                let copy = try? ShareRequestBuilder.stage(source, suggestedName: ".provider-\(UUID().uuidString)", into: directory, taken: &taken)
                continuation.resume(returning: copy.map { ($0, source.lastPathComponent) })
            }
        }
    }

    private static func loadURL(_ provider: NSItemProvider, type: UTType) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, error in
                guard error == nil else { continuation.resume(returning: nil); return }
                switch item {
                case let url as URL: continuation.resume(returning: url)
                case let data as Data where data.count <= 2 * 1024 * 1024:
                    continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                default: continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func loadText(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, error in
                guard error == nil else { continuation.resume(returning: nil); return }
                switch item {
                case let text as String: continuation.resume(returning: text)
                case let text as NSAttributedString: continuation.resume(returning: text.string)
                case let data as Data where data.count <= 2 * 1024 * 1024:
                    continuation.resume(returning: String(data: data, encoding: .utf8))
                default: continuation.resume(returning: nil)
                }
            }
        }
    }

    @objc private func saveShare() { submit(target: nil) }

    @objc private func chooseNote() {
        model.refreshRecentNotes()
        let picker = UIAlertController(title: "Append to Note", message: nil, preferredStyle: .actionSheet)
        for entry in model.recentNotes {
            picker.addAction(UIAlertAction(title: entry.title, style: .default) { [weak self] _ in self?.submit(target: entry.id) })
        }
        guard !model.recentNotes.isEmpty else { return }
        picker.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        picker.popoverPresentationController?.sourceView = append
        picker.popoverPresentationController?.sourceRect = append.bounds
        offeredNotes = model.recentNotes
        notePicker = picker
        present(picker, animated: true)
    }

    @objc private func cancelShare() {
        guard model.phase != .submitting else { return }
        finished = true
        collection?.cancel()
        model.stopWatching()
        // A provider callback may still be copying; collection cleans up after it returns.
        if model.phase != .collecting { staging?.remove() }
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }

    private func submit(target: String?) {
        Task {
            guard await model.submit(target: target) else { return }
            finished = true
            model.stopWatching()
            staging?.remove()
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }
}
