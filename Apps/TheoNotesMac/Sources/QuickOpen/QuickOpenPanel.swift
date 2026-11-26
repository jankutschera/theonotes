// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import SwiftUI

/// The floating Quick Open panel: non-activating, horizontally centred over the window ⌘O was
/// pressed in with its field in that window's top third. It routes the panel keys to its model
/// before the field editor sees them (except while an input method composes text).
final class QuickOpenPanel: NSPanel {
    static let size = NSSize(width: 560, height: 380)

    /// Handles a panel key; false passes it on.
    var onKey: ((QuickOpenModel.Key) -> Bool)?
    /// The panel stopped being key (a click elsewhere, another window).
    var onResignKey: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovable = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        setAccessibilityTitle("Quick Open")
    }

    /// The system's utility-window fade, or none under Reduce Motion (the panel is the app's one custom animation).
    static func animationBehavior(reduceMotion: Bool) -> NSWindow.AnimationBehavior {
        reduceMotion ? .none : .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The panel's frame: centred horizontally over `parent` (the screen without one), its top
    /// edge a sixth of the way down so the field sits in the top third, kept on `screen`.
    static func frame(size: NSSize, over parent: NSRect?, screen: NSRect) -> NSRect {
        let area = parent ?? screen
        var frame = NSRect(
            x: area.midX - size.width / 2, y: area.maxY - area.height / 6 - size.height,
            width: size.width, height: size.height)
        frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - size.width)
        frame.origin.y = min(max(frame.minY, screen.minY), screen.maxY - size.height)
        return frame
    }

    func handle(_ key: QuickOpenModel.Key) -> Bool {
        onKey?(key) ?? false
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, !isComposing {
            // A held ↩ must not open one result after another (or reach the field).
            if QuickOpenModel.isRepeatedReturn(event) { return }
            if let key = QuickOpenModel.key(for: event), handle(key) { return }
        }
        super.sendEvent(event)
    }

    /// ⌘↩ arrives as a key equivalent before it is a key down.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !isComposing, QuickOpenModel.key(for: event) == .openInNewWindow, handle(.openInNewWindow) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Esc that reached the responder chain; while composing it belongs to the input method.
    override func cancelOperation(_ sender: Any?) {
        guard !isComposing else { return }
        _ = handle(.cancel)
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    /// An input method has marked text in the field: ↩, Esc and the arrows belong to it.
    var isComposing: Bool {
        (firstResponder as? NSTextInputClient)?.hasMarkedText() ?? false
    }
}

/// Shows one Quick Open panel at a time and gives keyboard focus back when it closes: Esc (and
/// choosing a result) return it to the window and view that had it; a click elsewhere leaves it
/// where the click put it.
@MainActor
final class QuickOpenController {
    static let announcementDelay: TimeInterval = 0.5

    private(set) var panel: QuickOpenPanel?
    private(set) var model: QuickOpenModel?
    private weak var previousWindow: NSWindow?
    private weak var previousResponder: NSResponder?
    private var isDismissing = false
    /// Bumped by every show and dismiss: a deferred teardown or announcement of an earlier panel
    /// does nothing.
    private var generation = 0
    private var pendingAnnouncement: DispatchWorkItem?

    /// The panel is on screen (it also hides when the app deactivates).
    var isShown: Bool { model != nil && panel?.isVisible == true }

    /// Shows the panel for `model` over `window` (the key window when ⌘O was pressed). `appearance` is the
    /// resolved look: the theme palette for the panel's content, and Reduce Motion for its show and hide.
    func show(_ model: QuickOpenModel, over window: NSWindow?, appearance: AppearanceController? = nil) {
        if self.model != nil { dismiss(restoringFocus: false) }
        generation += 1
        previousWindow = window
        // A text field's focus is its window's field editor: remember the field itself.
        if let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor,
           let field = editor.delegate as? NSResponder {
            previousResponder = field
        } else {
            previousResponder = window?.firstResponder
        }
        self.model = model
        let choose = model.onChoose
        model.onChoose = { [weak self] result, newWindow in
            self?.dismiss(restoringFocus: true)
            choose(result, newWindow)
        }
        let cancel = model.onCancel
        model.onCancel = { [weak self] in
            self?.dismiss(restoringFocus: true)
            cancel()
        }
        model.onSelectionChange = { [weak self] result in
            self?.announce(QuickOpenModel.accessibilityLabel(for: result))
        }
        model.onResultsChange = { [weak self] results in
            self?.announceLater(QuickOpenModel.resultsAnnouncement(results))
        }

        let panel = self.panel ?? QuickOpenPanel()
        self.panel = panel
        panel.onKey = { [weak model] key in model?.handle(key) ?? false }
        panel.onResignKey = { [weak self] in self?.dismiss(restoringFocus: false) }
        panel.setAccessibilityTitle(model.panelTitle)
        panel.animationBehavior = QuickOpenPanel.animationBehavior(reduceMotion: appearance?.resolved.reduceMotion ?? false)
        if let appearance {
            panel.contentView = NSHostingView(rootView: QuickOpenView(model: model).shellPalette(from: appearance))
        } else {
            panel.contentView = NSHostingView(rootView: QuickOpenView(model: model))
        }
        let screen = (window?.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(origin: .zero, size: QuickOpenPanel.size)
        panel.setFrame(QuickOpenPanel.frame(size: QuickOpenPanel.size, over: window?.frame, screen: screen), display: false)
        panel.makeKeyAndOrderFront(nil)
        focusField()
    }

    /// Puts keyboard focus into the field (also ⌘O while the panel is shown). Again on the next
    /// run-loop turn: SwiftUI may only then have put the field into the window.
    func focusField() {
        guard let panel, model != nil else { return }
        panel.makeKeyAndOrderFront(nil)
        if let field = Self.textField(in: panel.contentView) { panel.makeFirstResponder(field) }
        let shown = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == shown, let panel = self.panel, panel.isVisible,
                  !Self.fieldHasFocus(in: panel), let field = Self.textField(in: panel.contentView) else { return }
            panel.makeFirstResponder(field)
        }
    }

