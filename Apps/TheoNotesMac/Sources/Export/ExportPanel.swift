// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore

/// The folder panel of an export: an open panel for directories with an accessory view for the
/// format and its options (M8-R1: "Convert note links to HTML links" and "Embed images" for HTML
/// only, a theme for PDF only; A9: "Include attachments" for Markdown, TextBundle and HTML, "Put
/// images inside the file" for Markdown only).
@MainActor
enum ExportPanel {
    static func choose(
        title: String, settings: ExportSettings, lightThemeName: String = "Default",
        completion: @escaping @MainActor (URL, ExportSettings) -> Void, cancelled: @escaping @MainActor () -> Void = {}
    ) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Export"
        panel.message = "Choose the folder to export into."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        let accessory = ExportPanelAccessory(settings: settings, lightThemeName: lightThemeName)
        panel.accessoryView = accessory.view
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            // The accessory is read before the panel goes away.
            let chosen = accessory.settings
            let url = panel.url
            MainActor.assumeIsolated {
                if response == .OK, let url { completion(url, chosen) } else { cancelled() }
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }
}

extension ExportPanel {
    /// The name the PDF theme popup shows for its default item: the theme of the light slot.
    static func lightThemeName(_ snapshot: TheoNotesCore.Settings.Snapshot) -> String {
        let id = ThemePicker.selection(stored: snapshot.lightTheme, appearance: .light)
        return ThemeCatalog.theme(id: id)?.name ?? id
    }
}

/// The accessory view's controls and the settings they hold. `keepTags` is not offered here: it
/// is a Settings toggle and travels through unchanged.
@MainActor
final class ExportPanelAccessory: NSObject {
    private(set) var settings: ExportSettings
    let view = NSView()

    private let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let linksCheckbox = NSButton(
        checkboxWithTitle: "Convert note links to HTML links", target: nil, action: nil)
    private let embedCheckbox = NSButton(checkboxWithTitle: "Put images inside the file", target: nil, action: nil)
    private let attachmentsCheckbox = NSButton(checkboxWithTitle: "Include attachments", target: nil, action: nil)
    private let markdownEmbedCheckbox = NSButton(
        checkboxWithTitle: "Put images inside the file", target: nil, action: nil)
    private let themeLabel = NSTextField(labelWithString: "Theme:")
    private let themePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let optionsStack = NSStackView()

    /// The popup's first item: the light-slot theme, which is also what a nil id means.
    static func defaultThemeTitle(_ lightThemeName: String) -> String { "Light theme (\(lightThemeName))" }

    init(settings: ExportSettings, lightThemeName: String) {
        self.settings = settings
        super.init()

        for format in ExportFormat.allCases {
            formatPopup.addItem(withTitle: format.title)
            formatPopup.lastItem?.representedObject = format.rawValue
        }
        formatPopup.selectItem(at: ExportFormat.allCases.firstIndex(of: settings.format) ?? 0)
        formatPopup.target = self
        formatPopup.action = #selector(changed(_:))
        formatPopup.setAccessibilityLabel("Format")

        themePopup.addItem(withTitle: Self.defaultThemeTitle(lightThemeName))
        themePopup.lastItem?.representedObject = nil
        themePopup.menu?.addItem(.separator())
        // Menu items, not `addItem(withTitle:)`, which would drop an item with an equal title.
        for theme in ThemeCatalog.themes(.light) + ThemeCatalog.themes(.dark) {
            let item = NSMenuItem(title: theme.name, action: nil, keyEquivalent: "")
            item.representedObject = theme.id
            themePopup.menu?.addItem(item)
        }
        if let id = settings.pdfThemeId, let index = themePopup.itemArray.firstIndex(where: { $0.representedObject as? String == id }) {
            themePopup.selectItem(at: index)
        }
        themePopup.target = self
        themePopup.action = #selector(changed(_:))
        themePopup.setAccessibilityLabel("Theme")

        for box in [linksCheckbox, embedCheckbox, attachmentsCheckbox, markdownEmbedCheckbox] {
            box.target = self
            box.action = #selector(changed(_:))
        }
        linksCheckbox.state = settings.htmlLinksBetweenNotes ? .on : .off
        embedCheckbox.state = settings.htmlEmbedImages ? .on : .off
        attachmentsCheckbox.state = settings.includeAttachments ? .on : .off
        markdownEmbedCheckbox.state = settings.markdownEmbedImages ? .on : .off
        attachmentsCheckbox.setAccessibilityLabel("Include attachments")

        let formatLabel = NSTextField(labelWithString: "Format:")
        let formatRow = NSStackView(views: [formatLabel, formatPopup])
        formatRow.spacing = 8
        let themeRow = NSStackView(views: [themeLabel, themePopup])
        themeRow.spacing = 8
        themeRow.identifier = NSUserInterfaceItemIdentifier("themeRow")

        optionsStack.orientation = .vertical
        optionsStack.alignment = .leading
        optionsStack.spacing = 6
        let markdownEmbedRow = Self.indented(markdownEmbedCheckbox)
        let embedRow = Self.indented(embedCheckbox)
        markdownEmbedRow.identifier = NSUserInterfaceItemIdentifier("markdownEmbedRow")
        embedRow.identifier = NSUserInterfaceItemIdentifier("embedRow")
        optionsStack.setViews([formatRow, attachmentsCheckbox, markdownEmbedRow, linksCheckbox, embedRow, themeRow], in: .top)
        optionsStack.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        optionsStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(optionsStack)
        // Top and sides only: the height is fixed below, so hidden rows leave their space empty.
        NSLayoutConstraint.activate([
            optionsStack.topAnchor.constraint(equalTo: view.topAnchor),
            optionsStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            optionsStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        // One height for every format: measured with every row shown, then kept.
        for row in optionsStack.arrangedSubviews { row.isHidden = false }
        view.layoutSubtreeIfNeeded()
        let fixed = optionsStack.fittingSize
        view.frame.size = NSSize(width: fixed.width, height: fixed.height)
        refresh()
    }

    /// A checkbox that sits under "Include attachments" because it depends on it.
    private static func indented(_ box: NSButton) -> NSView {
        let row = NSStackView(views: [box])
        row.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 0)
        return row
    }

    /// The options only their format uses are hidden for the others.
    private func refresh() {
        let format = selectedFormat
        linksCheckbox.isHidden = format != .html
        attachmentsCheckbox.isHidden = ![.markdown, .textBundle, .html].contains(format)
        markdownEmbedCheckbox.superview?.isHidden = format != .markdown
        embedCheckbox.superview?.isHidden = format != .html
        // Nothing to put inside the file while attachments are left out.
        let hint = "Turn on Include attachments to use this."
        for box in [markdownEmbedCheckbox, embedCheckbox] {
            box.isEnabled = attachmentsCheckbox.state == .on
            box.toolTip = box.isEnabled ? nil : hint
        }
        themeLabel.superview?.isHidden = format != .pdf
    }

    private var selectedFormat: ExportFormat {
        (formatPopup.selectedItem?.representedObject as? String).flatMap(ExportFormat.init(rawValue:)) ?? settings.format
    }

    @objc private func changed(_ sender: Any?) {
        settings.format = selectedFormat
        settings.htmlLinksBetweenNotes = linksCheckbox.state == .on
        settings.htmlEmbedImages = embedCheckbox.state == .on
        settings.includeAttachments = attachmentsCheckbox.state == .on
        settings.markdownEmbedImages = markdownEmbedCheckbox.state == .on
        settings.pdfThemeId = themePopup.selectedItem?.representedObject as? String
        refresh()
    }
}
