// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit

/// One accessibility problem the audit found (M7 Task 12).
struct AXIssue: CustomStringConvertible, Equatable {
    let role: String
    let detail: String
    var description: String { "\(role): \(detail)" }
}

/// Walks a window's accessibility tree (`accessibilityChildren()`, recursively) and reports controls
/// without a name: a button, checkbox, pop-up, menu button, text field, slider or non-hidden image
/// with an empty label and title, and note-list rows whose label does not start with the title.
@MainActor
enum AccessibilityAudit {
    static let controlRoles: Set<NSAccessibility.Role> = [
        .button, .checkBox, .popUpButton, .menuButton, .textField, .slider, .image,
    ]

    /// Every element below `window`, depth first (a bounded walk: the tree of one window).
    static func elements(in window: NSWindow) -> [NSAccessibilityElementProtocol] {
        var out: [NSAccessibilityElementProtocol] = []
        func walk(_ element: Any, depth: Int) {
            guard depth < 60, out.count < 20_000 else { return }
            guard let node = element as? NSObject, node.responds(to: #selector(NSAccessibilityProtocol.accessibilityChildren)) else { return }
            if let el = element as? NSAccessibilityElementProtocol { out.append(el) }
            for child in (node.value(forKey: "accessibilityChildren") as? [Any]) ?? [] { walk(child, depth: depth + 1) }
        }
        for child in window.accessibilityChildren() ?? [] { walk(child, depth: 0) }
        return out
    }

    static func issues(in window: NSWindow, noteTitles: [String: String] = [:]) -> [AXIssue] {
        var issues: [AXIssue] = []
        for element in elements(in: window) {
            guard let node = element as? NSObject else { continue }
            let role = (node.value(forKey: "accessibilityRole") as? NSAccessibility.Role) ?? .unknown
            let label = (node.value(forKey: "accessibilityLabel") as? String) ?? ""
            let title = (node.value(forKey: "accessibilityTitle") as? String) ?? ""
            let hidden = (node.value(forKey: "isAccessibilityElement") as? Bool) == false
            if controlRoles.contains(role), !hidden, label.isEmpty, title.isEmpty {
                issues.append(AXIssue(role: role.rawValue, detail: "no label or title (\(type(of: node)))"))
            }
            if let id = node.value(forKey: "accessibilityIdentifier") as? String, let expected = noteTitles[id],
               !label.hasPrefix(expected)
            {
                issues.append(AXIssue(role: role.rawValue, detail: "note row \(id) label \"\(label)\" does not start with \"\(expected)\""))
            }
        }
        return issues
    }
}
