// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

// Gate item 5: dump AXTextArea/AXWebArea/AXStaticText values of a running app.
// Usage: swift scripts/gate/ax-dump.swift <pid>   (the calling terminal needs Accessibility permission)
import ApplicationServices
import AppKit
let args = CommandLine.arguments
guard args.count > 1, let pid = Int32(args[1]) else { print("usage: axdump <pid>"); exit(2) }
print("AXIsProcessTrusted:", AXIsProcessTrusted())
let app = AXUIElementCreateApplication(pid)
func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?; return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
var found: [String] = []
func walk(_ e: AXUIElement, _ depth: Int) {
    guard depth < 40 else { return }
    let role = attr(e, kAXRoleAttribute) as? String ?? "?"
    let value = attr(e, kAXValueAttribute) as? String
    if role == "AXTextArea" || role == "AXWebArea" || role == "AXStaticText" {
        found.append("\(String(repeating: " ", count: depth))\(role): \(value ?? "")")
    }
    for child in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(child, depth + 1) }
}
let windows = attr(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
print("windows:", windows.count)
for w in windows { walk(w, 0) }
found.forEach { print($0) }
