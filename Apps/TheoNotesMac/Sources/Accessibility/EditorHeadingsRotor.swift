// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit

/// VoiceOver's "Headings" rotor on the editor web view (M7 Task 12): one entry per heading of the
/// shown note ("H2 Install"), in `NoteParser` order. WebKit's own heading rotor does not cross into
/// the web content's tree from the host, so the host offers this one.
///
/// Searching has no side effect: VoiceOver searches through every entry to build its rotor menu.
/// Each entry is a `HeadingElement`; the editor scrolls to the heading only when VoiceOver lands on
/// it (focus) or presses it (`EditorBridgeController.scrollToHeading`).
@MainActor
final class EditorHeadingsRotor: NSObject, NSAccessibilityCustomRotorItemSearchDelegate {
    struct Entry: Equatable {
        let level: Int
        let text: String
        var label: String { "H\(level) \(text)" }
    }

    /// The shown note's headings.
    var headings: () -> [Entry]
    /// Scrolls the editor to the heading at this index.
    var choose: (Int) -> Void
    weak var target: NSView?

    init(headings: @escaping () -> [Entry], choose: @escaping (Int) -> Void) {
        self.headings = headings
        self.choose = choose
    }

    private(set) lazy var rotor = NSAccessibilityCustomRotor(label: "Headings", itemSearchDelegate: self)
    /// The entries' elements: an item result holds its target weakly, so the rotor keeps them
    /// (one per heading index and label; a changed heading gets a new one).
    private var elements: [Int: HeadingElement] = [:]

    nonisolated func rotor(
        _ rotor: NSAccessibilityCustomRotor, resultFor searchParameters: NSAccessibilityCustomRotor.SearchParameters
    ) -> NSAccessibilityCustomRotor.ItemResult? {
        // AppKit asks on the main thread; anything else gets no result rather than a trap.
        guard Thread.isMainThread else { return nil }
        nonisolated(unsafe) let search = searchParameters
        nonisolated(unsafe) var found: NSAccessibilityCustomRotor.ItemResult?
        MainActor.assumeIsolated {
            let filter = search.filterString.trimmingCharacters(in: .whitespaces)
            // The entry the search starts from (nil, or not one of ours: from the start or the end).
            let from = (search.currentItem?.targetElement as? HeadingElement)?.index
            found = result(filter: filter, from: from, forward: search.searchDirection == .next)
        }
        return found
    }

    /// The next (or previous) heading after the entry at `from` (nil: from the start or end) whose
    /// label contains `filter`. No scrolling here (see the type's comment).
    func result(filter: String, from: Int?, forward: Bool) -> NSAccessibilityCustomRotor.ItemResult? {
        guard let target else { return nil }
        let entries = headings()
        let matching = entries.indices.filter { filter.isEmpty || entries[$0].label.localizedCaseInsensitiveContains(filter) }
        let next: Int? =
            if let from {
                forward ? matching.first { $0 > from } : matching.last { $0 < from }
            } else {
                forward ? matching.first : matching.last
            }
        guard let index = next else { return nil }
        let element = element(index, label: entries[index].label, parent: target)
        let item = NSAccessibilityCustomRotor.ItemResult(targetElement: element)
        item.customLabel = entries[index].label
        return item
    }

    private func element(_ index: Int, label: String, parent: NSView) -> HeadingElement {
        if let kept = elements[index], kept.label == label { return kept }
        let made = HeadingElement(index: index, label: label, parent: parent) { [weak self] in self?.choose($0) }
        elements[index] = made
        return made
    }
}

/// One rotor entry: a heading of the shown note as an accessibility element over the editor. It
/// scrolls the editor to its heading when VoiceOver focuses or presses it. A plain object with the
/// element protocol (AppKit's `NSAccessibilityElement` clashes with it over `accessibilityIdentifier`);
/// VoiceOver reads the other attributes by selector.
@MainActor
final class HeadingElement: NSObject, @MainActor NSAccessibilityElementProtocol {
    let index: Int
    let label: String
    private weak var host: NSView?
    private let scroll: (Int) -> Void

    init(index: Int, label: String, parent: NSView, scroll: @escaping (Int) -> Void) {
        self.index = index
        self.label = label
        self.host = parent
        self.scroll = scroll
        super.init()
    }

    func accessibilityFrame() -> NSRect {
        guard let host, let window = host.window else { return .zero }
        return window.convertToScreen(host.convert(host.bounds, to: nil))
    }

    func accessibilityParent() -> Any? { host }

    func isAccessibilityFocused() -> Bool { false }

    func accessibilityIdentifier() -> String { "heading-\(index)" }

    @objc func accessibilityLabel() -> String? { label }

    @objc func accessibilityRole() -> NSAccessibility.Role? { .staticText }

    @objc func isAccessibilityElement() -> Bool { true }

    @objc func setAccessibilityFocused(_ focused: Bool) {
        if focused { scroll(index) }
    }

    @objc func accessibilityPerformPress() -> Bool {
        scroll(index)
        return true
    }
}