    func dismiss(restoringFocus: Bool) {
        guard model != nil, !isDismissing else { return }
        isDismissing = true
        defer { isDismissing = false }
        generation += 1
        model = nil
        pendingAnnouncement?.cancel()
        pendingAnnouncement = nil
        panel?.onKey = nil
        panel?.onResignKey = nil
        panel?.orderOut(nil)
        // The hosting view goes on the next turn: a row click dismisses from inside its own
        // gesture, which must not tear down the view it runs in.
        let dismissed = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == dismissed else { return }
            self.panel?.contentView = nil
        }
        guard restoringFocus, let window = previousWindow, window.isVisible else { return }
        window.makeKeyAndOrderFront(nil)
        if let responder = previousResponder, Self.belongs(responder, to: window) {
            window.makeFirstResponder(responder)
        }
    }

    private static func belongs(_ responder: NSResponder, to window: NSWindow) -> Bool {
        if responder === window { return true }
        return (responder as? NSView)?.window === window
    }

    static func fieldHasFocus(in panel: NSPanel) -> Bool {
        guard let editor = panel.firstResponder as? NSTextView, editor.isFieldEditor else { return false }
        return editor.delegate is NSTextField
    }

    private static func textField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let field = textField(in: subview) { return field }
        }
        return nil
    }

    /// VoiceOver keeps focus in the field while ↑↓ move the selection: it announces the row.
    private func announce(_ text: String) {
        pendingAnnouncement?.cancel()
        pendingAnnouncement = nil
        guard let panel else { return }
        NSAccessibility.post(
            element: panel, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// While typing: once the query has settled for `announcementDelay`.
    private func announceLater(_ text: String) {
        pendingAnnouncement?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.announce(text) }
        }
        pendingAnnouncement = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.announcementDelay, execute: item)
    }
}

/// The panel's content: the field and the results.
struct QuickOpenView: View {
    @Bindable var model: QuickOpenModel
    @FocusState private var fieldFocused: Bool
    @Environment(\.shellPalette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(model.placeholder, text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .accessibilityLabel(model.panelTitle)
                    .accessibilityHint(model.fieldHint)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            Divider()
            results
        }
        .frame(width: QuickOpenPanel.size.width, height: QuickOpenPanel.size.height)
        // A standard material, which the system makes opaque under Reduce Transparency. Rows keep the system
        // text colours that match it; only the field's caret takes the theme accent. The selected row stays on
        // the asset AccentColor/OnAccentColor pair, whatever the theme.
        .background(.regularMaterial)
        .tint(palette.accent)
        .onAppear { fieldFocused = true }
    }

    @ViewBuilder private var results: some View {
        if model.results.isEmpty {
            Text(model.emptyMessage)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                            QuickOpenRow(result: result, isSelected: index == model.selectedIndex)
                                .id(result.id)
                                .onTapGesture {
                                    model.choose(result, newWindow: NSEvent.modifierFlags.contains(.command))
                                }
                        }
                    }
                    .padding(6)
                }
                .accessibilityLabel("Results")
                .onChange(of: model.selectedIndex) {
                    if let selected = model.selected { proxy.scrollTo(selected.id) }
                }
            }
        }
    }
}

/// The selected row's fill and text: the asset `AccentColor` and `OnAccentColor` (white in every variant), a
/// fill-safe red decoupled from the themes' text accent (white on it is at least 4.5:1, pinned by
/// `ThemeTests.testAccentColorCarriesWhiteTextOnItsFill`). Both come from the asset so the pair always matches.
enum QuickOpenColors {
    static var selectedFill: NSColor { NSColor(named: "AccentColor") ?? .controlAccentColor }
    static var selectedText: NSColor { NSColor(named: "OnAccentColor") ?? .white }
}

private struct QuickOpenRow: View {
    let result: QuickOpenResult
    let isSelected: Bool

    private static let selectedText = Color(nsColor: QuickOpenColors.selectedText)
    private static let selectedFill = Color(nsColor: QuickOpenColors.selectedFill)

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: QuickOpenModel.symbolName(for: result))
                .frame(width: 18)
                .foregroundStyle(isSelected ? AnyShapeStyle(Self.selectedText) : AnyShapeStyle(.secondary))
            Text(QuickOpenModel.displayTitle(for: result))
                .lineLimit(1)
                .foregroundStyle(
                    isSelected
                        ? AnyShapeStyle(Self.selectedText)
                        : result.kind == .note && result.title.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            Spacer(minLength: 8)
            if let detail = result.detail {
                Text(detail)
                    .font(.callout)
                    // Full opacity: the fill leaves no headroom for a dimmed detail (white at 85 % fell below AA).
                    .foregroundStyle(isSelected ? AnyShapeStyle(Self.selectedText) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(isSelected ? Self.selectedText : .primary)
        .background(isSelected ? Self.selectedFill : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(QuickOpenModel.accessibilityLabel(for: result))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
